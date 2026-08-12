#!/usr/bin/env bash
# Phase 12 — HIGH SIDE. Provision a GPU node.
#
#   scripts/12-gpu-machineset.sh              # discover, render, apply, wait
#   scripts/12-gpu-machineset.sh --show       # print the rendered MachineSet only
#   scripts/12-gpu-machineset.sh --delete     # scale to 0 and remove
#
# Every cluster-specific value — AMI, subnet, security group, IAM profile — is
# cloned from the existing worker MachineSet. Nothing is hard-coded, because a
# stale AMI produces an instance that boots and never joins, and the only
# evidence is in the machine-controller log.
#
# This SPENDS MONEY. A g6e.2xlarge is roughly $2/hour on demand and the node
# stays up until someone removes it. The script prints the instance type and
# waits for confirmation unless GPU_CONFIRM=false.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env

require_cmd oc jq
require_cluster_admin

ACTION=apply
case "${1:-}" in
  --show)   ACTION=show ;;
  --delete) ACTION=delete ;;
  "")       ;;
  *)        die "usage: $0 [--show|--delete]" ;;
esac

# ---------------------------------------------------------------------------
step "Discovering cluster values from the existing worker MachineSet"

INFRA_ID="$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')"
[[ -n "$INFRA_ID" ]] || die "could not read the cluster infrastructure name"

# Pick a worker set explicitly rather than items[0] — on a cluster that already
# has a GPU set, items[0] may BE the GPU set, and cloning it copies the GPU
# instance type back over itself.
src="$(oc get machineset -n openshift-machine-api -o json \
  | jq -r --arg id "$INFRA_ID" '
      [.items[]
       | select(.spec.template.spec.providerSpec.value.instanceType != null)
       | select((.metadata.name | test("gpu")) | not)]
      | sort_by(.metadata.name)[0] // empty')"
[[ -n "$src" ]] || die "no non-GPU MachineSet found in openshift-machine-api to clone from"

SRC_NAME="$(printf '%s' "$src" | jq -r '.metadata.name')"
AMI="$(printf     '%s' "$src" | jq -r '.spec.template.spec.providerSpec.value.ami.id')"
SUBNET="$(printf  '%s' "$src" | jq -r '.spec.template.spec.providerSpec.value.subnet.id // empty')"
REGION="$(printf  '%s' "$src" | jq -r '.spec.template.spec.providerSpec.value.placement.region')"
AZ="$(printf      '%s' "$src" | jq -r '.spec.template.spec.providerSpec.value.placement.availabilityZone')"
IAM_PROFILE="$(printf '%s' "$src" | jq -r '.spec.template.spec.providerSpec.value.iamInstanceProfile.id')"
SG="$(printf '%s' "$src" | jq -r '
  .spec.template.spec.providerSpec.value.securityGroups[0].filters[]?
  | select(.name=="tag:Name") | .values[0] // empty')"

# Some installs reference the subnet by tag filter instead of by id. Fall back
# rather than emitting a MachineSet with an empty subnet, which AWS accepts and
# then fails to place.
if [[ -z "$SUBNET" ]]; then
  SUBNET_FILTER="$(printf '%s' "$src" | jq -r '
    .spec.template.spec.providerSpec.value.subnet.filters[]?
    | select(.name=="tag:Name") | .values[0] // empty')"
  [[ -n "$SUBNET_FILTER" ]] \
    || die "worker MachineSet ${SRC_NAME} names its subnet neither by id nor by tag:Name — render manifests/gpu/machineset-l40s.yaml by hand"
  warn "worker set uses a subnet tag filter, not an id: ${SUBNET_FILTER}"
  warn "  resolving it would need AWS API access; set OCP_PRIVATE_SUBNET_ID in"
  warn "  CRIAB's config to override, or edit the rendered manifest."
  SUBNET="${OCP_PRIVATE_SUBNET_ID:-}"
  [[ -n "$SUBNET" ]] || die "no subnet id available — set OCP_PRIVATE_SUBNET_ID in ${CRIAB_ENV}"
fi

[[ -n "$SG" ]] || SG="${INFRA_ID}-node"

export INFRA_ID AMI SUBNET REGION AZ IAM_PROFILE SG
export INSTANCE_TYPE="${GPU_INSTANCE_TYPE:-g6e.2xlarge}"
export GPU_REPLICAS="${GPU_REPLICAS:-1}"
export GPU_VOLUME_SIZE="${GPU_VOLUME_SIZE:-200}"
export MS_NAME="${GPU_MACHINESET_NAME:-${INFRA_ID}-gpu-${AZ}}"

if [[ "${GPU_TAINT:-false}" == "true" ]]; then
  export GPU_TAINTS_BLOCK="      taints:
        - key: nvidia.com/gpu
          effect: NoSchedule"
else
  export GPU_TAINTS_BLOCK=""
fi

printf '\n  %-16s %s\n' \
  "cloned from"   "$SRC_NAME" \
  "machineset"    "$MS_NAME" \
  "instance type" "$INSTANCE_TYPE" \
  "replicas"      "$GPU_REPLICAS" \
  "region / az"   "${REGION} / ${AZ}" \
  "ami"           "$AMI" \
  "subnet"        "$SUBNET" \
  "iam profile"   "$IAM_PROFILE" \
  "security grp"  "$SG" \
  "root volume"   "${GPU_VOLUME_SIZE} GB" \
  "gpu taint"     "${GPU_TAINT:-false}"
echo

# ---------------------------------------------------------------------------
if [[ "$ACTION" == "delete" ]]; then
  step "Removing MachineSet ${MS_NAME}"
  run oc scale machineset "$MS_NAME" -n openshift-machine-api --replicas=0
  run oc wait --for=delete machine -n openshift-machine-api \
    -l "machine.openshift.io/cluster-api-machineset=${MS_NAME}" --timeout=900s || true
  run oc delete machineset "$MS_NAME" -n openshift-machine-api --ignore-not-found
  ok "GPU MachineSet removed"
  exit 0
fi

render() {
  require_cmd envsubst
  envsubst < "${REPO_ROOT}/manifests/gpu/machineset-l40s.yaml"
}

if [[ "$ACTION" == "show" ]]; then
  render
  exit 0
fi

# ---------------------------------------------------------------------------
# Is this instance type even offered here? A g6e that AWS does not sell in this
# AZ leaves the Machine in Provisioning with the reason only in the controller
# log — cheap to check, expensive to debug.
step "Checking ${INSTANCE_TYPE} is offered in ${AZ}"

if command -v aws >/dev/null 2>&1; then
  offered="$(aws ec2 describe-instance-type-offerings \
      --location-type availability-zone \
      --filters "Name=instance-type,Values=${INSTANCE_TYPE}" \
                "Name=location,Values=${AZ}" \
      --region "$REGION" --query 'InstanceTypeOfferings[0].InstanceType' \
      --output text 2>/dev/null || true)"
  if [[ "$offered" == "$INSTANCE_TYPE" ]]; then
    ok "${INSTANCE_TYPE} is available in ${AZ}"
  else
    warn "${INSTANCE_TYPE} does not appear to be offered in ${AZ}."
    warn "  L40S (g6e) is not in every zone. Check what is:"
    warn "    aws ec2 describe-instance-type-offerings --location-type availability-zone \\"
    warn "      --filters Name=location,Values=${AZ} --region ${REGION} \\"
    warn "      --query 'InstanceTypeOfferings[?starts_with(InstanceType,\`g6e\`)||starts_with(InstanceType,\`g5\`)].InstanceType' --output text"
    warn "  Set GPU_INSTANCE_TYPE in config/llmd.env to one that is."
    [[ "${GPU_CONFIRM:-true}" == "false" ]] || die "refusing to apply (GPU_CONFIRM=false to override)"
  fi
else
  warn "aws CLI not found — cannot verify ${INSTANCE_TYPE} is offered in ${AZ}"
fi

# Service quotas are the other silent failure: a fresh account often has a
# zero vCPU quota for G-family on-demand instances, and the Machine then sits
# in Provisioning with a VcpuLimitExceeded event.
warn "if the Machine stays in Provisioning, check the G-family vCPU quota:"
warn "  aws service-quotas get-service-quota --service-code ec2 \\"
warn "    --quota-code L-DB2E81BA --region ${REGION}   # Running On-Demand G instances"

# ---------------------------------------------------------------------------
if [[ "${GPU_CONFIRM:-true}" == "true" && "${DRY_RUN:-false}" != "true" ]]; then
  echo
  warn "This provisions ${GPU_REPLICAS} x ${INSTANCE_TYPE} and will keep billing until removed."
  read -r -p "  Type the instance type to confirm: " reply
  [[ "$reply" == "$INSTANCE_TYPE" ]] || die "not confirmed — nothing applied"
fi

step "Applying MachineSet ${MS_NAME}"
if [[ "${DRY_RUN:-false}" == "true" ]]; then
  render | sed 's/^/  /'
  dim "would apply the above"
  exit 0
fi
render | oc apply -f -
ok "MachineSet applied"

# ---------------------------------------------------------------------------
step "Waiting for the GPU node (AWS provisioning plus a full RHCOS boot: 5-15m)"

machine_running() {
  local phase
  phase="$(oc get machine -n openshift-machine-api \
    -l "machine.openshift.io/cluster-api-machineset=${MS_NAME}" \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
  [[ "$phase" == "Running" ]]
}
last=""
deadline=$(( SECONDS + 1800 ))
while (( SECONDS < deadline )) && ! machine_running; do
  cur="$(oc get machine -n openshift-machine-api \
    -l "machine.openshift.io/cluster-api-machineset=${MS_NAME}" \
    --no-headers 2>/dev/null | awk '{print $1" "$2}' | tr '\n' ' ')"
  if [[ "$cur" != "$last" ]]; then printf '\n  %s' "${cur:-no machine yet}"; last="$cur"; else printf '.'; fi
  sleep 15
done
echo
machine_running || {
  oc get machine -n openshift-machine-api -l "machine.openshift.io/cluster-api-machineset=${MS_NAME}" -o wide || true
  oc get events -n openshift-machine-api --sort-by=.lastTimestamp | tail -20 || true
  die "Machine did not reach Running. The events above usually name the cause —
     VcpuLimitExceeded (quota), Unsupported (instance type not in this AZ), or
     InsufficientInstanceCapacity (AWS has none right now; try another AZ)."
}
ok "Machine Running"

node_ready() {
  local n
  n="$(oc get nodes -l node-role.kubernetes.io/gpu -o json 2>/dev/null \
       | jq -r '[.items[] | select(.status.conditions[]? | select(.type=="Ready" and .status=="True"))] | length')"
  [[ "${n:-0}" -ge "$GPU_REPLICAS" ]]
}
wait_for "GPU node(s) Ready" 1200 node_ready

oc get nodes -l node-role.kubernetes.io/gpu \
  -o custom-columns=NAME:.metadata.name,STATUS:.status.conditions[-1].type,INSTANCE:.metadata.labels.node\\.kubernetes\\.io/instance-type

echo
ok "GPU node provisioned"
cat <<EOF

  The node exists, but it has no nvidia.com/gpu capacity yet — NFD has to label
  it and the NVIDIA driver has to build and load. On a disconnected cluster
  that build is the part that fails. Next:

    scripts/14-gpu-driver-disconnected.sh diagnose

EOF
