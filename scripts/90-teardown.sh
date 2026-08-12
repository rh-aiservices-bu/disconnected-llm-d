#!/usr/bin/env bash
# Phase 90 — HIGH SIDE. Remove the llm-d deployment.
#
#   scripts/90-teardown.sh              # the model only
#   scripts/90-teardown.sh --all        # model, namespace, gateway
#
# Scoped narrowly on purpose. The cluster is shared between projects, and the
# Gateway and GatewayClass are cluster-wide — deleting the GatewayClass
# uninstalls OSSM 3 and takes out anything else using Gateway API with it.
#
# Nothing here touches the mirror registry. Removing images from Quay is how you
# break node reboot, scale and upgrade for the whole cluster; the ModelCar
# images are a few gigabytes and are not worth that risk.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env

require_cmd oc
require_cluster_admin

ALL=false
[[ "${1:-}" == "--all" ]] && ALL=true

ISVC="$(model_isvc_name)"

step "Phase 90 — removing ${LLMD_NAMESPACE}/${ISVC}"
run oc delete llminferenceservice "$ISVC" -n "$LLMD_NAMESPACE" --ignore-not-found
ok "LLMInferenceService removed"

if [[ "$ALL" != "true" ]]; then
  ok "namespace and gateway left in place (pass --all to remove them)"
  exit 0
fi

step "Removing the namespace"
run oc delete namespace "$LLMD_NAMESPACE" --ignore-not-found

step "Removing the Gateway"
run oc delete gateway "$LLMD_GATEWAY_NAME" -n "$LLMD_GATEWAY_NAMESPACE" --ignore-not-found

# Deliberately NOT deleting the GatewayClass. RHOAI's own Data Science Gateway
# and any other Gateway API consumer share it, and its removal triggers an OSSM
# uninstall. Delete it by hand if you genuinely mean to.
warn "GatewayClass ${LLMD_GATEWAY_CLASS} left in place — it is cluster-wide and"
warn "  shared. Removing it uninstalls OSSM 3. Delete it only deliberately:"
warn "    oc delete gatewayclass ${LLMD_GATEWAY_CLASS}"

ok "teardown complete"
