# llm-d on a disconnected RHOAI install

Deploys **llm-d** — distributed LLM inference — onto an air-gapped OpenShift AI
cluster, where nothing can reach `quay.io`, `registry.redhat.io` or
`huggingface.co` and every image must be in the local mirror registry first.

It assumes OpenShift and RHOAI are already installed and healthy. Building that
underneath is a separate job:
**[rh-aiservices-bu/disconnected-rhoai](https://github.com/rh-aiservices-bu/disconnected-rhoai)**.

---

## Contents

- [What gets deployed](#what-gets-deployed)
- [What gets mirrored](#what-gets-mirrored)
- [Prerequisites](#prerequisites)
- **[Part 1 — Manual walkthrough](#part-1--manual-walkthrough)** — every command and manifest, no scripts
- **[Part 2 — Scripted](#part-2--scripted)** — the same thing in five commands
- [GPU setup](#gpu-setup)
- [Troubleshooting](#troubleshooting)
- [Field notes](#field-notes)

> **Which part should I read?**
> Part 1 if you are on a cluster you reach some other way — a bastion, a VPN, a
> web terminal — or if you want to understand what is happening. Part 2 if your
> environment matches the two-hop jump-box layout the scripts expect.
> They do exactly the same thing.

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

Eight images, about **27 GB**. [Step 1](#step-1--find-out-which-images-your-cluster-needs)
discovers the exact list from your cluster — the digests are specific to your
RHOAI version, so this table is illustrative, not a fixed list.

| Image | Size | Why |
|:--|:--|:--|
| `quay.io/redhat-ai-services/modelcar-catalog` *(qwen2.5-0.5b-instruct)* | 0.9 GiB | model weights, smoke test |
| `quay.io/redhat-ai-services/modelcar-catalog` *(qwen3-4b)* | 7.6 GiB | model weights, demo |
| `registry.redhat.io/rhaii/vllm-cuda-rhel9` | 16 GiB | the vLLM serving runtime |
| `registry.redhat.io/rhoai/odh-llm-d-inference-scheduler-rhel9` | small | the endpoint picker |
| `registry.redhat.io/rhoai/odh-llm-d-routing-sidecar-rhel9` | small | request routing |
| `registry.redhat.io/rhoai/odh-llm-d-kv-cache-rhel9` | 4.4 GiB | KV-cache support |
| `registry.redhat.io/rhoai/odh-kserve-storage-initializer-rhel9` | small | unpacks the ModelCar |
| `registry.access.redhat.com/ubi9/httpd-24` | 250 MB | only for the [GPU driver workaround](#the-driver-cannot-build-disconnected) |

Three things worth knowing:

* **The model weights are the reason this is not just an `oc apply`.** A normal
  llm-d deployment fetches them from Hugging Face at runtime. Here they travel
  as a container image (KServe *ModelCar*) through the same mirror as everything
  else.
* **The four llm-d components are usually missing even on a healthy cluster.**
  Nothing pulls them until the first `LLMInferenceService` exists, so a RHOAI
  install can report `Ready` for weeks with none of them mirrored. All four were
  absent on the cluster this was built against.
* **Only the accelerator you own is mirrored.** RHOAI also declares ROCm, Gaudi
  and Spyre runtimes; drop the ones your nodes cannot schedule and save tens of
  gigabytes.

---

## Prerequisites

| | |
|:--|:--|
| A disconnected cluster | OpenShift 4.19+, RHOAI 3.4+, `DataScienceCluster` Ready |
| Built with | [disconnected-rhoai](https://github.com/rh-aiservices-bu/disconnected-rhoai) |
| A **connected** host | to run `oc-mirror`; called the *low side* below |
| A **disconnected** host | with `oc` access to the cluster and to the mirror registry; the *high side* |
| A GPU with free capacity | see [GPU setup](#gpu-setup) |
| Free disk | ~60 GB on each host, ~60 GB in the mirror registry |
| A Red Hat pull secret | on the connected host, for `registry.redhat.io` |
| `oc`, `oc-mirror` v2, `podman`, `jq` | on the relevant hosts |

Set these once; every command below uses them.

```bash
# On BOTH hosts
export MIRROR_REGISTRY="<registry-host>:8443"     # e.g. ip-10-0-53-10...:8443
export MIRROR_NS="llmd"                           # our own namespace in the registry
export WORKDIR="/mnt/mirror/llmd-mirror"          # NOT on /, see note below
export KSERVE_NS="redhat-ods-applications"
export LLMD_NS="demo-llm"
```

> **Keep payload off `/`.** `oc-mirror` caches under `$HOME/.oc-mirror` and the
> archive is tens of gigabytes. On some lab images filling `/` leaves no room
> for a DHCP lease, and the host reboots without an IP — recoverable only from
> the serial console.

---

# Part 1 — Manual walkthrough

Nine steps. Steps 1–5 get the images into the registry; steps 6–9 deploy.

## Step 1 — Find out which images your cluster needs

**On the disconnected (high) side**, with `oc` logged in.

Do not use a fixed list. The digests come from the
`LLMInferenceServiceConfig` presets your RHOAI version ships, and they change
every z-stream.

```bash
# The llm-d component images (scheduler, routing sidecar, KV-cache, runtimes)
oc get llminferenceserviceconfig -A -o json \
  | jq -r '[.. | .image? // empty] | unique[]'

# The storage initializer, which lives in the KServe config instead
oc get configmap inferenceservice-config -n $KSERVE_NS \
  -o jsonpath='{.data.storageInitializer}' | jq -r '.image'
```

Typical output:

```
registry.redhat.io/rhaii/vllm-cuda-rhel9@sha256:5800e12b...
registry.redhat.io/rhaii/vllm-gaudi-rhel9@sha256:71008b21...
registry.redhat.io/rhaii/vllm-rocm-rhel9@sha256:df4d60e7...
registry.redhat.io/rhaii/vllm-spyre-rhel9@sha256:67443bfc...
registry.redhat.io/rhoai/odh-llm-d-inference-scheduler-rhel9@sha256:3b630017...
registry.redhat.io/rhoai/odh-llm-d-kv-cache-rhel9@sha256:8f684d88...
registry.redhat.io/rhoai/odh-llm-d-routing-sidecar-rhel9@sha256:18dbf82a...
registry.redhat.io/rhoai/odh-kserve-storage-initializer-rhel9@sha256:83bebb2e...
```

**Keep only the runtime for the accelerator you actually have.** On an NVIDIA
cluster, drop `vllm-gaudi`, `vllm-rocm` and `vllm-spyre` — they are declared
regardless of hardware and can never be scheduled. That is ~30 GB saved.

Check what you have:

```bash
oc get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.capacity.nvidia\\.com/gpu
```

> **IMPORTANT — the vLLM registry path is `rhaii`, one `i`, no trailing `s`.**
> Several upstream examples use `rhaiis/`, which is not covered by the IDMS and
> fails only on a disconnected cluster.
> ([RHOAIENG-82814](https://redhat.atlassian.net/browse/RHOAIENG-82814))

Write the final list — the images above plus the model weights — to a file:

```bash
cat > required-images.txt <<'EOF'
# model weights (ModelCar)
quay.io/redhat-ai-services/modelcar-catalog@sha256:e20441c23be795838409137576b9016e6bc941eec79e5765cf9de6319c0ec769
quay.io/redhat-ai-services/modelcar-catalog@sha256:2252a63e6f0f36df27ace6497330dfba61b7501024cf44fa67480d3848471809

# httpd base, only needed for the disconnected GPU driver workaround
registry.access.redhat.com/ubi9/httpd-24:latest

# llm-d components — REPLACE with the digests your cluster printed above
registry.redhat.io/rhaii/vllm-cuda-rhel9@sha256:5800e12b...
registry.redhat.io/rhoai/odh-kserve-storage-initializer-rhel9@sha256:83bebb2e...
registry.redhat.io/rhoai/odh-llm-d-inference-scheduler-rhel9@sha256:3b630017...
registry.redhat.io/rhoai/odh-llm-d-kv-cache-rhel9@sha256:8f684d88...
registry.redhat.io/rhoai/odh-llm-d-routing-sidecar-rhel9@sha256:18dbf82a...
EOF
```

Copy this file to the connected host.

## Step 2 — Mirror to disk

**On the connected (low) side.**

Stage the pull secret where `oc-mirror` looks for it — not `~/pull-secret.json`:

```bash
mkdir -p ${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/containers
cp ~/pull-secret.json ${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/containers/auth.json
```

Build an `ImageSetConfiguration` from the list:

```bash
mkdir -p "$WORKDIR"
{
  echo 'apiVersion: mirror.openshift.io/v2alpha1'
  echo 'kind: ImageSetConfiguration'
  echo 'mirror:'
  echo '  additionalImages:'
  grep -vE '^\s*#|^\s*$' required-images.txt | sed 's/^/    - name: /'
} > "$WORKDIR/imageset-config.yaml"

cat "$WORKDIR/imageset-config.yaml"
```

It should look like this:

```yaml
apiVersion: mirror.openshift.io/v2alpha1
kind: ImageSetConfiguration
mirror:
  additionalImages:
    - name: quay.io/redhat-ai-services/modelcar-catalog@sha256:e20441c2...
    - name: quay.io/redhat-ai-services/modelcar-catalog@sha256:2252a63e...
    - name: registry.access.redhat.com/ubi9/httpd-24:latest
    - name: registry.redhat.io/rhaii/vllm-cuda-rhel9@sha256:5800e12b...
    - name: registry.redhat.io/rhoai/odh-kserve-storage-initializer-rhel9@sha256:83bebb2e...
    - name: registry.redhat.io/rhoai/odh-llm-d-inference-scheduler-rhel9@sha256:3b630017...
    - name: registry.redhat.io/rhoai/odh-llm-d-kv-cache-rhel9@sha256:8f684d88...
    - name: registry.redhat.io/rhoai/odh-llm-d-routing-sidecar-rhel9@sha256:18dbf82a...
```

Run it. This takes 10–20 minutes on a first run:

```bash
oc-mirror --v2 --config "$WORKDIR/imageset-config.yaml" "file://$WORKDIR"
```

> **Use a separate `WORKDIR` and a separate ImageSetConfiguration from your RHOAI
> mirror.** Re-running the RHOAI install's mirror to add these images
> regenerates its `idms-operator-0` / `idms-generic-0` objects, and applying
> those *replaces* rather than merges — silently deleting mirror rules other
> workloads depend on. A separate batch keeps this additive.

Judge success by the artifact, not the exit code — `oc-mirror` returns non-zero
for soft failures too:

```bash
ls -lh "$WORKDIR"/*.tar
```

## Step 3 — Transfer to the disconnected side

```bash
rsync -a --partial --info=progress2 \
  "$WORKDIR/" lab-user@<HIGH_SIDE>:"$WORKDIR/"
```

> **Do NOT use `rsync --append`.** It is only safe when resuming an
> *interrupted* copy of an *unchanged* file. Every incremental `oc-mirror` run
> rebuilds the tarball, so `--append` keeps the stale prefix and bolts a new tail
> onto it — producing a file of exactly the right **size** and the wrong
> **content**. The transfer reports success and the failure surfaces two steps
> later as `manifest unknown` from `localhost:55000`.

Verify the copy. Size alone proves nothing — that is precisely what `--append`
gets wrong. Hash a prefix on both hosts and compare:

```bash
# run on BOTH, compare the output
head -c 200000000 "$WORKDIR"/mirror_000001.tar | sha256sum
stat -c %s "$WORKDIR"/mirror_000001.tar
```

If they differ, delete the remote copy and transfer again.

## Step 4 — Push into the mirror registry

**On the disconnected (high) side.**

First check the registry has room. A full registry fails as `502 Bad Gateway` on
every upload, and the real cause (`ENOSPC`) is visible only inside the container
log:

```bash
df -h <quay-storage-path>      # e.g. ~/.local/share/containers/storage/volumes/quay-storage/_data
```

If it is full, orphaned partial uploads are never-committed blobs and are safe
to delete when no push is running:

```bash
du -sh <quay-storage-path>/uploads
find <quay-storage-path>/uploads -type f -mmin +360 -delete
```

Authenticate and push:

```bash
podman login --authfile ${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/containers/auth.json \
  -u <registry-user> -p <registry-password> "$MIRROR_REGISTRY"

oc-mirror --v2 \
  --config "$WORKDIR/imageset-config.yaml" \
  --from "file://$WORKDIR" \
  "docker://${MIRROR_REGISTRY}/${MIRROR_NS}"
```

> **`--config` is mandatory in both directions**, and `--from` needs the
> `file://` scheme. Omit either and `oc-mirror` prints its whole usage plus
> `[Executor] use the --config flag it is mandatory`.

## Step 5 — Apply the mirror rules

`oc-mirror` writes `IDMS`/`ITMS` manifests describing how to rewrite pulls:

```bash
ls "$WORKDIR/working-dir/cluster-resources/"
cat "$WORKDIR/working-dir/cluster-resources/idms-oc-mirror.yaml"
```

```yaml
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: idms-generic-0
spec:
  imageDigestMirrors:
    - mirrors:
        - <registry>:8443/llmd/redhat-ai-services
      source: quay.io/redhat-ai-services
    - mirrors:
        - <registry>:8443/llmd/rhaii
      source: registry.redhat.io/rhaii
    - mirrors:
        - <registry>:8443/llmd/rhoai
      source: registry.redhat.io/rhoai
```

> **IMPORTANT — two traps here, and both delete working configuration.**
>
> 1. **Rename it.** `oc-mirror` always emits `idms-generic-0`. Any other
>    oc-mirror batch, from any project, produces the same name and `oc apply`
>    will replace yours. Rename to something project-specific.
> 2. **Merge, do not replace.** `oc apply` replaces the whole object. On an
>    *incremental* run oc-mirror regenerates this file from only what was in the
>    current archive — so applying it deletes the rules for everything you
>    mirrored earlier. This is not hypothetical: it removed the ModelCar rule
>    hours after a successful mirror, and the images then reported "no mirror
>    rule" while sitting in the registry.

Check first whether the object already exists:

```bash
oc get idms,itms
```

A reference copy of the shape it should end up, with both traps documented, is
at [`manifests/mirror/idms-llmd-generic-0.yaml`](manifests/mirror/idms-llmd-generic-0.yaml).

**If it does not exist**, rename and apply:

```bash
sed 's/name: idms-generic-0/name: idms-llmd-generic-0/' \
  "$WORKDIR/working-dir/cluster-resources/idms-oc-mirror.yaml" | oc apply -f -

sed 's/name: itms-generic-0/name: itms-llmd-generic-0/' \
  "$WORKDIR/working-dir/cluster-resources/itms-oc-mirror.yaml" | oc apply -f -
```

**If it already exists**, union the rules instead:

```bash
existing="$(oc get idms idms-llmd-generic-0 -o json | jq -c '[.spec.imageDigestMirrors[]?]')"
new="$(oc create -f "$WORKDIR/working-dir/cluster-resources/idms-oc-mirror.yaml" \
        --dry-run=client -o json | jq -c '[.spec.imageDigestMirrors[]?]')"

jq -n --argjson a "$existing" --argjson b "$new" '
  {apiVersion:"config.openshift.io/v1", kind:"ImageDigestMirrorSet",
   metadata:{name:"idms-llmd-generic-0"},
   spec:{imageDigestMirrors:
     (($a + $b) | group_by(.source)
      | map({source:.[0].source, mirrors:(map(.mirrors[])|unique)}))}}' \
  | oc apply -f -
```

Applying an IDMS triggers a MachineConfig rollout and the nodes reboot. Wait for
it, then **prove the rule reached a node** rather than trusting the condition —
the MCO takes a moment to notice, so polling immediately reports the previous
state:

```bash
sleep 45
oc wait mcp --all --for=condition=Updated --timeout=30m

oc debug node/<any-node> -- chroot /host \
  grep -A3 'redhat-ai-services' /etc/containers/registries.conf
```

Expected:

```
location = "quay.io/redhat-ai-services"
  [[registry.mirror]]
    location = "<registry>:8443/llmd/redhat-ai-services"
    pull-from-mirror = "digest-only"
```

Finally, confirm the images really are in the registry:

```bash
oc image info --registry-config ${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/containers/auth.json \
  --filter-by-os linux/amd64 \
  "${MIRROR_REGISTRY}/${MIRROR_NS}/rhoai/odh-llm-d-inference-scheduler-rhel9@sha256:3b630017..."
```

> **`--filter-by-os` is required for multi-arch images** — without it `oc image
> info` errors out and looks like the image is missing. Conversely `podman
> manifest inspect` refuses *single*-arch images (the ModelCars). Neither tool
> alone is right for the whole list.

## Step 6 — Enable OCI ModelCar in KServe

KServe rejects `oci://` model URIs unless ModelCar support is switched on. The
error appears as a reconcile failure on the `LLMInferenceService` reading
`OCI modelcars is not enabled` — nothing image-shaped.

```bash
oc get configmap inferenceservice-config -n $KSERVE_NS \
  -o jsonpath='{.data.storageInitializer}' | jq .
```

Set `enableModelcar` and remove `uidModelcar`:

```bash
desired="$(oc get configmap inferenceservice-config -n $KSERVE_NS \
  -o jsonpath='{.data.storageInitializer}' \
  | jq -c '.enableModelcar = true | del(.uidModelcar)')"

oc patch configmap inferenceservice-config -n $KSERVE_NS --type merge \
  -p "$(jq -n --arg v "$desired" '{data:{storageInitializer:$v}}')"
```

> **There is deliberately no manifest file for this step.** The value is a JSON
> document inside a ConfigMap string, and a static file would have to restate the
> storage-initializer image digest — which differs per RHOAI version, so
> committing one would overwrite yours with a stale digest. See
> [`manifests/README.md`](manifests/README.md).
>
> **Edit it with `jq`, never `sed`.** The value is a JSON document embedded in a
> ConfigMap string; editing it textually produces a ConfigMap KServe cannot
> parse and a controller that CrashLoops for no visible reason.
>
> **`uidModelcar` must stay unset on OpenShift.** KServe applies it as
> `runAsUser` on both the ModelCar sidecar and the serving container, and the
> `restricted-v2` SCC rejects any UID outside the namespace's assigned range.

Restart the controllers — they cache this config at startup, so without a
restart the patch reads as applied and does nothing:

```bash
oc rollout restart deploy/kserve-controller-manager -n $KSERVE_NS
oc rollout restart deploy/llmisvc-controller-manager -n $KSERVE_NS
oc rollout status  deploy/llmisvc-controller-manager -n $KSERVE_NS --timeout=300s
```

## Step 7 — Create the Gateway

Also available as [`manifests/gateway/gateway.yaml`](manifests/gateway/gateway.yaml)
(`oc apply -f manifests/gateway/gateway.yaml`).

```bash
oc apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: openshift-default
spec:
  controllerName: openshift.io/gateway-controller/v1
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: openshift-ai-inference
  namespace: openshift-ingress
spec:
  gatewayClassName: openshift-default
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All
EOF
```

> **This is the step most likely to stall on a disconnected cluster.** Creating
> the `GatewayClass` makes the cluster-ingress-operator create an OLM
> Subscription for `servicemeshoperator3` from a CatalogSource named
> **`redhat-operators`** — hard-coded, and disabled along with the other default
> sources on a disconnected cluster. Without a CatalogSource under that exact
> name serving your *mirrored* index, the GatewayClass sits at
> `Accepted=Unknown` forever, no Gateway is ever programmed, and the
> DataScienceCluster still reports Ready — so nothing points at the cause.

Verify:

```bash
oc get catalogsource redhat-operators -n openshift-marketplace
oc get gatewayclass openshift-default
oc wait --for=condition=Programmed gateway/openshift-ai-inference \
  -n openshift-ingress --timeout=15m
```

**On AWS**, the Gateway's Service defaults to an *external* NLB with public IPs
that nothing inside a disconnected VPC can reach. The symptom is a Gateway that
programs fine and then times out. Patch it to an internal NLB and delete the
Service so the controller recreates it:

```bash
oc patch gateway openshift-ai-inference -n openshift-ingress --type=merge \
  --patch-file manifests/gateway/internal-nlb-patch.yaml

oc delete svc openshift-ai-inference-openshift-default -n openshift-ingress
```

## Step 8 — Deploy the model

Namespace and (optional) hardware profile — both are in
[`manifests/base/`](manifests/base/), so `oc apply -k manifests/base` does this
step in one command:

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: demo-llm
  labels:
    openshift.io/cluster-monitoring: "true"
EOF
```

Now the `LLMInferenceService`. **The only meaningful difference from a connected
deployment is `spec.model.uri`:**

```yaml
uri: hf://Qwen/Qwen2.5-0.5B-Instruct     # connected — needs huggingface.co
uri: oci://quay.io/...modelcar-catalog@sha256:...   # disconnected
```

Note it still names `quay.io`, not your registry — the IDMS from Step 5 does the
redirection, which keeps the manifest portable.

The complete version — with the HardwareProfile annotations and dashboard
metadata this trimmed copy leaves out — is
[`manifests/qwen2.5-0.5b/llm-inference-service.yaml`](manifests/qwen2.5-0.5b/llm-inference-service.yaml),
and `manifests/qwen3-4b/` holds the larger model.

```bash
oc apply -f - <<'EOF'
apiVersion: serving.kserve.io/v1alpha1
kind: LLMInferenceService
metadata:
  name: qwen25-05b
  namespace: demo-llm
  annotations:
    opendatahub.io/model-type: generative
    security.opendatahub.io/enable-auth: 'false'
spec:
  replicas: 1
  model:
    uri: oci://quay.io/redhat-ai-services/modelcar-catalog@sha256:e20441c23be795838409137576b9016e6bc941eec79e5765cf9de6319c0ec769
    name: Qwen/Qwen2.5-0.5B-Instruct
  router:
    route: {}
    gateway: {}
    scheduler:
      template:
        containers:
          - name: main
            env:
              - name: HF_HOME
                value: /tmp/tokenizer-cache
              - name: XDG_CACHE_HOME
                value: /tmp
            args:
              - '--cert-path'
              - /var/run/kserve/tls
              - '--pool-group'
              - inference.networking.x-k8s.io
              - '--pool-name'
              - '{{ ChildName .ObjectMeta.Name `-inference-pool` }}'
              - '--pool-namespace'
              - '{{ .ObjectMeta.Namespace }}'
              - '--zap-encoder'
              - json
              - '--grpc-port'
              - '9002'
              - '--grpc-health-port'
              - '9003'
              - '--secure-serving'
              - '--model-server-metrics-scheme'
              - https
              - '--config-text'
              - |
                apiVersion: inference.networking.x-k8s.io/v1alpha1
                kind: EndpointPickerConfig
                plugins:
                - type: single-profile-handler
                - type: queue-scorer
                - type: active-request-scorer
                - type: prefix-cache-scorer
                schedulingProfiles:
                - name: default
                  plugins:
                  - pluginRef: queue-scorer
                    weight: 2
                  - pluginRef: active-request-scorer
                    weight: 2
                  - pluginRef: prefix-cache-scorer
                    weight: 3
            volumeMounts:
              - name: tokenizer-cache
                mountPath: /tmp/tokenizer-cache
        volumes:
          - name: tokenizer-cache
            emptyDir: {}
  template:
    tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
    containers:
      - name: main
        env:
          - name: VLLM_ADDITIONAL_ARGS
            value: "--disable-uvicorn-access-log --max-model-len=8192"
        resources:
          limits:   { cpu: '1', memory: 8Gi, nvidia.com/gpu: "1" }
          requests: { cpu: '1', memory: 8Gi, nvidia.com/gpu: "1" }
        livenessProbe:
          httpGet: { path: /health, port: 8000, scheme: HTTPS }
          initialDelaySeconds: 120
          periodSeconds: 30
          failureThreshold: 5
EOF
```

Watch it come up. The first start is slow — the ModelCar image has to be pulled
before vLLM can load it:

```bash
oc get pods -n $LLMD_NS -w
oc wait --for=condition=Ready llminferenceservice/qwen25-05b -n $LLMD_NS --timeout=30m
```

You should end with two pods: the workload (`2/2`, vLLM + ModelCar) and the
router-scheduler (`3/3`, EPP + routing sidecar + KV-cache).

## Step 9 — Verify

```bash
oc get llminferenceservice -n $LLMD_NS
oc get httproute -n $LLMD_NS
```

Send a real request:

```bash
oc port-forward -n openshift-ingress \
  svc/openshift-ai-inference-openshift-default 8080:80 &

curl -s http://localhost:8080/demo-llm/qwen25-05b/v1/models | jq

curl -s http://localhost:8080/demo-llm/qwen25-05b/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen2.5-0.5B-Instruct",
       "messages":[{"role":"user","content":"Reply with exactly: llm-d is serving."}],
       "max_tokens":32,"temperature":0}' | jq -r '.choices[0].message.content'
```

Expected:

```
llm-d is serving.
```

> The `model` field must match `spec.model.name`, **not** the resource name. A
> mismatch returns a 404 that looks exactly like a routing failure — read the
> name from `/v1/models` if unsure.

In-cluster, the endpoint is:

```
http://openshift-ai-inference-openshift-default.openshift-ingress.svc.cluster.local/demo-llm/qwen25-05b/v1
```

---

# Part 2 — Scripted

The same nine steps, wrapped up for the two-hop jump-box layout (laptop → jump
box → disconnected host). Every phase is re-runnable and idempotent; re-running
one that already succeeded is a no-op.

```bash
# 0. one-time
cp config/llmd.env.example config/llmd.env     # usually needs no edits

# 1. laptop — copy this repo to both lab hosts
scripts/remote.sh sync

# 2. high side — ask the cluster what it needs        (Step 1)
scripts/remote.sh run high -- './deploy-llmd.sh 05'

# 3. laptop — carry that list to the low side
scripts/remote.sh sync

# 4. low side — download and ship the images          (Steps 2-3, ~20 min)
scripts/remote.sh run low  -- './deploy-llmd.sh low'

# 5. high side — push, deploy, and prove it works     (Steps 4-9, ~20 min)
scripts/remote.sh run high -- './deploy-llmd.sh high'
```

Step 5 ends by printing the model's reply. `llm-d verify complete` means done.

> **Steps 4 and 5 are long.** Run them under `tmux` (`scripts/remote.sh ssh low`,
> then `tmux new -s llmd`) so a dropped SSH connection cannot kill them.

### Phase map

| Phase | Where | Manual equivalent |
|:--|:--|:--|
| `05` | high | Step 1 — discover images → `config/required-images.txt` |
| `01` | low | preflight |
| `10` | low | Step 2 — mirror to disk |
| `15` | low | Step 3 — transfer, **and verify the copy** |
| `06` | high | preflight — CRDs, GPU, disk, catalog, Service Mesh |
| `18` | high | Steps 4–5 — push, **merge** mirror rules, wait for rollout |
| `20` | high | verify every required image is present |
| `30` | high | Step 6 — enable OCI ModelCar |
| `40` | high | Steps 7–8 — Gateway and model |
| `50` | high | Step 9 — real inference request |
| `90` | high | teardown (`--all` also removes namespace and Gateway) |

Run a single phase with `./deploy-llmd.sh 18`. All accept `DRY_RUN=true`.

### What the scripts add over the manual path

* Preflight that changes nothing and names the exact problem — GPU *free*
  capacity (not just total), registry disk, Service Mesh v2, catalog, CRDs
* Transfer verification by prefix hash, so a bad copy cannot proceed
* IDMS **merge** rather than replace
* Skips the push entirely when the registry already has everything
* Reads mirror paths from the cluster's own IDMS instead of guessing

### Configuration

```bash
LLMD_MODEL="qwen2.5-0.5b"   # start here: 0.9 GiB, proves the whole path
LLMD_MODEL="qwen3-4b"       # the demo model: 7.6 GiB

LLMD_LOW_HOST="..."         # set these if your disconnected-rhoai checkout
LLMD_HIGH_HOST="..."        # points at a different environment
```

Registry address, credentials and host addresses are read from the
disconnected-rhoai checkout's own config file (named `config/criab.env` there),
found automatically under `~/disconnected-rhoai` or `~/criab`. Set
`RHOAI_REPO_DIR` if yours lives elsewhere.

---

## GPU setup

llm-d needs a GPU.

```bash
oc get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.capacity.nvidia\\.com/gpu
```

### No GPU node at all

Clone your existing worker MachineSet — never hand-write the AMI, subnet or
security group, because a stale AMI produces an instance that boots and never
joins:

```bash
export INFRA_ID=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
export AMI=$(oc get machineset -n openshift-machine-api -o jsonpath='{.items[0].spec.template.spec.providerSpec.value.ami.id}')
export SUBNET=$(oc get machineset -n openshift-machine-api -o jsonpath='{.items[0].spec.template.spec.providerSpec.value.subnet.id}')
export REGION=$(oc get machineset -n openshift-machine-api -o jsonpath='{.items[0].spec.template.spec.providerSpec.value.placement.region}')
export AZ=$(oc get machineset -n openshift-machine-api -o jsonpath='{.items[0].spec.template.spec.providerSpec.value.placement.availabilityZone}')
export INSTANCE_TYPE=g6e.2xlarge          # 1x L40S, 48 GB VRAM
export MS_NAME=${INFRA_ID}-gpu-${AZ}
export IAM_PROFILE=${INFRA_ID}-worker-profile
export SG=${INFRA_ID}-node
export GPU_REPLICAS=1
export GPU_VOLUME_SIZE=200
export GPU_TAINTS_BLOCK=""

envsubst < manifests/gpu/machineset-l40s.yaml | oc apply -f -
```

L40S on AWS is the **g6e** family: `g6e.2xlarge` (1× L40S) or `g6e.12xlarge`
(4× L40S). Check it is offered in your AZ before applying — it is not
everywhere, and the failure is a Machine stuck in `Provisioning`:

```bash
aws ec2 describe-instance-type-offerings --location-type availability-zone \
  --filters "Name=location,Values=${AZ}" --region "$REGION" \
  --query 'InstanceTypeOfferings[?starts_with(InstanceType,`g6e`)].InstanceType' --output text
```

The other silent failure is a zero G-family vCPU quota, which looks identical:

```bash
aws service-quotas get-service-quota --service-code ec2 \
  --quota-code L-DB2E81BA --region "$REGION"
```

Scripted: `./deploy-llmd.sh 12`.

### The driver cannot build disconnected

A GPU node with **no** `nvidia.com/gpu` capacity usually means the NVIDIA driver
failed to compile — not a hardware fault. Two halves fail independently:

| Half | Source | Usually |
|:--|:--|:--|
| kernel-devel / headers | the Driver Toolkit, in the OpenShift release payload — already mirrored | fine |
| CUDA dev packages | `developer.download.nvidia.com` | **broken** |

Diagnose before doing any work — the kernel half is normally already solved by
`operator.use_ocp_driver_toolkit: true`:

```bash
oc get clusterpolicy -o jsonpath='{.items[0].spec.operator.use_ocp_driver_toolkit}'
oc logs -n nvidia-gpu-operator -l app=nvidia-driver-daemonset --all-containers --tail=100
```

If the CUDA half is broken, build a local package repo, serve it **in-cluster**
(a shell-hosted repo dies on the next reboot, and the driver pod runs
`dnf install` on every start), and point the ClusterPolicy at it:

```bash
# serve the packages in-cluster (template — needs KERNEL_REPO_IMAGE and GPU_NS)
envsubst < manifests/gpu/kernel-repo.yaml | oc apply -f -

# point the driver at it
oc apply -f manifests/gpu/kernel-repo-config.yaml

oc patch clusterpolicy gpu-cluster-policy --type=merge \
  --patch-file manifests/gpu/clusterpolicy-repoconfig-patch.yaml

# make the retry immediate, and get a clean log
oc delete pod -n nvidia-gpu-operator -l app=nvidia-driver-daemonset
```

Scripted, with the diagnosis first: `./deploy-llmd.sh 14 diagnose`.

### Something else is holding the GPU

One GPU cannot run two models:

```bash
oc get pods -A -o json | jq -r '.items[]
  | select([.spec.containers[]?.resources.requests["nvidia.com/gpu"]//empty]|length>0)
  | "\(.metadata.namespace)/\(.metadata.name) \(.status.phase)"'

oc patch llminferenceservice <other-model> -n <ns> --type=merge -p '{"spec":{"replicas":0}}'
```

---

## Troubleshooting

Ordered by how often each is the answer.

| Symptom | What it means |
|:--|:--|
| `ImagePullBackOff` | image not mirrored, or no IDMS rule covers it |
| Pod `Pending`, `Insufficient nvidia.com/gpu` | something else holds the GPU |
| GPU node with no capacity | driver did not build — see [above](#the-driver-cannot-build-disconnected) |
| oc-mirror push → `502 Bad Gateway` | the registry's disk is full; check its storage volume, not `/` |
| `manifest unknown` from `localhost:55000` | usually an empty incremental archive, not corruption — check whether the images are already present |
| An image was mirrored but now reports no rule | an IDMS was replaced rather than merged (Step 5) |
| GatewayClass `Accepted=Unknown` | no `redhat-operators` CatalogSource serving the mirrored index |
| Gateway programmed but times out | external NLB with public IPs (Step 7) |
| `OCI modelcars is not enabled` | Step 6 not done, or the controllers were not restarted |
| Sidecar `CreateContainerError` | `uidModelcar` is set; it must be unset on OpenShift |
| 404 from a healthy model | `model` field ≠ `spec.model.name` |
| Scheduler logs show Hugging Face fetches | drop `prefix-cache-scorer`; the other scorers need no tokenizer |

Quick health check:

```bash
oc get llminferenceservice -n demo-llm
oc get pods -n demo-llm
oc logs -n demo-llm -l app.kubernetes.io/name=qwen25-05b -c main --tail=50
```

---

## Layout

```
deploy-llmd.sh              phase driver
scripts/
  remote.sh                 sync the repo to the lab hosts
  00-preflight.sh           low|high checks; changes nothing
  05-discover-images.sh     Step 1
  10-mirror-images.sh       Step 2
  15-transfer.sh            Step 3 + verification
  18-push-images.sh         Steps 4-5
  20-verify-mirror.sh       confirm everything is really there
  30-enable-modelcar.sh     Step 6
  40-deploy.sh              Steps 7-8
  50-verify.sh              Step 9
  12/14/16-*.sh             GPU node, GPU driver, LeaderWorkerSet
  90-teardown.sh
config/
  llmd.env.example          the only file you edit
  required-images.txt       generated by phase 05
manifests/
  base/ gateway/ gpu/       namespace, HardwareProfile, Gateway, MachineSet
  qwen2.5-0.5b/ qwen3-4b/   the models
```

The manifests work standalone (`oc apply -k manifests/qwen2.5-0.5b`) — but
Step 6 must have run first, or the `oci://` URI is rejected.

---

## Field notes

Every one of these was hit bringing this up on a real cluster. The symptom never
resembles the cause.

**`oc apply` on an IDMS replaces it — it does not merge.** The sharpest edge in
the whole process, and it bites in two ways. *Across projects:* regenerating the
RHOAI install's mirror config produces objects named `idms-operator-0` /
`idms-generic-0`, and applying a narrower set silently deletes rules other
workloads rely on. *Against yourself:* oc-mirror regenerates those files from
whatever was in the **current** archive, so on an incremental run applying them
deletes the rules for everything mirrored earlier. See Step 5.

**oc-mirror archives are incremental against the connected host's history, not
the destination registry.** Re-run the mirror after a successful push and you get
a near-empty delta archive; feeding that to `diskToMirror` fails with
`manifest unknown ... localhost:55000`, which reads as corruption but means
"nothing new in the box". To force a full archive:

```bash
rm -rf "$WORKDIR/working-dir" && oc-mirror --v2 --config "$WORKDIR/imageset-config.yaml" "file://$WORKDIR"
```

**`rsync --append` corrupts a regenerated archive** — right size, wrong content.
See Step 3.

**A full registry looks like `502`, not a disk error.** The real cause
(`ENOSPC`) is only inside the container log. Orphaned partial uploads under
`<storage>/uploads` are never committed and are safe to delete when no push is
running — 213 GiB was reclaimed that way.

**A cached image is not a mirrored image.** The vLLM CUDA runtime was running
happily from a node's local CRI-O cache while absent from the mirror entirely.
It survives reboots but not node replacement. `crictl images` on the node tells
you the truth; the registry tells you whether you could get it back.

**Two inspection tools, opposite blind spots.** `podman manifest inspect` refuses
single-arch images; `oc image info` refuses manifest lists without
`--filter-by-os`. ModelCars are single-arch and the RHOAI components are lists.

**Kuadrant attaches an AuthPolicy to llm-d routes.** Where Models-as-a-Service is
deployed, the generated HTTPRoute picks up `openshift-ai-inference-authn`. It is
also why route status must be read across all `parents`, not `parents[0]`.

---

## References

- [disconnected-rhoai](https://github.com/rh-aiservices-bu/disconnected-rhoai) — builds the cluster this deploys onto
- [rhoai-maas-guide, Phase 0: Disconnected](https://github.com/rh-aiservices-bu/rhoai-maas-guide/blob/main/content/modules/ROOT/pages/00-disconnected.adoc) — GPU driver approach and the `rhaii/` registry path
- [Red Hat AI Inference 3.4 — llm-d prerequisites](https://docs.redhat.com/en/documentation/red_hat_ai_inference/3.4/html/deploy_distributed_inference_with_llm-d_on_openshift_container_platform/prerequisites-llmd-on-openshift_llmd-on-openshift)
- [LeaderWorkerSet Operator](https://docs.redhat.com/en/documentation/openshift_container_platform/latest/html/ai_workloads/leader-worker-set-operator)
