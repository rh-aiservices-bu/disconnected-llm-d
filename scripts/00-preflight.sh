#!/usr/bin/env bash
# Phase 00 — preflight. Checks only; changes nothing.
#
#   scripts/00-preflight.sh low     # jump box: can we reach the sources?
#   scripts/00-preflight.sh high    # cluster side: is it ready for llm-d?
#
# Every check that fails prints what to do about it. The high-side set is the
# one that matters — it is cheaper to fail here than to spend forty minutes
# pulling a 7.6 GiB ModelCar into a cluster that was never going to schedule it.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env

SIDE="${1:-}"
[[ "$SIDE" == "low" || "$SIDE" == "high" ]] || die "usage: $0 <low|high>"

FAILED=0
PROBLEMS=()
fail()  { printf '%s fail%s %s\n' "$C_RED" "$C_RST" "$1" >&2; PROBLEMS+=("$1"); FAILED=1; }
check() { printf '%s  ok%s %s\n' "$C_GRN" "$C_RST" "$1"; }

step "Phase 00 — preflight (${SIDE} side)"

# ---------------------------------------------------------------------------
if [[ "$SIDE" == "low" ]]; then

  # skopeo is not installed on the CRIAB jump box; podman always is. See
  # inspect_remote() in lib/common.sh.
  require_cmd oc jq
  check "image inspection via $(command -v skopeo >/dev/null 2>&1 && echo skopeo || echo '`oc image info` (no skopeo installed)')"

  for ref in "$MODELCAR_QWEN25_05B" "$MODELCAR_QWEN3_4B"; do
    if inspect_remote "$ref" >/dev/null 2>&1; then
      digest="${ref##*@}"
      check "reachable: ${ref%%@*}@${digest:0:19}..."
    else
      fail "cannot reach ${ref} — the low side needs internet for this phase"
    fi
  done

  if [[ -f "$CRIAB_ENV" ]]; then
    check "CRIAB env found at ${CRIAB_ENV}"
  else
    fail "no CRIAB env at ${CRIAB_ENV} — set CRIAB_DIR in config/llmd.env"
  fi

  add_file="${CRIAB_DIR}/config/additional-images.txt"
  if [[ -w "$add_file" ]]; then
    check "CRIAB additional-images.txt is writable"
  else
    fail "cannot write ${add_file} — phase 10 appends the ModelCar refs there"
  fi

  # The mirror pipeline stages a full copy of everything before pushing. The
  # cheatsheet's rule of thumb is 3x payload free; 7.6 + 0.9 GiB of ModelCar
  # means ~26 GiB, and it shares /mnt/mirror with the RHOAI archive.
  avail="$(df -BG --output=avail /mnt/mirror 2>/dev/null | tail -1 | tr -dc '0-9' || true)"
  if [[ -z "$avail" ]]; then
    warn "could not read free space on /mnt/mirror — is this actually the low side?"
  elif (( avail >= 40 )); then
    check "/mnt/mirror has ${avail}G free"
  else
    fail "/mnt/mirror has only ${avail}G free — want 40G+ for the ModelCar images"
  fi

# ---------------------------------------------------------------------------
else

  require_cluster_admin
  check "logged in to $(oc whoami --show-server 2>/dev/null) as $(oc whoami)"

  # --- the llm-d API itself ------------------------------------------------
  if oc get crd llminferenceservices.serving.kserve.io >/dev/null 2>&1; then
    check "LLMInferenceService CRD present"
  else
    fail "no llminferenceservices.serving.kserve.io CRD — this RHOAI install does not
       have the llm-d/KServe LLM stack. Check the DataScienceCluster has
       kserve managementState=Managed:
         oc get dsc -o jsonpath='{.items[0].spec.components.kserve}' | jq"
  fi

  if oc get crd inferencepools.inference.networking.x-k8s.io >/dev/null 2>&1; then
    check "InferencePool CRD present (Gateway API Inference Extension)"
  else
    fail "no inferencepools.inference.networking.x-k8s.io CRD — the scheduler
       cannot create its pool. This ships with the KServe LLM stack."
  fi

  # --- ModelCar support ----------------------------------------------------
  # oci:// model URIs are refused outright unless this is on, and the error
  # surfaces as a reconcile failure on the LLMInferenceService rather than
  # anything image-shaped: "OCI modelcars is not enabled".
  cm_json="$(oc get configmap inferenceservice-config -n "$KSERVE_NAMESPACE" \
              -o jsonpath='{.data.storageInitializer}' 2>/dev/null || true)"
  if [[ -z "$cm_json" ]]; then
    fail "no inferenceservice-config ConfigMap in ${KSERVE_NAMESPACE} — is
       KSERVE_NAMESPACE right? (RHOAI: redhat-ods-applications)"
  elif [[ "$(printf '%s' "$cm_json" | jq -r '.enableModelcar // false')" == "true" ]]; then
    check "enableModelcar is true — oci:// model URIs will work"
  else
    fail "enableModelcar is false in ${KSERVE_NAMESPACE}/inferenceservice-config.
       oci:// model URIs will be rejected. Fix with:
         scripts/30-enable-modelcar.sh"
  fi

  # KServe sets runAsUser from uidModelcar on BOTH the ModelCar sidecar and the
  # main container. Any value outside the namespace's assigned UID range is
  # rejected by the restricted-v2 SCC, and the pod never starts. Unset is the
  # only safe setting on OpenShift.
  uid="$(printf '%s' "${cm_json:-{\}}" | jq -r '.uidModelcar // "unset"')"
  if [[ "$uid" == "unset" || "$uid" == "null" ]]; then
    check "uidModelcar unset — OpenShift assigns the UID (correct)"
  else
    fail "uidModelcar is ${uid}. On OpenShift the restricted-v2 SCC rejects a
       hard-coded runAsUser outside the namespace UID range and the pod will
       not start. Clear it with: scripts/30-enable-modelcar.sh"
  fi

  # --- Gateway API ---------------------------------------------------------
  # See manifests/gateway/gateway.yaml for why this matters so much here.
  if oc get crd gatewayclasses.gateway.networking.k8s.io >/dev/null 2>&1; then
    check "Gateway API CRDs present"
  else
    fail "no Gateway API CRDs — the cluster-ingress-operator installs these when
       Gateway API is enabled on OpenShift 4.19+."
  fi

  if oc get catalogsource redhat-operators -n openshift-marketplace >/dev/null 2>&1; then
    state="$(oc get catalogsource redhat-operators -n openshift-marketplace \
              -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null)"
    if [[ "$state" == "READY" ]]; then
      check "CatalogSource redhat-operators is READY (OSSM 3 can resolve)"
    else
      fail "CatalogSource redhat-operators is '${state:-unknown}', not READY. The
       ingress operator subscribes servicemeshoperator3 from this source; while
       it is broken the GatewayClass stays ACCEPTED=Unknown and no Gateway is
       ever programmed."
    fi
  else
    fail "no CatalogSource named redhat-operators in openshift-marketplace.
       On a disconnected cluster the default source is disabled, so CRIAB
       aliases the MIRRORED index under that name (phase 30, gated on
       INSTALL_SERVICE_MESH3=true). Without it the Gateway never programs.
       Re-run:  ~/criab/deploy-rhoai.sh 30"
  fi

  # Capture, then match. See imatch() in lib/common.sh for why a `| grep -q`
  # here is a latent false negative.
  csvs_all="$(oc get csv -A -o name 2>/dev/null || true)"
  if imatch "$csvs_all" 'servicemeshoperator3'; then
    check "servicemeshoperator3 CSV installed"
  else
    warn "servicemeshoperator3 not installed yet — it is created on demand when"
    warn "  the GatewayClass is applied. Phase 40 waits for it."
  fi

  # --- OpenShift version ---------------------------------------------------
  # Red Hat's llm-d prerequisites are 4.19 or later.
  ocpv="$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || true)"
  if [[ -n "$ocpv" ]]; then
    # No `head` in the pipeline: it would SIGPIPE sort for the same reason
    # grep -q does. Sort fully, then take the first line with parameter
    # expansion.
    sorted="$(printf '%s\n4.19.0\n' "$ocpv" | sort -V)"
    if [[ "${sorted%%$'\n'*}" == "4.19.0" ]]; then
      check "OpenShift ${ocpv} (>= 4.19 required)"
    else
      fail "OpenShift ${ocpv} is below the 4.19 minimum for llm-d"
    fi
  fi

  # --- Service Mesh v2 must be absent --------------------------------------
  # Red Hat calls this out explicitly: OSSM v2 conflicts with the Istio Sail
  # operator that backs Gateway API. Both installed is not a warning state, it
  # is a broken one, and it presents as a Gateway that never programs.
  # Reuses the CSV list captured above. A `| grep -q` here would be worse than
  # cosmetic: a SIGPIPE false negative on a safety check reports "v2 absent" on
  # a cluster where it is present.
  if imatch "$csvs_all" 'servicemeshoperator\.v2'; then
    fail "OpenShift Service Mesh v2 is installed. It conflicts with the Sail
       operator behind Gateway API and must be removed before deploying llm-d."
  else
    check "Service Mesh v2 not installed (correct — v3/Sail is what Gateway API uses)"
  fi

  # --- LeaderWorkerSet -----------------------------------------------------
  # A warning, not a failure: single-node serving reconciles into a Deployment,
  # and the KServe controller only watches LeaderWorkerSet when the CRD exists.
  # It becomes required for multi-node.
  if oc get crd leaderworkersets.leaderworkerset.x-k8s.io >/dev/null 2>&1; then
    check "LeaderWorkerSet CRD present — multi-node serving available"
  else
    warn "LeaderWorkerSet Operator not installed."
    warn "  Optional for the single-node replicas deployed here; REQUIRED for"
    warn "  multi-node (disaggregated prefill/decode). Install with:"
    warn "    scripts/16-install-lws.sh"
  fi

  # --- user workload monitoring --------------------------------------------
  # Listed by Red Hat as a prerequisite; it is what scrapes the vLLM metrics
  # the scheduler's scorers and any dashboard depend on.
  uwm="$(oc get configmap cluster-monitoring-config -n openshift-monitoring \
          -o jsonpath='{.data.config\.yaml}' 2>/dev/null | grep -c 'enableUserWorkload: true' || true)"
  if [[ "${uwm:-0}" -gt 0 ]]; then
    check "user workload monitoring enabled"
  else
    warn "user workload monitoring is not enabled. Model metrics will not be"
    warn "  scraped. Enable with:"
    warn "    oc -n openshift-monitoring patch configmap cluster-monitoring-config \\"
    warn "      --type merge -p '{\"data\":{\"config.yaml\":\"enableUserWorkload: true\\n\"}}'"
  fi

  # --- GPU capacity --------------------------------------------------------
  gpus="$(oc get nodes -o json | jq '[.items[].status.capacity["nvidia.com/gpu"] // "0" | tonumber] | add')"
  if (( gpus > 0 )); then
    # Total capacity is the wrong number. What matters is what is FREE — on a
    # shared cluster another workload may already hold every GPU, and then the
    # model pod sits Pending with
    #   0/3 nodes are available: 3 Insufficient nvidia.com/gpu
    # long after a capacity-only check said everything was fine.
    # Count only pods BOUND to a node (.spec.nodeName set). An unscheduled
    # Pending pod — including the one this very deployment may have left behind
    # from a previous attempt — is competing for a GPU, not holding one, and
    # counting it produces nonsense like "-1 of 1 GPU(s) free".
    gpus_used="$(oc get pods -A -o json | jq '
      [ .items[]
        | select(.spec.nodeName != null)
        | select(.status.phase == "Running" or .status.phase == "Pending")
        | .spec.containers[]?.resources.requests["nvidia.com/gpu"] // "0" | tonumber
      ] | add // 0')"
    gpus_free=$(( gpus - gpus_used ))
    want="${LLMD_REPLICAS:-1}"

    if (( gpus_free >= want )); then
      check "${gpus_free} of ${gpus} GPU(s) free (need ${want})"
    else
      fail "only ${gpus_free} of ${gpus} GPU(s) are free but LLMD_REPLICAS=${want}.
       Already requested by:
$(oc get pods -A -o json | jq -r '
          .items[]
          | select([.spec.containers[]?.resources.requests["nvidia.com/gpu"] // empty] | length > 0)
          | "         \(.metadata.namespace)/\(.metadata.name)  (\(.status.phase))"' | head -8)
       Free one up, or lower LLMD_REPLICAS."
    fi

    # 50 GB per GPU node is Red Hat's floor for images and ephemeral storage.
    # The vLLM CUDA image plus a 7.6 GiB ModelCar clears that on its own.
    # Units are NOT consistent across fields: on the same node, capacity came
    # back as "209124332Ki" and allocatable as plain bytes. k8s_bytes normalises
    # both; assuming either one is wrong by a factor of 1024.
    while read -r n raw; do
      [[ -n "$n" ]] || continue
      gib=$(( $(k8s_bytes "$raw") / 1073741824 ))
      if (( gib >= 50 )); then
        check "${n}: ${gib} GiB ephemeral storage"
      else
        fail "${n} has only ${gib} GiB ephemeral storage — Red Hat's floor is 50 GiB per GPU node"
      fi
    done < <(oc get nodes -o json | jq -r '
      .items[] | select(.status.capacity["nvidia.com/gpu"] != null)
      | .metadata.name + " " + ((.status.allocatable["ephemeral-storage"] // "0") | tostring)')
  else
    fail "no nvidia.com/gpu capacity on any node.

       If no GPU node exists at all:
         scripts/12-gpu-machineset.sh

       If a GPU node exists but reports no capacity, the driver did not build.
       That is the normal disconnected failure and it is NOT a hardware fault:
         scripts/14-gpu-driver-disconnected.sh diagnose"
  fi

  # --- the mirror registry's own disk ---------------------------------------
  # Checked here because the failure mode is genuinely misleading: Quay's
  # front end keeps answering, `podman login` still succeeds, reads still
  # serve — and every push dies with
  #   received unexpected HTTP status: 502 Bad Gateway
  # while the real error is only visible inside the container log as
  #   OSError: [Errno 28] No space left on device: '/datastorage/uploads/...'
  #
  # Note this is NOT the same filesystem as / or /mnt/mirror. Quay gets its own
  # volume, so `df -h /` looking healthy proves nothing.
  qs="${MIRROR_REGISTRY_QUAY_STORAGE:-}"
  if [[ -n "$qs" && -d "$qs" ]]; then
    q_avail_k="$(df -Pk "$qs" 2>/dev/null | awk 'NR==2{print $4}')"
    q_gib=$(( ${q_avail_k:-0} / 1048576 ))
    q_pct="$(df -Pk "$qs" 2>/dev/null | awk 'NR==2{print $5}')"
    if (( q_gib >= 60 )); then
      check "mirror registry storage: ${q_gib} GiB free (${q_pct} used)"
    else
      fail "mirror registry storage has only ${q_gib} GiB free (${q_pct} used) at
       ${qs}
       Pushes will fail with 502 Bad Gateway long before this looks like a disk
       problem. Two ways out:
         - reclaim abandoned partial uploads (safe; they are not committed blobs):
             du -sh ${qs}/uploads
             # with no push running, remove entries older than a day
         - grow the volume:
             aws ec2 modify-volume --volume-id <id> --size <GB>
             sudo xfs_growfs ${qs}"
    fi
  else
    warn "cannot locate the mirror registry's storage volume."
    warn "  Set MIRROR_REGISTRY_QUAY_STORAGE in ${CRIAB_ENV} so this can be checked;"
    warn "  a full Quay volume presents as 502 on push, not as a disk error."
  fi

  # --- image redirection ---------------------------------------------------
  idms="$(oc get imagedigestmirrorset -o name 2>/dev/null || true)"
  icsp="$(oc get imagecontentsourcepolicy -o name 2>/dev/null || true)"
  itms="$(oc get imagetagmirrorset -o name 2>/dev/null || true)"
  if [[ -n "$idms" || -n "$icsp" ]]; then
    check "$(printf '%s' "$idms$icsp" | grep -c . || true) digest mirror resource(s) — quay.io pulls redirect to the mirror"
    # ModelCar references here are digest-pinned, so IDMS covers them. ITMS only
    # matters if you add a TAG-referenced image; noting it because the MaaS
    # modelcars are tag-based and their ITMS is easy to mistake for ours.
    # `|| true`: last statement of this if-body, so a false test would make the
    # whole `if` return 1 and set -e would end the preflight early.
    [[ -n "$itms" ]] && check "$(printf '%s' "$itms" | grep -c . || true) ImageTagMirrorSet(s) — needed only for tag-referenced images" || true
  else
    fail "no ImageDigestMirrorSet or ImageContentSourcePolicy. Manifests use
       original image references and rely on mirror redirection; without it
       every pull goes to quay.io and hangs. Run: ~/criab/deploy-rhoai.sh 30"
  fi
fi

# ---------------------------------------------------------------------------
echo
if (( FAILED )); then
  step "${#PROBLEMS[@]} problem(s) — resolve these before continuing"
  printf '  - %s\n' "${PROBLEMS[@]}" | head -40
  exit 1
fi
ok "preflight (${SIDE}) passed"
