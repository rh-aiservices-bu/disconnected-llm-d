#!/usr/bin/env bash
# Deploy llm-d onto a disconnected RHOAI cluster.
#
#   ./deploy-llmd.sh low       # jump box: stage the ModelCar images
#   ./deploy-llmd.sh high      # cluster side: verify, configure, deploy, test
#   ./deploy-llmd.sh <NN>      # a single phase
#   ./deploy-llmd.sh list
#
# Assumes OpenShift and RHOAI are already installed and healthy — this repo
# deploys the llm-d layer only. CRIAB builds everything underneath it.
#
# Same shape as CRIAB's deploy-rhoai.sh, on purpose: one driver, numbered
# phases, each phase runnable on its own when something needs a second attempt.

source "$(dirname "${BASH_SOURCE[0]}")/scripts/lib/common.sh"

S="${REPO_ROOT}/scripts"

PHASES_LOW=(
  "00:preflight (low):${S}/00-preflight.sh low"
  "10:stage ModelCar images:${S}/10-stage-images.sh"
)
PHASES_HIGH=(
  "05:preflight (high):${S}/00-preflight.sh high"
  "20:verify mirror contents:${S}/20-verify-mirror.sh"
  "30:enable OCI ModelCar:${S}/30-enable-modelcar.sh"
  "40:deploy llm-d:${S}/40-deploy.sh"
  "50:verify inference:${S}/50-verify.sh"
)

# GPU and LWS are deliberately NOT in the `high` run. Provisioning a GPU node
# spends money and takes 15 minutes; the driver remedy is diagnostic work that
# has to be read, not automated past. Run them explicitly, once, before `high`.
PHASES_GPU=(
  "12:GPU MachineSet (L40S):${S}/12-gpu-machineset.sh"
  "14:GPU driver (disconnected):${S}/14-gpu-driver-disconnected.sh"
  "16:Leader Worker Set Operator:${S}/16-install-lws.sh"
)

usage() {
  cat >&2 <<'EOF'
usage: ./deploy-llmd.sh <low|high|list|PHASE>

  low     jump box    : 00 -> 10          (needs internet)
  high    disconnected: 05 -> 20 -> 30 -> 40 -> 50
  list    show all phases
  PHASE   run one phase (00 05 10 12 14 16 20 30 40 50 90)

  12      GPU MachineSet — provision an L40S node (SPENDS MONEY)
  14      GPU driver on a disconnected cluster; start with:
            ./deploy-llmd.sh 14 diagnose
  16      Leader Worker Set Operator (needed for multi-node serving)
  90      teardown (high side; --all also removes namespace and Gateway)

Phases 12/14/16 are one-time cluster setup and are NOT part of `high`. Run them
first if the cluster has no working GPU:

  ./deploy-llmd.sh 12                  # provision the node
  ./deploy-llmd.sh 14 diagnose         # find out what is actually broken
  ./deploy-llmd.sh 16                  # optional unless serving multi-node

Between low and high you must run CRIAB's mirror pipeline so the staged images
actually reach Quay:

  low :  cd ~/criab && ./deploy-rhoai.sh 10 && ./deploy-rhoai.sh 15
  high:  cd ~/criab && ./deploy-rhoai.sh 20

Phase 10 prints those commands, or pass --mirror to have it run them.

Configure with config/llmd.env (copy from config/llmd.env.example).
EOF
  exit 1
}

run_set() {
  local start_ts=$SECONDS entry
  for entry in "$@"; do
    local num="${entry%%:*}" rest="${entry#*:}"
    local name="${rest%%:*}" cmd="${rest#*:}"
    step "[$num] $name"
    # shellcheck disable=SC2086
    ${cmd} || die "phase $num ($name) failed"
  done
  ok "completed in $(( (SECONDS - start_ts) / 60 ))m"
}

print_set() {
  local title="$1"; shift
  printf '\n%s\n' "$title"
  for e in "$@"; do
    local num="${e%%:*}" rest="${e#*:}"
    printf '  %-4s %-26s %s\n' "$num" "${rest%%:*}" "$(printf '%s' "${rest#*:}" | sed "s|${REPO_ROOT}/||")"
  done
}

case "${1:-}" in
  low)  load_env; run_set "${PHASES_LOW[@]}" ;;
  high) load_env; run_set "${PHASES_HIGH[@]}" ;;
  list)
    print_set "LOW SIDE (jump box, has internet)"  "${PHASES_LOW[@]}"
    print_set "HIGH SIDE (disconnected)"           "${PHASES_HIGH[@]}"
    print_set "CLUSTER SETUP (high side, run once, not part of \`high\`)" "${PHASES_GPU[@]}"
    printf '\n  %-4s %-26s %s\n\n' "90" "teardown" "scripts/90-teardown.sh"
    ;;
  00) exec "${S}/00-preflight.sh" low ;;
  05) exec "${S}/00-preflight.sh" high ;;
  10) shift; exec "${S}/10-stage-images.sh" "$@" ;;
  12) shift; exec "${S}/12-gpu-machineset.sh" "$@" ;;
  14) shift; exec "${S}/14-gpu-driver-disconnected.sh" "$@" ;;
  16) shift; exec "${S}/16-install-lws.sh" "$@" ;;
  20) exec "${S}/20-verify-mirror.sh" ;;
  30) exec "${S}/30-enable-modelcar.sh" ;;
  40) exec "${S}/40-deploy.sh" ;;
  50) exec "${S}/50-verify.sh" ;;
  90) shift; exec "${S}/90-teardown.sh" "$@" ;;
  *)  usage ;;
esac
