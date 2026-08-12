#!/usr/bin/env bash
# Phase 50 — HIGH SIDE. Prove the deployment actually serves inference.
#
#   scripts/50-verify.sh
#
# Readiness conditions are not the same thing as a working model. This sends a
# real completion request and checks a real response.
#
# The request goes through an `oc port-forward` to the Gateway rather than from
# a pod inside the cluster. That is deliberate: an in-cluster curl needs a curl
# IMAGE, and on a disconnected cluster the odds that ubi9/curl happens to be
# mirrored are not worth betting a verification step on. The high side already
# has curl.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env

require_cmd oc jq curl
require_cluster_admin

ISVC="$(model_isvc_name)"
PF_PORT="${PF_PORT:-18080}"

step "Phase 50 — verifying ${LLMD_NAMESPACE}/${ISVC}"

# ---------------------------------------------------------------------------
step "1/4  Resource status"

oc get llminferenceservice "$ISVC" -n "$LLMD_NAMESPACE" || die "no LLMInferenceService ${ISVC}"
ready="$(oc get llminferenceservice "$ISVC" -n "$LLMD_NAMESPACE" \
          -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
[[ "$ready" == "True" ]] || die "LLMInferenceService is not Ready (Ready=${ready:-<none>}) — run phase 40 first"
ok "LLMInferenceService Ready"

echo
oc get pods -n "$LLMD_NAMESPACE" -o wide

# ---------------------------------------------------------------------------
step "2/4  Routing"

# KServe generates an HTTPRoute per service, mounted at /{namespace}/{name}.
# If it is not Accepted, the Gateway will answer 404 and the model looks broken
# when it is in fact fine.
routes="$(oc get httproute -n "$LLMD_NAMESPACE" -o json 2>/dev/null | jq -r '.items[].metadata.name')"
if [[ -z "$routes" ]]; then
  warn "no HTTPRoute in ${LLMD_NAMESPACE} — the router may still be reconciling"
else
  while read -r r; do
    [[ -n "$r" ]] || continue
    # Search EVERY parent, not parents[0]. Each controller that touches the
    # route appends its own entry, and on a cluster running Kuadrant (MaaS)
    # parents[0] is its policy-controller reporting AuthPolicyAffected — the
    # gateway controller's real Accepted condition sits further down. Indexing
    # [0] reports "Accepted=<none>" on a perfectly healthy route.
    st="$(oc get httproute "$r" -n "$LLMD_NAMESPACE" -o json 2>/dev/null \
          | jq -r '[.status.parents[]?.conditions[]? | select(.type=="Accepted") | .status] | (index("True") // empty) | "True"' 2>/dev/null)"
    if [[ "$st" == "True" ]]; then
      ok "HTTPRoute ${r} Accepted"
    else
      warn "HTTPRoute ${r} not Accepted by any parent"
    fi

    # Surface auth policies rather than letting them show up as a 401 later.
    pol="$(oc get httproute "$r" -n "$LLMD_NAMESPACE" -o json 2>/dev/null \
           | jq -r '[.status.parents[]?.conditions[]? | select(.type|test("AuthPolicyAffected")) | .message] | first // empty')"
    [[ -n "$pol" ]] && warn "an AuthPolicy applies to this route: ${pol}" || true
  done <<< "$routes"
fi

GW_SVC="$(oc get svc -n "$LLMD_GATEWAY_NAMESPACE" -o name 2>/dev/null \
          | grep -- "${LLMD_GATEWAY_NAME}" | head -1)"
[[ -n "$GW_SVC" ]] || die "no Service for Gateway ${LLMD_GATEWAY_NAME} in ${LLMD_GATEWAY_NAMESPACE}"
ok "gateway service: ${GW_SVC}"

# ---------------------------------------------------------------------------
step "3/4  Port-forward to the gateway"

if [[ "${DRY_RUN:-false}" == "true" ]]; then
  dim "would port-forward ${GW_SVC} and send a completion request"
  exit 0
fi

# Keep oc's output. Discarding it turns "address already in use" — by far the
# most common cause, usually a port-forward left behind by a previous run — into
# a bare "port-forward died", which says nothing actionable.
PF_LOG="$(mktemp)"
start_pf() {
  oc port-forward -n "$LLMD_GATEWAY_NAMESPACE" "$GW_SVC" "${1}:80" > "$PF_LOG" 2>&1 &
  PF_PID=$!
}

start_pf "$PF_PORT"
# shellcheck disable=SC2064
trap "kill ${PF_PID} 2>/dev/null || true; rm -f ${PF_LOG}" EXIT

pf_up() {
  # Any HTTP status proves the tunnel is up; the gateway answers 404 at / and
  # that is a perfectly good sign of life.
  local code
  code="$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${1}/" 2>/dev/null || true)"
  [[ -n "$code" && "$code" != "000" ]]
}

for _ in $(seq 1 15); do pf_up "$PF_PORT" && break; sleep 1; done

if ! pf_up "$PF_PORT"; then
  if grep -qi "address already in use\|bind" "$PF_LOG" 2>/dev/null; then
    warn "port ${PF_PORT} is already in use — retrying on a free port"
    kill "$PF_PID" 2>/dev/null || true
    PF_PORT=$(( PF_PORT + RANDOM % 900 + 1 ))
    start_pf "$PF_PORT"
    for _ in $(seq 1 15); do pf_up "$PF_PORT" && break; sleep 1; done
  fi
fi

pf_up "$PF_PORT" || die "could not port-forward to ${GW_SVC}. oc said:
$(sed 's/^/     /' "$PF_LOG" | head -5)
   Something already listening? Check: ss -lnt | grep ${PF_PORT}"
ok "forwarding localhost:${PF_PORT} -> ${GW_SVC}:80"

BASE="http://127.0.0.1:${PF_PORT}/${LLMD_NAMESPACE}/${ISVC}"

# ---------------------------------------------------------------------------
step "4/4  Inference"

echo "GET ${BASE}/v1/models"
models="$(curl -s -m 30 "${BASE}/v1/models" || true)"
printf '%s\n' "$models" | jq . 2>/dev/null || printf '%s\n' "$models"

# Ask the served model for its own name rather than assuming it. vLLM matches
# the "model" field exactly, and a mismatch returns a 404 that reads like a
# routing failure.
served="$(printf '%s' "$models" | jq -r '.data[0].id // empty' 2>/dev/null || true)"
if [[ -z "$served" ]]; then
  served="$(oc get llminferenceservice "$ISVC" -n "$LLMD_NAMESPACE" \
             -o jsonpath='{.spec.model.name}' 2>/dev/null)"
  warn "could not read /v1/models — falling back to spec.model.name: ${served}"
fi

echo
echo "POST ${BASE}/v1/chat/completions  (model=${served})"
resp="$(curl -s -m 120 "${BASE}/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg m "$served" '{
        model: $m,
        messages: [{role:"user", content:"Reply with exactly: llm-d is serving."}],
        max_tokens: 32,
        temperature: 0
      }')" || true)"

printf '%s\n' "$resp" | jq . 2>/dev/null || printf '%s\n' "$resp"

content="$(printf '%s' "$resp" | jq -r '.choices[0].message.content // empty' 2>/dev/null || true)"
[[ -n "$content" ]] || die "no completion returned. Check the serving container:
     oc logs -n ${LLMD_NAMESPACE} -l app.kubernetes.io/part-of=${ISVC} -c main --tail=100"

echo
ok "model responded: ${content}"

# ---------------------------------------------------------------------------
cat <<EOF

  Reach it from a workbench or another pod, in-cluster:

    http://${LLMD_GATEWAY_NAME}-openshift-default.${LLMD_GATEWAY_NAMESPACE}.svc.cluster.local/${LLMD_NAMESPACE}/${ISVC}/v1

  From your laptop, through the jump box (SOCKS proxy per the CRIAB cheatsheet),
  or keep using this port-forward:

    oc port-forward -n ${LLMD_GATEWAY_NAMESPACE} ${GW_SVC} ${PF_PORT}:80

EOF

ok "llm-d verify complete"
