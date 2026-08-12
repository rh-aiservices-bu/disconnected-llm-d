#!/usr/bin/env bash
# Phase 40 — HIGH SIDE. Deploy llm-d.
#
#   scripts/40-deploy.sh
#   LLMD_MODEL=qwen3-4b scripts/40-deploy.sh
#
# Order matters and is not arbitrary:
#
#   1. Gateway first. Applying the GatewayClass is what triggers the ingress
#      operator to install OSSM 3, which on a disconnected cluster is the step
#      most likely to stall. Doing it before anything else means a failure
#      shows up in two minutes instead of after a 7.6 GiB image pull.
#   2. Namespace and HardwareProfile.
#   3. The LLMInferenceService.
#
# Long-running: run it under tmux or nohup per the convention, and tee to
# /mnt/mirror. It prints "llm-d deploy complete" on success so a watcher can
# poll for a marker rather than guess from process state.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env

require_cmd oc jq
require_cluster_admin
require_vars LLMD_MODEL LLMD_NAMESPACE

OVERLAY="$(model_overlay)"
ISVC="$(model_isvc_name)"

step "Phase 40 — deploying llm-d (${LLMD_MODEL} -> ${LLMD_NAMESPACE}/${ISVC})"

# ---------------------------------------------------------------------------
# 1. Gateway
if [[ "$LLMD_MANAGE_GATEWAY" == "true" ]]; then
  step "1/4  Gateway API"

  if oc get gatewayclass "$LLMD_GATEWAY_CLASS" >/dev/null 2>&1; then
    ok "GatewayClass ${LLMD_GATEWAY_CLASS} already exists — left alone"
    # Re-applying is harmless, but the OSSM override annotations only take
    # effect at first creation, so there is nothing to gain and a small chance
    # of disturbing a working install.
  else
    run oc apply -f "${REPO_ROOT}/manifests/gateway/gateway.yaml"
  fi

  # A GatewayClass stuck at Accepted=Unknown is THE disconnected failure mode:
  # the ingress operator is waiting on a servicemeshoperator3 subscription that
  # cannot resolve, because the redhat-operators CatalogSource it hard-codes was
  # disabled with the rest of the default sources. Diagnose that explicitly — a
  # bare timeout here sends people looking at the Gateway, which is fine.
  gwclass_accepted() {
    [[ "$(oc get gatewayclass "$LLMD_GATEWAY_CLASS" \
          -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null)" == "True" ]]
  }
  gwclass_deadline=$(( SECONDS + 900 ))
  step "Waiting for GatewayClass ${LLMD_GATEWAY_CLASS} to be Accepted (timeout 900s)"
  while (( SECONDS < gwclass_deadline )) && ! gwclass_accepted; do printf '.'; sleep 10; done
  echo
  if gwclass_accepted; then
    ok "GatewayClass ${LLMD_GATEWAY_CLASS} Accepted"
  elif [[ "${DRY_RUN:-false}" == "true" ]]; then
    dim "DRY_RUN — not waiting on the GatewayClass"
  else
    oc get gatewayclass "$LLMD_GATEWAY_CLASS" -o jsonpath='{.status.conditions}' 2>/dev/null | jq . || true
    oc get subscription -n openshift-operators servicemeshoperator3 \
      -o jsonpath='{.status.conditions}' 2>/dev/null | jq . || true
    die "GatewayClass ${LLMD_GATEWAY_CLASS} never became Accepted.

     This is nearly always the OSSM 3 subscription failing to resolve. Check:

       oc get catalogsource redhat-operators -n openshift-marketplace
       oc get sub,csv -n openshift-operators | grep -i servicemesh

     On a disconnected cluster there must be a CatalogSource literally named
     redhat-operators serving the MIRRORED index — the ingress operator
     hard-codes that name. the RHOAI install creates it in phase 30 when
     INSTALL_SERVICE_MESH3=true:  cd <disconnected-rhoai> && ./deploy-rhoai.sh 30"
  fi

  # Ensure the Gateway itself exists even if the class was pre-created.
  if ! oc get gateway "$LLMD_GATEWAY_NAME" -n "$LLMD_GATEWAY_NAMESPACE" >/dev/null 2>&1; then
    run oc apply -f "${REPO_ROOT}/manifests/gateway/gateway.yaml"
  fi

  # On AWS the gateway's Service defaults to an EXTERNAL NLB with public IPs.
  # In a disconnected VPC those are unreachable from everywhere that matters —
  # the high side, and pods inside the cluster resolving the gateway hostname.
  # The symptom is a Gateway that programs fine and then times out or returns
  # EOF, which reads as a serving fault rather than a load balancer one.
  if [[ "${LLMD_GATEWAY_INTERNAL_LB:-auto}" != "false" ]]; then
    platform="$(oc get infrastructure cluster -o jsonpath='{.status.platform}' 2>/dev/null || true)"
    if [[ "$platform" == "AWS" || "${LLMD_GATEWAY_INTERNAL_LB:-}" == "true" ]]; then
      current="$(oc get gateway "$LLMD_GATEWAY_NAME" -n "$LLMD_GATEWAY_NAMESPACE" \
        -o jsonpath='{.spec.infrastructure.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-internal}' 2>/dev/null || true)"
      if [[ "$current" == "true" ]]; then
        ok "gateway already annotated for an internal NLB"
      else
        step "Switching the gateway to an internal NLB (disconnected VPC)"
        run oc patch gateway "$LLMD_GATEWAY_NAME" -n "$LLMD_GATEWAY_NAMESPACE" --type=merge -p \
          '{"spec":{"infrastructure":{"annotations":{"service.beta.kubernetes.io/aws-load-balancer-internal":"true"}}}}'
        # The annotation only affects Service creation, so an already-created
        # external NLB keeps its public IPs until the Service is recreated.
        svc="$(oc get svc -n "$LLMD_GATEWAY_NAMESPACE" -o name 2>/dev/null | grep -- "$LLMD_GATEWAY_NAME" | head -1)"
        if [[ -n "$svc" ]]; then
          run oc delete "$svc" -n "$LLMD_GATEWAY_NAMESPACE"
          ok "deleted ${svc} — the controller recreates it as an internal NLB (1-2 min)"
        fi
      fi
    fi
  fi

  gw_programmed() {
    [[ "$(oc get gateway "$LLMD_GATEWAY_NAME" -n "$LLMD_GATEWAY_NAMESPACE" \
          -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)" == "True" ]]
  }
  wait_for "Gateway ${LLMD_GATEWAY_NAME} Programmed" 900 gw_programmed
else
  ok "LLMD_MANAGE_GATEWAY=false — using the existing ${LLMD_GATEWAY_NAMESPACE}/${LLMD_GATEWAY_NAME}"
  oc get gateway "$LLMD_GATEWAY_NAME" -n "$LLMD_GATEWAY_NAMESPACE" >/dev/null 2>&1 \
    || die "Gateway ${LLMD_GATEWAY_NAMESPACE}/${LLMD_GATEWAY_NAME} does not exist"
fi

# ---------------------------------------------------------------------------
# 2. namespace + hardware profile
step "2/4  Namespace and HardwareProfile"

if [[ "$LLMD_MANAGE_HARDWARE_PROFILE" == "true" ]]; then
  run oc apply -k "${REPO_ROOT}/manifests/base"
else
  run oc apply -f "${REPO_ROOT}/manifests/base/namespace.yaml"
fi

# ---------------------------------------------------------------------------
# 3. the model
step "3/4  LLMInferenceService"

run oc apply -f "${OVERLAY}/llm-inference-service.yaml"

# Patch the ModelCar reference only if config overrides the manifest, so a
# plain `oc apply -k manifests/qwen3-4b` stays a complete, working deployment
# on its own.
want_uri="oci://$(model_image)"
have_uri="$(oc get llminferenceservice "$ISVC" -n "$LLMD_NAMESPACE" \
             -o jsonpath='{.spec.model.uri}' 2>/dev/null || true)"
if [[ -n "$have_uri" && "$want_uri" != "$have_uri" ]]; then
  warn "config overrides the manifest's model URI:"
  warn "  manifest: ${have_uri}"
  warn "  config:   ${want_uri}"
  run oc patch llminferenceservice "$ISVC" -n "$LLMD_NAMESPACE" --type merge \
    -p "$(jq -n --arg u "$want_uri" '{spec:{model:{uri:$u}}}')"
fi

if [[ -n "${LLMD_REPLICAS:-}" ]]; then
  run oc patch llminferenceservice "$ISVC" -n "$LLMD_NAMESPACE" --type merge \
    -p "$(jq -n --argjson r "$LLMD_REPLICAS" '{spec:{replicas:$r}}')"
  ok "replicas set to ${LLMD_REPLICAS}"
fi

# ---------------------------------------------------------------------------
# 4. wait
step "4/4  Waiting for the model to serve"

if [[ "${DRY_RUN:-false}" == "true" ]]; then
  dim "would wait for ${ISVC} to become Ready"
  ok "llm-d deploy complete (dry run)"
  exit 0
fi

# Report what the pods are doing while waiting. On a first deploy the honest
# answer for several minutes is "pulling a multi-gigabyte image", and a bare
# spinner makes that indistinguishable from a hang.
isvc_ready() {
  local ready
  ready="$(oc get llminferenceservice "$ISVC" -n "$LLMD_NAMESPACE" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  [[ "$ready" == "True" ]]
}

deadline=$(( SECONDS + WAIT_TIMEOUT ))
last=""
while (( SECONDS < deadline )); do
  if isvc_ready; then
    echo
    ok "LLMInferenceService ${ISVC} is Ready"
    break
  fi
  now="$(oc get pods -n "$LLMD_NAMESPACE" -l app.kubernetes.io/name="$ISVC" \
          --no-headers 2>/dev/null | awk '{print $1" "$3}' | sort | tr '\n' ' ')"
  [[ -z "$now" ]] && now="$(oc get pods -n "$LLMD_NAMESPACE" --no-headers 2>/dev/null \
          | awk '{print $1" "$3}' | sort | tr '\n' ' ')"
  if [[ "$now" != "$last" ]]; then
    printf '\n  %s\n' "${now:-no pods yet}"
    last="$now"
  else
    printf '.'
  fi
  sleep 15
done

if ! isvc_ready; then
  echo
  warn "not Ready after ${WAIT_TIMEOUT}s. Where to look, in order:"
  cat <<EOF

  oc get llminferenceservice ${ISVC} -n ${LLMD_NAMESPACE} -o yaml | yq '.status'
  oc get pods -n ${LLMD_NAMESPACE}
  oc describe pod -n ${LLMD_NAMESPACE} -l app.kubernetes.io/name=${ISVC} | tail -40

  Common causes here, most likely first:

    ImagePullBackOff on the ModelCar     -> phase 20 said it was mirrored?
    Pending, no nodes match              -> no GPU capacity; phase 00 checks this
    "OCI modelcars is not enabled"       -> phase 30 was not run, or the
                                            controller was not restarted
    Init/sidecar CreateContainerError    -> uidModelcar is set; phase 30 clears it
    HTTPRoute not attached               -> Gateway not Programmed

EOF
  exit 1
fi

oc get llminferenceservice "$ISVC" -n "$LLMD_NAMESPACE"
oc get pods -n "$LLMD_NAMESPACE"

echo
ok "llm-d deploy complete"
