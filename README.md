# llm-d on a disconnected RHOAI install

Deploys **llm-d** — distributed LLM inference — onto an air-gapped OpenShift AI
cluster, where nothing can reach `quay.io`, `registry.redhat.io` or
`huggingface.co` and every image must be in the local mirror registry first.

It assumes OpenShift and RHOAI are already installed and healthy. Building that
underneath is a separate job:
**[rh-aiservices-bu/disconnected-rhoai](https://github.com/rh-aiservices-bu/disconnected-rhoai)**.

---

## What gets deployed

An `LLMInferenceService` — the RHOAI/KServe resource that runs a model under
llm-d — plus the routing layer in front of it:

| Component | What it is |
|:--|:--|
| **vLLM server** | the model itself, one pod per replica, one GPU each |
| **ModelCar sidecar** | the model weights, delivered as a container image |
| **Inference scheduler (EPP)** | llm-d's endpoint picker — routes each request to the replica that already holds its prefix in KV cache, instead of round-robin |
| **Routing sidecar + KV-cache** | the data path the scheduler steers |
| **Gateway + HTTPRoute** | `openshift-ai-inference` in `openshift-ingress`, serving `/{namespace}/{model}/v1/...` |
| **Namespace + HardwareProfile** | `demo-llm`, and the GPU shape the dashboard shows |

The result is an OpenAI-compatible endpoint. Two models ship ready to use:
`qwen2.5-0.5b` (small, for proving the path) and `qwen3-4b` (the demo model).

## What gets mirrored

Eight images, about **27 GB**. Phase 05 discovers the exact list from your
cluster and writes `config/required-images.txt` — the digests are specific to
your RHOAI version, so this table is illustrative, not a fixed list.

| Image | Size | Why |
|:--|:--|:--|
| `quay.io/redhat-ai-services/modelcar-catalog` *(qwen2.5-0.5b-instruct)* | 0.9 GiB | model weights, smoke test |
| `quay.io/redhat-ai-services/modelcar-catalog` *(qwen3-4b)* | 7.6 GiB | model weights, demo |
| `registry.redhat.io/rhaii/vllm-cuda-rhel9` | 16 GiB | the vLLM serving runtime |
| `registry.redhat.io/rhoai/odh-llm-d-inference-scheduler-rhel9` | small | the endpoint picker |
| `registry.redhat.io/rhoai/odh-llm-d-routing-sidecar-rhel9` | small | request routing |
| `registry.redhat.io/rhoai/odh-llm-d-kv-cache-rhel9` | 4.4 GiB | KV-cache support |
| `registry.redhat.io/rhoai/odh-kserve-storage-initializer-rhel9` | small | unpacks the ModelCar |
| `registry.access.redhat.com/ubi9/httpd-24` | 250 MB | only for the [GPU driver workaround](#no-gpu) |

Three things worth knowing about that list:

- **The model weights are the reason this is not just an `oc apply`.** A normal
  llm-d deployment fetches them from Hugging Face at runtime. Here they travel
  as a container image (KServe *ModelCar*) through the same mirror as everything
  else.
- **The four llm-d components are usually missing even on a healthy cluster.**
  Nothing pulls them until the first `LLMInferenceService` exists, so a RHOAI
  install can report `Ready` for weeks with none of them mirrored. All four were
  absent on the cluster this was built against.
- **Only the accelerator you own is mirrored.** RHOAI also declares ROCm, Gaudi
  and Spyre runtimes; phase 05 drops the ones your nodes cannot schedule, which
  saves tens of gigabytes.

Everything is pushed into its own `llmd` namespace in the mirror registry, with
its own `ImageDigestMirrorSet`, so it cannot disturb rules another workload
depends on.

---

## The whole process

Five commands. Roughly 45 minutes, most of it waiting for images to copy.

```bash
# 0. one-time
cp config/llmd.env.example config/llmd.env     # usually needs no edits

# 1. laptop — copy this repo to both lab hosts
scripts/remote.sh sync

# 2. high side — ask the cluster what it needs
scripts/remote.sh run high -- './deploy-llmd.sh 05'

# 3. laptop — carry that list to the low side
scripts/remote.sh sync

# 4. low side — download and ship the images       (~20 min)
scripts/remote.sh run low  -- './deploy-llmd.sh low'

# 5. high side — push, deploy, and prove it works  (~20 min)
scripts/remote.sh run high -- './deploy-llmd.sh high'
```

Step 5 ends with a real inference request and prints the model's reply. If you
see `llm-d verify complete`, you are done.

> **Steps 4 and 5 are long.** Run them under `tmux` (`scripts/remote.sh ssh low`,
> then `tmux new -s llmd`) so a dropped SSH connection cannot kill them. Every
> phase is re-runnable, so if something does die, just run it again.

### If a step fails

Every phase prints what to do next. Re-run just that phase:

```bash
./deploy-llmd.sh 18        # or whichever number failed
```

Nothing is destructive and nothing has to be undone first. Re-running a phase
that already succeeded is a no-op.

---

## Before you start

| | |
|:--|:--|
| A disconnected cluster | OpenShift 4.19+, RHOAI 3.4+, `DataScienceCluster` Ready |
| Built with | [disconnected-rhoai](https://github.com/rh-aiservices-bu/disconnected-rhoai) |
| SSH to both hosts | jump box (has internet) and high side (has the registry and `oc`) |
| A GPU with capacity | see [No GPU?](#no-gpu) |
| Free disk | ~60 GB on `/mnt/mirror` per host, ~60 GB in the mirror registry |
| A Red Hat pull secret | on the low side, for `registry.redhat.io` |

Preflight checks all of this and changes nothing. **Run it first if unsure:**

```bash
scripts/remote.sh run high -- './deploy-llmd.sh 06'
scripts/remote.sh run low  -- './deploy-llmd.sh 01'
```

### Configuration

One file, `config/llmd.env`, and the defaults are usually right. The values you
might change:

```bash
LLMD_MODEL="qwen2.5-0.5b"   # start here: 0.9 GiB, proves the whole path
LLMD_MODEL="qwen3-4b"       # the demo model: 7.6 GiB

LLMD_LOW_HOST="..."         # set these if your disconnected-rhoai checkout
LLMD_HIGH_HOST="..."        # points at a different environment
```

Registry address, credentials and host addresses are read from the
disconnected-rhoai checkout's own config file (it is named `config/criab.env`
there) — deliberately not duplicated here, because two copies of
`MIRROR_REGISTRY` is how you end up pushing to a registry the cluster does not
trust. The scripts find that checkout automatically under `~/disconnected-rhoai`
or `~/criab`; set `RHOAI_REPO_DIR` if yours lives elsewhere.

---

## What each phase does

| Phase | Where | What |
|:--|:--|:--|
| `05` | high | Asks the cluster which images llm-d needs → `config/required-images.txt` |
| `01` | low | Preflight |
| `10` | low | Downloads them (`oc-mirror` to disk) |
| `15` | low | Ships the archive to the high side, then **verifies the copy** |
| `06` | high | Preflight — CRDs, GPU, disk, catalog, Service Mesh |
| `18` | high | Pushes to the registry, merges mirror rules, waits for the rollout |
| `20` | high | Confirms every required image is really there |
| `30` | high | Enables OCI ModelCar in KServe |
| `40` | high | Creates the Gateway and the model |
| `50` | high | Sends a real completion request |

Phase 05 is separate because only the high side can read the cluster and only
the low side has internet. `scripts/remote.sh sync` moves the list between them.

---

## Why disconnected is different

Four things break without egress. The scripts handle all of them; this is what
they are doing.

**1. Model weights cannot come from Hugging Face.** `uri: hf://Qwen/Qwen3-4B`
reaches `huggingface.co`, which does not exist here. Instead the weights ship as
a container image and are referenced with `oci://`.

**2. ModelCar is off by default.** KServe rejects `oci://` URIs unless
`enableModelcar` is set, and the error — `OCI modelcars is not enabled` — appears
as a reconcile failure, not anything image-shaped. Phase 30 sets it and restarts
the controller, which caches the value at startup.

**3. The Gateway pulls in Service Mesh.** Creating a `GatewayClass` makes the
ingress operator subscribe `servicemeshoperator3` from a CatalogSource named
`redhat-operators` — hard-coded, and disabled on a disconnected cluster. Without
an alias to the mirrored index the GatewayClass sits at `Accepted=Unknown`
forever while the DataScienceCluster still reports Ready. The disconnected-rhoai
install creates that alias; phase 06 checks for it.

**4. Nothing may be assumed to be in the mirror.** Phase 20 checks every image
against the registry before anything is deployed, using the cluster's own mirror
rules rather than guessing the path.

---

## No GPU?

llm-d needs a GPU. Phase 06 tells you which case you are in.

**No GPU node at all** — provision one (this spends money, ~$2/hour):

```bash
./deploy-llmd.sh 12          # NVIDIA L40S on AWS (g6e.2xlarge)
```

**A GPU node exists but reports no capacity** — the driver did not build. This is
the normal disconnected failure and it is *not* a hardware fault. Start with the
diagnosis; it often reports that there is nothing to do:

```bash
./deploy-llmd.sh 14 diagnose
```

Kernel sources come from the Driver Toolkit, which is in the OpenShift release
payload and therefore already mirrored — that half usually works. CUDA packages
come from `developer.download.nvidia.com` and that half usually does not.
`diagnose` distinguishes them so you do not do an hour of unnecessary work.

**A GPU exists but something else is using it** — phase 06 names the holder. One
GPU cannot run two models:

```bash
oc patch llminferenceservice <other-model> -n <ns> --type=merge -p '{"spec":{"replicas":0}}'
```

---

## Using the model

llm-d routes by path — `/{namespace}/{name}/v1/...`:

```bash
oc port-forward -n openshift-ingress \
  svc/openshift-ai-inference-openshift-default 8080:80 &

curl -s http://localhost:8080/demo-llm/qwen25-05b/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen2.5-0.5B-Instruct",
       "messages":[{"role":"user","content":"hello"}]}' | jq
```

The `model` field must match `spec.model.name`, not the resource name. Phase 50
reads it from `/v1/models` rather than assuming, because a mismatch returns a
404 that looks exactly like a routing failure.

To switch to the 4B demo model:

```bash
sed -i 's/^LLMD_MODEL=.*/LLMD_MODEL="qwen3-4b"/' config/llmd.env
./deploy-llmd.sh 40 && ./deploy-llmd.sh 50
```

`prefix-cache-scorer` — the thing that makes llm-d better than plain vLLM — is
inert at one replica. The routing benefit only appears once there is more than
one replica to choose between.

---

## Troubleshooting

Ordered by how often each is the answer.

| Symptom | What it means |
|:--|:--|
| Phase fails with advice printed | do what it says, then re-run that phase |
| `ImagePullBackOff` | run phase 20 — it names the missing image |
| Pod `Pending`, `Insufficient nvidia.com/gpu` | something else holds the GPU; phase 06 names it |
| GPU node with no capacity | driver did not build → `./deploy-llmd.sh 14 diagnose` |
| oc-mirror push → `502 Bad Gateway` | the registry's disk is full; phase 18 checks this first and tells you how to reclaim |
| `manifest unknown` from `localhost:55000` | usually an empty incremental archive, not corruption — run phase 20; if all images are present there is nothing to do |
| An image was mirrored but now reports `NORULE` | an IDMS was replaced rather than merged; re-run phase 18, which unions rules |
| GatewayClass `Accepted=Unknown` | no `redhat-operators` CatalogSource — re-run the disconnected-rhoai install's phase 30 |
| Gateway programmed but times out | external NLB with public IPs; phase 40 patches this automatically |
| `OCI modelcars is not enabled` | phase 30 not run, or the controller was not restarted |
| Scheduler logs show Hugging Face fetches | drop `prefix-cache-scorer` from the plugin list; the other scorers need no tokenizer |

Quick health check:

```bash
oc get llminferenceservice -n demo-llm
oc get pods -n demo-llm
oc logs -n demo-llm -l app.kubernetes.io/name=<model> -c main --tail=50
```

---

## Layout

```
deploy-llmd.sh              phase driver — start here
scripts/
  remote.sh                 sync the repo to the lab hosts
  00-preflight.sh           low|high checks; changes nothing
  05-discover-images.sh     ask the cluster what it needs
  10-mirror-images.sh       oc-mirror to disk
  15-transfer.sh            ship it, then verify the copy
  18-push-images.sh         push to the registry + mirror rules + rollout
  20-verify-mirror.sh       confirm everything is really there
  30-enable-modelcar.sh     enable oci:// in KServe
  40-deploy.sh              Gateway + model
  50-verify.sh              real inference request
  12/14/16-*.sh             GPU node, GPU driver, LeaderWorkerSet
  90-teardown.sh
config/
  llmd.env.example          the only file you edit
  required-images.txt       generated by phase 05
manifests/
  base/ gateway/ gpu/       namespace, HardwareProfile, Gateway, MachineSet
  qwen2.5-0.5b/ qwen3-4b/   the models
```

The manifests work standalone (`oc apply -k manifests/qwen2.5-0.5b`) — but phase
30 must have run first, or the `oci://` URI is rejected.

---

## Field notes

Every one of these was hit bringing this up on a real cluster. They are all
handled by the scripts now; they are recorded because the symptom never
resembles the cause.

**`oc apply` on an IDMS replaces it — it does not merge.** The sharpest edge in
the whole process, and it bites in two ways. *Across projects:* regenerating the
RHOAI install's mirror config produces objects named `idms-operator-0` /
`idms-generic-0`, and applying a narrower set silently deletes rules other
workloads rely on. *Against yourself:* oc-mirror regenerates those files from
whatever was in the **current** archive, so on an incremental run applying them
deletes the rules for everything mirrored earlier. That happened here — the
ModelCar rule vanished hours after a successful mirror and the images reported
"no mirror rule" while sitting in the registry. Phase 18 now **unions** rules
keyed by source; they only accumulate.

**oc-mirror archives are incremental against the LOW side's history, not the
destination registry.** Re-run phase 10 after a successful push and you get a
near-empty delta archive; feeding that to `diskToMirror` fails with
`manifest unknown ... localhost:55000`, which reads as corruption but means
"nothing new in the box". Phase 18 checks the registry first and skips the push
when everything is already there. To force a full archive:

```bash
rm -rf /mnt/mirror/llmd-mirror/working-dir && ./deploy-llmd.sh 10
```

**`rsync --append` corrupts a regenerated archive.** It is only safe when
resuming an *interrupted* copy of an *unchanged* file. Every incremental
oc-mirror run rebuilds the tarball, so `--append` keeps the stale prefix and
bolts a new tail on: right size, wrong content. The transfer reports success and
the error surfaces two steps later. Phase 15 uses `--partial` and verifies a
prefix hash on both sides.

**A full registry looks like `502`, not a disk error.** The real cause
(`ENOSPC`) is only inside the container log. Orphaned partial uploads under
`<storage>/uploads` are never committed and are safe to delete when no push is
running — 213 GiB was reclaimed that way. Phase 18 checks free space first.

**A cached image is not a mirrored image.** The vLLM CUDA runtime was running
happily from a node's local CRI-O cache while absent from the mirror entirely.
It survives reboots but not node replacement.

**Two inspection tools, opposite blind spots.** `podman manifest inspect` refuses
single-arch images; `oc image info` refuses manifest lists without
`--filter-by-os`. ModelCars are single-arch and the RHOAI components are lists,
so either tool alone is wrong about half of them.

**Kuadrant attaches an AuthPolicy to llm-d routes.** Where Models-as-a-Service is
deployed, the generated HTTPRoute picks up `openshift-ai-inference-authn`. It is
also why route status must be read across all `parents`, not `parents[0]`.

---

## References

- [disconnected-rhoai](https://github.com/rh-aiservices-bu/disconnected-rhoai) — builds the cluster this deploys onto
- [rhoai-maas-guide, Phase 0: Disconnected](https://github.com/rh-aiservices-bu/rhoai-maas-guide/blob/main/content/modules/ROOT/pages/00-disconnected.adoc) — GPU driver approach and the `rhaii/` registry path
- [Red Hat AI Inference 3.4 — llm-d prerequisites](https://docs.redhat.com/en/documentation/red_hat_ai_inference/3.4/html/deploy_distributed_inference_with_llm-d_on_openshift_container_platform/prerequisites-llmd-on-openshift_llmd-on-openshift)
- [LeaderWorkerSet Operator](https://docs.redhat.com/en/documentation/openshift_container_platform/latest/html/ai_workloads/leader-worker-set-operator)
