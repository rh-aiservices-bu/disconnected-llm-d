#!/usr/bin/env bash
# Phase 30 — HIGH SIDE. Turn on OCI ModelCar support in KServe.
#
#   scripts/30-enable-modelcar.sh
#
# WHY THIS EXISTS
#
# On a connected cluster a model is fetched with hf://, and nothing about
# storage needs configuring. Disconnected, the weights have to arrive as a
# container image, and KServe refuses oci:// model URIs unless ModelCar support
# is explicitly enabled:
#
#     enableModelcar: false   ->   "OCI modelcars is not enabled"
#
# That error appears as a reconcile failure on the LLMInferenceService. It does
# not look like an image problem, which is what makes it cost an afternoon.
#
# The script also CLEARS uidModelcar if it is set. KServe applies that value as
# runAsUser on both the ModelCar sidecar and the main serving container. On
# OpenShift the restricted-v2 SCC only permits UIDs from the namespace's
# assigned range, so any hard-coded value there stops the pod from starting.
# Leaving it unset lets OpenShift assign, which is what you want.
#
# Idempotent: run it as often as you like. It restarts the KServe controller
# only when it actually changed something.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env

require_cmd oc jq
require_cluster_admin
require_vars KSERVE_NAMESPACE

CM=inferenceservice-config

step "Phase 30 — enabling OCI ModelCar in ${KSERVE_NAMESPACE}/${CM}"

current="$(oc get configmap "$CM" -n "$KSERVE_NAMESPACE" \
            -o jsonpath='{.data.storageInitializer}' 2>/dev/null || true)"
[[ -n "$current" ]] \
  || die "no storageInitializer key in ${KSERVE_NAMESPACE}/${CM}.
     Check KSERVE_NAMESPACE — RHOAI uses redhat-ods-applications, upstream
     KServe uses kserve."

echo "current:"
printf '%s\n' "$current" | jq '{enableModelcar, uidModelcar, cpuModelcar, memoryModelcar, image}'

# jq, not sed: this value is a JSON document embedded in a ConfigMap string, and
# editing it textually is how you end up with a ConfigMap KServe cannot parse
# and a controller that CrashLoops with no obvious cause.
desired="$(printf '%s' "$current" | jq -c '.enableModelcar = true | del(.uidModelcar)')"

if [[ "$(printf '%s' "$current" | jq -cS .)" == "$(printf '%s' "$desired" | jq -cS .)" ]]; then
  ok "already correct — enableModelcar=true, uidModelcar unset"
  exit 0
fi

echo
echo "desired:"
printf '%s\n' "$desired" | jq '{enableModelcar, uidModelcar, cpuModelcar, memoryModelcar, image}'

if [[ "${DRY_RUN:-false}" == "true" ]]; then
  dim "would patch ${KSERVE_NAMESPACE}/${CM}"
  exit 0
fi

# Back up before touching a ConfigMap the whole serving stack reads.
backup="${LLMD_LOG_DIR}/inferenceservice-config.$(date +%Y%m%d-%H%M%S).json"
oc get configmap "$CM" -n "$KSERVE_NAMESPACE" -o json > "$backup" 2>/dev/null \
  && ok "backed up to ${backup}" \
  || warn "could not write a backup to ${LLMD_LOG_DIR} — continuing"

oc patch configmap "$CM" -n "$KSERVE_NAMESPACE" --type merge \
  -p "$(jq -n --arg v "$desired" '{data:{storageInitializer:$v}}')" >/dev/null
ok "patched ${KSERVE_NAMESPACE}/${CM}"

# The controller caches this config at startup. Without a restart the change
# reads as applied but has no effect, which is a genuinely misleading state.
step "Restarting the KServe controller so it re-reads the config"

dep="$(oc get deploy -n "$KSERVE_NAMESPACE" -o name 2>/dev/null \
        | grep -E 'kserve-controller|llmisvc-controller' || true)"
if [[ -z "$dep" ]]; then
  warn "no kserve/llmisvc controller Deployment found in ${KSERVE_NAMESPACE}."
  warn "  Restart it by hand wherever it runs, or the patch will not take effect."
else
  while read -r d; do
    [[ -n "$d" ]] || continue
    oc rollout restart "$d" -n "$KSERVE_NAMESPACE" >/dev/null
    oc rollout status  "$d" -n "$KSERVE_NAMESPACE" --timeout=300s >/dev/null \
      && ok "restarted ${d}"
  done <<< "$dep"
fi

ok "phase 30 complete — oci:// model URIs are now accepted"
