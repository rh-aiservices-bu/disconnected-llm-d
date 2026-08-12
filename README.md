# llm-d on a disconnected RHOAI cluster

Deploys llm-d onto the CRIAB lab cluster — OpenShift 4.20 and RHOAI 3.4.2, no
egress, images served from Quay on the high side.

This repo is the **llm-d layer only**. [CRIAB](../criab) builds everything
underneath it and owns the mirror pipeline, the cluster and the credentials.
Read [CRIAB's cheatsheet](../criab/CHEATSHEET.md) first — the SSH topology, the
`/mnt/mirror` disk rule and the tmux conventions all apply here unchanged.

```
./deploy-llmd.sh low     # jump box   : preflight, stage the model images
./deploy-llmd.sh high    # cluster    : verify, configure, deploy, test
./deploy-llmd.sh list    # show phases
```

---

## Prerequisites, and where each one comes from

Red Hat's [llm-d prerequisites](https://docs.redhat.com/en/documentation/red_hat_ai_inference/3.4/html/deploy_distributed_inference_with_llm-d_on_openshift_container_platform/prerequisites-llmd-on-openshift_llmd-on-openshift)
assume a connected cluster, where the `rhai-on-openshift` Helm chart pulls from
`registry.redhat.io` and installs the missing pieces itself. That chart cannot
run here, so each prerequisite has to be satisfied some other way.

| Prerequisite | Here |
|:--|:--|
| OpenShift 4.19+ | 4.20.30 ✓ — phase 05 checks |
| GPU node pool | none by default — `scripts/12-gpu-machineset.sh` provisions an L40S |
| NVIDIA GPU Operator | installed by CRIAB; the **driver build** is the hard part — see [GPU](#the-gpu-node) |
| Gateway `openshift-ai-inference` in `openshift-ingress` | `manifests/gateway/` — but see [§3](#3-the-gateway-pulls-in-service-mesh-from-a-catalog-that-was-disabled) |
| LeaderWorkerSet Operator | Helm would install it; here `scripts/16-install-lws.sh`, and it must be mirrored first |
| Service Mesh v2 **absent** | phase 05 fails if it is present — it conflicts with the Sail operator |
| LoadBalancer | AWS NLB, but it must be **internal** — phase 40 patches it |
| User Workload Monitoring | phase 05 warns and prints the patch |
| 50 GB per GPU node | MachineSet defaults to 200 GB; phase 05 checks the running node |
| Model weights from a registry | no egress — ModelCar, see [§1](#1-model-weights-cannot-come-from-hugging-face) |

**LeaderWorkerSet is optional for what this repo deploys by default.** The
KServe controller calls `IsCrdAvailable` for `LeaderWorkerSet` and only watches
it when the CRD exists; single-node replicas reconcile into a plain Deployment.
It becomes required for multi-node — disaggregated prefill/decode, or a model
too large for one node. Phase 05 warns rather than fails.

---

## What changes when you go disconnected

A connected llm-d deployment (see [rhaoi3-llm-d](../rhaoi3-llm-d)) is roughly
"apply an `LLMInferenceService` and wait". Five things break without egress, and
this repo exists to handle them.

### 1. Model weights cannot come from Hugging Face

`uri: hf://Qwen/Qwen3-4B` makes the KServe storage-initializer reach
`huggingface.co`. That host does not exist from this cluster, and the pod sits
in `Init` until the timeout.

The fix is **ModelCar**: the weights are packaged as an ordinary container image
and referenced with `oci://`. They then travel the same mirror path as every
other image, and `IDMS` redirects the pull to Quay exactly as it does for the
vLLM runtime.

```yaml
# connected
uri: hf://Qwen/Qwen3-4B

# disconnected — manifests/qwen3-4b/llm-inference-service.yaml
uri: oci://quay.io/redhat-ai-services/modelcar-catalog@sha256:2252a63e...
```

Note the manifest still names `quay.io`, not the mirror registry. That is the
CRIAB convention and it matters: `IDMS` does the redirection, so the manifest
stays portable instead of being welded to one lab.

### 2. ModelCar is off by default

KServe refuses `oci://` model URIs unless `enableModelcar` is true in the
`inferenceservice-config` ConfigMap:

```
OCI modelcars is not enabled
```

That surfaces as a reconcile failure on the `LLMInferenceService`, not as
anything image-shaped, which is what makes it expensive to diagnose.
`scripts/30-enable-modelcar.sh` sets it and restarts the KServe controller —
the controller caches this config at startup, so without the restart the patch
reads as applied and does nothing.

The same script **clears `uidModelcar`** if it is set. KServe applies that value
as `runAsUser` on both the ModelCar sidecar and the main serving container, and
OpenShift's `restricted-v2` SCC rejects any UID outside the namespace's assigned
range. Unset is the only workable setting here.

### 3. The Gateway pulls in Service Mesh, from a catalog that was disabled

Creating a `GatewayClass` with controller
`openshift.io/gateway-controller/v1` makes the cluster-ingress-operator create an
OLM Subscription for `servicemeshoperator3` — from a CatalogSource named
**`redhat-operators`** in `openshift-marketplace`, hard-coded.

On a disconnected cluster that source was disabled along with the rest of the
defaults. Nothing resolves, the GatewayClass stays `Accepted=Unknown` forever,
the Gateway is never `Programmed`, and requests 404. Meanwhile the DSC still
reports Ready, so nothing points at the actual problem.

CRIAB handles this in its phase 30 by aliasing the *mirrored* index under the
name `redhat-operators` when `INSTALL_SERVICE_MESH3=true`. This repo's preflight
checks for that CatalogSource rather than assuming it, and phase 40 fails with
the diagnosis rather than an anonymous timeout.

### 4. Nothing may be assumed to be in the mirror

`scripts/20-verify-mirror.sh` reads the images the *running cluster* says llm-d
will pull — out of the `LLMInferenceServiceConfig` presets and the KServe config
— and checks each one against Quay with `podman manifest inspect` before
anything is deployed. Finding a gap here costs a minute; finding it after a
7.6 GiB pull and a MachineConfig rollout costs an afternoon.

Only the ModelCar images actually need adding to the mirror. The vLLM runtime,
the endpoint picker, the storage initializer and the Istio proxy all arrive
through the RHOAI and OSSM 3 operator bundles CRIAB already mirrors. Phase 20
verifies that claim instead of trusting it.

> **Watch the registry path for vLLM.** The runtime is published under
> `registry.redhat.io/rhaii/vllm-cuda-rhel9` — one `i`, no trailing `s`. Several
> upstream examples (including the connected reference repo) use `rhaiis/`,
> which is not covered by the IDMS and fails only on a disconnected cluster.
> [RHOAIENG-82814](https://redhat.atlassian.net/browse/RHOAIENG-82814). This
> repo does not hard-code the runtime image — the KServe presets supply it — but
> if you add your own `ServingRuntime`, check the path.

### 5. The GPU node is the hardest part

Big enough that it has [its own section](#the-gpu-node).

---

## The GPU node

Two separate jobs: get a GPU instance into the cluster, and get the NVIDIA
driver to build on it without internet. The second is where the time goes.

### Provisioning an L40S node

```bash
./deploy-llmd.sh 12
```

Every cluster-specific value — AMI, subnet, security group, IAM profile — is
cloned from the existing worker MachineSet. Nothing is written down, because a
stale AMI produces an instance that boots and never joins, and the only evidence
is in the machine-controller log.

L40S on AWS is the **g6e** family, 48 GB VRAM per GPU:

| Type | GPUs | VRAM | Use |
|:--|:--|:--|:--|
| `g6e.2xlarge` | 1× L40S | 48 GB | default |
| `g6e.12xlarge` | 4× L40S | 192 GB | 4 llm-d replicas |
| `g5.2xlarge` | 1× A10G | 24 GB | fallback where g6e is not offered |

The script checks `describe-instance-type-offerings` before applying, because
g6e is not in every AZ and the failure otherwise is a Machine stuck in
`Provisioning` with the reason buried in a controller log. It also prints the
G-family vCPU quota command — a zero quota is the other silent failure, and it
looks identical.

It **spends money** and asks you to type the instance type to confirm.

The `nvidia.com/gpu:NoSchedule` taint is **off by default**. It keeps cheap
workloads off an expensive node, but every DaemonSet that must run there (NFD
worker, the driver, the device plugin) has to tolerate it — and when one does
not, the symptom is a GPU node reporting no capacity, which is indistinguishable
from a driver failure. Turn it on with `GPU_TAINT=true` once the stack works.

### Getting the driver to build

**Run the diagnosis first. Do not start building anything.**

```bash
./deploy-llmd.sh 14 diagnose
```

The GPU operator compiles its kernel module on the node at runtime, and needs
two things it normally downloads. They fail independently:

| Half | Where it comes from | Usually |
|:--|:--|:--|
| kernel-devel / kernel-headers | the Driver Toolkit image, which is **in the OCP release payload and therefore already mirrored** | fine |
| CUDA development packages | `developer.download.nvidia.com` | **broken** |

That asymmetry is the point. The kernel half is solved by OpenShift itself as
long as the ClusterPolicy has `operator.use_ocp_driver_toolkit: true`, so the
usual answer is that only the CUDA half needs work. `diagnose` reads the driver
pod logs, matches the signatures that distinguish the two, and tells you which
subcommands you actually need. Doing the kernel half when you did not need it
costs an hour and changes nothing.

It also checks NFD health, because a partial NFD upgrade leaves `nfd-master`
not Ready on a missing `nodefeaturegroups` CRD, nothing gets labelled, and the
result presents as a GPU problem rather than an NFD one.

If the CUDA half is broken:

```bash
# LOW side — the only host with internet
./deploy-llmd.sh 14 fetch-cuda
rsync -avP /mnt/mirror/cuda-rpms.tar.gz lab-user@$HIGH_IP:/mnt/mirror/

# HIGH side
tar -xzf /mnt/mirror/cuda-rpms.tar.gz -C /mnt/mirror/
./deploy-llmd.sh 14 build-repo     # DTK kernel packages + CUDA -> repo image -> Quay
./deploy-llmd.sh 14 deploy-repo    # run it in-cluster
./deploy-llmd.sh 14 patch          # point the ClusterPolicy at it
./deploy-llmd.sh 14 verify         # wait for nvidia.com/gpu capacity
```

`CUDA_VERSION` must match what the driver expects; `diagnose` prints how to read
it off the ClusterPolicy.

### Why the repo runs in-cluster

The obvious fix is `python3 -m http.server` on the high side. It works, and it
breaks the next time anything restarts.

The driver pod runs `dnf install` **every time it starts** — node reboots,
MachineSet scale-ups, operator upgrades, ClusterPolicy edits — not once at
install. A background process on a jump host is not there for any of those, and
when it is gone the GPU silently stops working. The MaaS guide's team hit this
and filed [RHOAIENG-82815](https://redhat.atlassian.net/browse/RHOAIENG-82815)
because there is no good upstream answer yet.

So `build-repo` bakes the RPMs into an image, pushes it to Quay, and
`deploy-repo` runs it as a Deployment in `nvidia-gpu-operator` with a Service at
`http://gpu-kernel-repo.nvidia-gpu-operator.svc:8080/`. That survives everything
the cluster does to itself, and it is reproducible from the mirror after a
rebuild — which is the whole point of the environment.

Pass `--bastion` to `build-repo` for the throwaway version when you just need
the GPU working in the next ten minutes.

The httpd base image must itself be mirrored. It is in
`config/additional-images.txt` for that reason — mirror it in the same batch as
the models, because discovering you need it later costs another full low→high
round trip.

---

## Setup

```bash
cp config/llmd.env.example config/llmd.env
```

The only value most people touch is `CRIAB_DIR` — and it self-detects `~/criab`
and `~/projects/criab`, so usually nothing. Registry, credentials and host
addresses are read from CRIAB's `config/criab.env`; they are deliberately not
duplicated here, because two copies of `MIRROR_REGISTRY` is how you end up
pushing to a registry the cluster does not trust.

Sync to the lab hosts with CRIAB's `remote.sh`, pointing it at this repo:

```bash
cd ../criab
REMOTE_DIR=/home/lab-user/disconnected-llm-d \
  REPO_ROOT=$(cd ../disconnected-llm-d && pwd) scripts/remote.sh sync low
```

Or plainly:

```bash
rsync -az -e 'ssh -F ../criab/.ssh-config' --exclude .git \
  ./ criab-low:/home/lab-user/disconnected-llm-d/
rsync -az -e 'ssh -F ../criab/.ssh-config' --exclude .git \
  ./ criab-high:/home/lab-user/disconnected-llm-d/
```

---

## Runbook

Start with `qwen2.5-0.5b`. It is 0.9 GiB against the 4B model's 7.6 GiB and
exercises the identical path — mirror, ModelCar, vLLM, scheduler, Gateway,
HTTPRoute. Prove the plumbing cheaply, then switch `LLMD_MODEL` to `qwen3-4b`.

### Step 1 — low side: stage the model images

```bash
ssh -F ../criab/.ssh-config criab-low
cd ~/disconnected-llm-d
./deploy-llmd.sh low
```

This checks the images are reachable, then appends their digest-pinned
references to CRIAB's `config/additional-images.txt`. It does not mirror
anything by itself; it prints the commands. Pass `--mirror` to phase 10 if you
want it to run them.

### Step 2 — low side: run the mirror pipeline

Long. Under `nohup` with a per-run log, per the CRIAB convention:

```bash
cd ~/criab
nohup bash -c './deploy-rhoai.sh 10 && ./deploy-rhoai.sh 15' \
  > /mnt/mirror/llmd-mirror.log 2>&1 &
```

Chained with `&&`, not two background jobs — phase 15 rsyncs the archive phase
10 produces.

Judge progress by the artifact growing, never by process liveness:

```bash
f=/mnt/mirror/criab-mirror/mirror_seq1.tar
a=$(stat -c %s $f); sleep 30; b=$(stat -c %s $f)
echo "$(( (b-a)/1048576 )) MB in 30s"
```

### Step 3 — high side: push into Quay

```bash
ssh -F ../criab/.ssh-config criab-high
cd ~/criab && nohup ./deploy-rhoai.sh 20 > /mnt/mirror/llmd-push.log 2>&1 &
```

### Step 3b — high side: one-time cluster setup

Only needed once per environment, and deliberately **not** part of
`./deploy-llmd.sh high` — provisioning a node spends money and takes 15 minutes,
and the driver work has to be read rather than automated past.

```bash
./deploy-llmd.sh 12                # GPU node (skip if one already works)
./deploy-llmd.sh 14 diagnose       # then follow what it tells you
./deploy-llmd.sh 16                # LeaderWorkerSet — optional for single-node
```

### Step 4 — high side: deploy

```bash
cd ~/disconnected-llm-d
source ~/criab/scripts/ocp/oc-login.sh      # source it, do not execute it
tmux new -s llmd
./deploy-llmd.sh high 2>&1 | tee /mnt/mirror/llmd.log
```

Detach with `Ctrl-b d`; reattach with `tmux attach -t llmd`. Check on it without
attaching:

```bash
tail -40 /mnt/mirror/llmd.log
tmux capture-pane -pt llmd -S -60
```

Phase 40 prints `llm-d deploy complete` and phase 50 prints
`llm-d verify complete`. Poll for those markers rather than guessing from
process state.

### Step 5 — scale up to the demo model

```bash
sed -i 's/^LLMD_MODEL=.*/LLMD_MODEL="qwen3-4b"/' config/llmd.env
sed -i 's/^LLMD_REPLICAS=.*/LLMD_REPLICAS="4"/' config/llmd.env   # needs 4 GPUs
./deploy-llmd.sh 40 && ./deploy-llmd.sh 50
```

`prefix-cache-scorer` — the whole point of llm-d over plain vLLM — is inert at
one replica. It only does anything once there is more than one replica for it to
choose between, so the routing benefit does not appear until you scale.

---

## Phases

| | | |
|:--|:--|:--|
| `00` | low | preflight — images reachable, CRIAB config found, disk free |
| `10` | low | append ModelCar + httpd refs to CRIAB's mirror list |
| `05` | high | preflight — version, CRDs, ModelCar config, catalog, LWS, OSSM v2, UWM, GPU, storage, IDMS |
| `20` | high | verify every required image is in Quay |
| `30` | high | enable `enableModelcar`, clear `uidModelcar`, restart controller |
| `40` | high | Gateway (+ internal NLB), namespace, `LLMInferenceService`; wait |
| `50` | high | port-forward the Gateway and send a real completion request |
| `90` | high | teardown (`--all` also removes namespace and Gateway) |

One-time cluster setup, run separately:

| | | |
|:--|:--|:--|
| `12` | high | GPU MachineSet — L40S/g6e (`--show`, `--delete`) |
| `14` | both | GPU driver: `diagnose`, `fetch-cuda`, `build-repo`, `deploy-repo`, `patch`, `verify` |
| `16` | high | LeaderWorkerSet Operator (`--check`) |

Every phase is runnable on its own: `./deploy-llmd.sh 40`. All of them accept
`DRY_RUN=true`.

---

## Layout

```
deploy-llmd.sh              phase driver
config/
  llmd.env.example          the only file you edit
  additional-images.txt     what this project adds to the mirror, and why
  imageset-config-llmd.yaml oc-mirror config for the LeaderWorkerSet operator
manifests/
  base/                     namespace + gpu-profile HardwareProfile
  gateway/                  GatewayClass + Gateway
  gpu/
    machineset-l40s.yaml    g6e MachineSet template (envsubst)
    kernel-repo.yaml        in-cluster kernel/CUDA package repo
  qwen2.5-0.5b/             smoke-test model, 0.9 GiB, 1 GPU
  qwen3-4b/                 demo model, 7.6 GiB, 1 GPU per replica
scripts/
  lib/common.sh             logging, config loading, mirror checks
  00-preflight.sh  10-stage-images.sh  20-verify-mirror.sh
  12-gpu-machineset.sh  14-gpu-driver-disconnected.sh  16-install-lws.sh
  30-enable-modelcar.sh  40-deploy.sh  50-verify.sh  90-teardown.sh
```

The manifests stand alone if you would rather not use the scripts:

```bash
oc apply -f manifests/gateway/gateway.yaml
oc apply -k manifests/qwen2.5-0.5b
```

You still need phase 30 first, or the `oci://` URI is rejected.

---

## Calling the model

llm-d routes by path — `/{namespace}/{name}/v1/...` — so the namespace and the
`LLMInferenceService` name are both part of the URL.

In-cluster:

```
http://openshift-ai-inference-openshift-default.openshift-ingress.svc.cluster.local/demo-llm/qwen3-4b/v1
```

From the high side:

```bash
oc port-forward -n openshift-ingress svc/openshift-ai-inference-openshift-default 8080:80 &

curl -s http://localhost:8080/demo-llm/qwen3-4b/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen3-4B","messages":[{"role":"user","content":"hello"}]}' | jq
```

The `model` field must match `spec.model.name`, not the resource name. Phase 50
reads it from `/v1/models` rather than assuming, because a mismatch returns a
404 that reads exactly like a routing failure.

---

## When it does not work

Work down this list; it is ordered by how often each one is the answer.

| Symptom | Cause |
|:--|:--|
| `ImagePullBackOff` on the ModelCar | not mirrored — run phase 20, it says which |
| Pod `Pending`, no node matches | no `nvidia.com/gpu` capacity; run `14 diagnose` |
| GPU node exists, no `nvidia.com/gpu` | driver did not build — `14 diagnose`, almost always the CUDA half |
| Machine stuck `Provisioning` | g6e not offered in the AZ, or G-family vCPU quota is 0 |
| `nfd-master` not Ready | partial NFD upgrade, missing `nodefeaturegroups` CRD — nothing gets labelled |
| GPU works, then stops after a reboot | the kernel repo was served from a shell, not in-cluster |
| `OCI modelcars is not enabled` | phase 30 not run, or controller not restarted |
| Sidecar `CreateContainerError` | `uidModelcar` is set; phase 30 clears it |
| GatewayClass `Accepted=Unknown` | no `redhat-operators` CatalogSource — see §3 |
| Gateway programmed, but times out / EOF | external NLB with public IPs; phase 40 patches to internal |
| Gateway programmed, requests 404 | wrong path, or `model` field ≠ `spec.model.name` |
| `manifest unknown` on a vLLM image | `rhaiis/` instead of `rhaii/` — RHOAIENG-82814 |
| Scheduler logs show HF fetch attempts | drop `prefix-cache-scorer` from the plugin list and re-apply; the other two scorers need no tokenizer |

An `x509` or `manifest unknown` error means the image was never mirrored.
`pull QPS exceeded` is kubelet throttling and clears on its own.

Before blaming the cluster:

```bash
oc get llminferenceservice -n demo-llm -o yaml | yq '.items[].status'
oc get pods -n demo-llm
oc logs -n demo-llm -l app.kubernetes.io/part-of=qwen3-4b -c main --tail=100
oc get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.capacity.nvidia\.com/gpu
df -h / /mnt/mirror
```

---

## References

- [CRIAB cheatsheet](../criab/CHEATSHEET.md) — SSH topology, mirror pipeline, disk rules
- [rhoai-maas-guide, Phase 0: Disconnected Setup](https://github.com/rh-aiservices-bu/rhoai-maas-guide/blob/main/content/modules/ROOT/pages/00-disconnected.adoc)
  — where the GPU driver approach, the `rhaii/` path and the internal-NLB patch come from
- [Red Hat AI Inference 3.4 — llm-d prerequisites](https://docs.redhat.com/en/documentation/red_hat_ai_inference/3.4/html/deploy_distributed_inference_with_llm-d_on_openshift_container_platform/prerequisites-llmd-on-openshift_llmd-on-openshift)
- [LeaderWorkerSet Operator](https://docs.redhat.com/en/documentation/openshift_container_platform/latest/html/ai_workloads/leader-worker-set-operator)
- [rhaoi3-llm-d](../rhaoi3-llm-d) — the connected version this adapts

---

## Things deliberately not done

- **No Grafana/Prometheus stack.** The reference repo ships one using
  `grafana/grafana:latest` and `prom/prometheus:v2.45.0` from Docker Hub —
  unmirrored, and floating tags at that. The namespace carries
  `openshift.io/cluster-monitoring: "true"`, so vLLM metrics land in the
  in-cluster Prometheus. Mirror the dashboards separately if you want them.
- **No benchmark jobs.** `guidellm` and the multi-turn benchmark pull from
  `ghcr.io` and `quay.io/hayesphilip`, and the guidellm job also downloads a
  tokenizer from Hugging Face at runtime. Both need real work to run
  disconnected — a separate exercise from getting llm-d serving.
- **No mirror deletion in teardown.** Removing images from Quay breaks node
  reboot, scale and upgrade for every project on the cluster.
- **PVC-backed weights.** `pvc://` is supported by KServe and is the alternative
  to ModelCar. It needs a populated PVC, which means a transfer job and an RWX
  volume, and it is not reproducible from the mirror after a rebuild. ModelCar
  rides the pipeline that already exists.
