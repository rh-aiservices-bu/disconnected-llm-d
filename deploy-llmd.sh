#!/usr/bin/env bash
# Deploy llm-d onto a disconnected RHOAI cluster.
#
#   ./deploy-llmd.sh low       # jump box   : preflight, mirror, transfer
#   ./deploy-llmd.sh high      # cluster    : push, verify, configure, deploy, test
#   ./deploy-llmd.sh <NN>      # one phase
#   ./deploy-llmd.sh list
#
# Assumes OpenShift and RHOAI are already installed and healthy in a
# disconnected environment. This repo deploys the llm-d layer only:
#   https://github.com/rh-aiservices-bu/disconnected-rhoai builds what is underneath.

source "$(dirname "${BASH_SOURCE[0]}")/scripts/lib/common.sh"

S="${REPO_ROOT}/scripts"

PHASES_LOW=(
  "01:preflight (low):${S}/00-preflight.sh low"
  "10:mirror images to disk:${S}/10-mirror-images.sh"
  "15:transfer to the high side:${S}/15-transfer.sh"
)
PHASES_HIGH=(
  "06:preflight (high):${S}/00-preflight.sh high"
  "18:push images + mirror rules:${S}/18-push-images.sh"
  "20:verify mirror contents:${S}/20-verify-mirror.sh"
  "30:enable OCI ModelCar:${S}/30-enable-modelcar.sh"
  "40:deploy llm-d:${S}/40-deploy.sh"
  "50:verify inference:${S}/50-verify.sh"
)
# Run once per cluster, deliberately outside `high`: provisioning a node costs
# money and the driver work has to be read, not automated past.
PHASES_SETUP=(
  "12:GPU MachineSet (L40S):${S}/12-gpu-machineset.sh"
  "14:GPU driver (disconnected):${S}/14-gpu-driver-disconnected.sh"
  "16:Leader Worker Set Operator:${S}/16-install-lws.sh"
)

usage() {
  cat >&2 <<'EOF'
usage: ./deploy-llmd.sh <low|high|list|PHASE>

THE WHOLE PROCESS — four commands

  laptop     scripts/remote.sh sync
  high side  ./deploy-llmd.sh 05          # discover what this cluster needs
  laptop     scripts/remote.sh sync       # carry that list to the low side
  low side   ./deploy-llmd.sh low         # mirror + transfer   (~20 min)
  high side  ./deploy-llmd.sh high        # push + deploy + test (~20 min)

PHASES

  05   high  discover required images -> config/required-images.txt
  01   low   preflight
  10   low   mirror to disk
  15   low   transfer to the high side (verifies the copy)
  18   high  push to Quay, apply mirror rules, wait for rollout
  20   high  verify every required image is present
  30   high  enable OCI ModelCar in KServe
  40   high  deploy the Gateway and the model
  50   high  send a real inference request
  90   high  teardown  (--all also removes the namespace and Gateway)

ONE-TIME CLUSTER SETUP (only if the cluster has no working GPU)

  12   high  provision an L40S GPU node       (SPENDS MONEY)
  14   both  GPU driver; start with: ./deploy-llmd.sh 14 diagnose
  16   high  LeaderWorkerSet Operator (needed only for multi-node serving)

Every phase is re-runnable and accepts DRY_RUN=true.
Configure with config/llmd.env (copy from config/llmd.env.example).
EOF
  exit 1
}

run_set() {
  local start=$SECONDS entry
  for entry in "$@"; do
    local num="${entry%%:*}" rest="${entry#*:}"
    step "[$num] ${rest%%:*}"
    # shellcheck disable=SC2086
    ${rest#*:} || die "phase $num (${rest%%:*}) failed — fix it and re-run: ./deploy-llmd.sh $num"
  done
  ok "completed in $(( (SECONDS - start) / 60 ))m"
}

print_set() {
  local title="$1"; shift
  printf '\n%s\n' "$title"
  for e in "$@"; do
    local num="${e%%:*}" rest="${e#*:}"
    printf '  %-4s %-28s %s\n' "$num" "${rest%%:*}" "$(printf '%s' "${rest#*:}" | sed "s|${REPO_ROOT}/||")"
  done
}

case "${1:-}" in
  low)  load_env; run_set "${PHASES_LOW[@]}" ;;
  high) load_env; run_set "${PHASES_HIGH[@]}" ;;
  list)
    print_set "LOW SIDE (jump box, has internet)" "${PHASES_LOW[@]}"
    print_set "HIGH SIDE (disconnected)"          "${PHASES_HIGH[@]}"
    print_set "ONE-TIME CLUSTER SETUP (high side, not part of \`high\`)" "${PHASES_SETUP[@]}"
    printf '\n  %-4s %-28s %s\n' "05" "discover required images" "scripts/05-discover-images.sh"
    printf '  %-4s %-28s %s\n\n' "90" "teardown" "scripts/90-teardown.sh"
    ;;
  01|00) exec "${S}/00-preflight.sh" low ;;
  05)    exec "${S}/05-discover-images.sh" ;;
  06)    exec "${S}/00-preflight.sh" high ;;
  10)    exec "${S}/10-mirror-images.sh" ;;
  12)    shift; exec "${S}/12-gpu-machineset.sh" "$@" ;;
  14)    shift; exec "${S}/14-gpu-driver-disconnected.sh" "$@" ;;
  15)    exec "${S}/15-transfer.sh" ;;
  16)    shift; exec "${S}/16-install-lws.sh" "$@" ;;
  18)    exec "${S}/18-push-images.sh" ;;
  20)    exec "${S}/20-verify-mirror.sh" ;;
  30)    exec "${S}/30-enable-modelcar.sh" ;;
  40)    exec "${S}/40-deploy.sh" ;;
  50)    exec "${S}/50-verify.sh" ;;
  90)    shift; exec "${S}/90-teardown.sh" "$@" ;;
  *)     usage ;;
esac
