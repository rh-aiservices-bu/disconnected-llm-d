#!/usr/bin/env bash
# Phase 16 — HIGH SIDE. Install the Leader Worker Set Operator.
#
#   scripts/16-install-lws.sh            # install and wait
#   scripts/16-install-lws.sh --check    # report status only
#
# WHEN YOU ACTUALLY NEED THIS
#
# Red Hat lists the LeaderWorkerSet Operator as an llm-d prerequisite, because
# on a connected cluster the rhai-on-openshift Helm chart installs it through
# OLM automatically. That chart lives at registry.redhat.io and the disconnected
# path does not use it, so nothing installs LWS on its own here.
#
# For the single-node replicas this repo deploys by default it is OPTIONAL: the
# KServe controller calls IsCrdAvailable for LeaderWorkerSet and only registers
# the watch when the CRD exists, and single-node workloads reconcile into a
# plain Deployment. It becomes REQUIRED the moment you move to multi-node —
# disaggregated prefill/decode, or a model too large for one node.
#
# Install it anyway if you have the mirror capacity. It is small, and finding
# out it is missing halfway through a multi-node experiment is worse.
#
# PREREQUISITE: the operator must be in the mirrored catalog. CRIAB's RHOAI
# batch does not include it — see config/imageset-config-llmd.yaml.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env

require_cmd oc jq
require_cluster_admin

LWS_NS="${LWS_NS:-openshift-lws-operator}"
LWS_PKG="${LWS_PKG:-leader-worker-set}"
LWS_CHANNEL="${LWS_CHANNEL:-stable-v1.0}"
LWS_CATALOG="${LWS_CATALOG:-redhat-operators}"

CHECK_ONLY=false
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=true

step "Phase 16 — Leader Worker Set Operator"

# ---------------------------------------------------------------------------
if oc get crd leaderworkersets.leaderworkerset.x-k8s.io >/dev/null 2>&1; then
  ok "LeaderWorkerSet CRD already present — nothing to do"
  oc get csv -n "$LWS_NS" 2>/dev/null | grep -i lws || true
  exit 0
fi

if [[ "$CHECK_ONLY" == "true" ]]; then
  warn "LeaderWorkerSet CRD not present"
  warn "  Optional for single-node serving, required for multi-node."
  exit 0
fi

# ---------------------------------------------------------------------------
# Is it even mirrored? Subscribing to a package OLM cannot see leaves a
# Subscription in ResolutionFailed, which is easy to miss because the
# Subscription object itself is created successfully.
step "1/4  Checking the package is in the mirrored catalog"

if oc get packagemanifest "$LWS_PKG" -n openshift-marketplace >/dev/null 2>&1; then
  src="$(oc get packagemanifest "$LWS_PKG" -n openshift-marketplace -o jsonpath='{.status.catalogSource}')"
  ok "${LWS_PKG} available from CatalogSource '${src}'"
  LWS_CATALOG="$src"
else
  cat >&2 <<EOF

$(printf '%s fail%s' "$C_RED" "$C_RST") package '${LWS_PKG}' is not in any CatalogSource on this cluster.

  It is not part of CRIAB's RHOAI mirror batch. Mirror it with the config in
  this repo, from the LOW side:

    export WORKDIR=/mnt/mirror/llmd-mirror
    oc-mirror --v2 --config config/imageset-config-llmd.yaml file://\${WORKDIR}
    rsync -avP --append \${WORKDIR}/ lab-user@\${HIGH_IP}:/mnt/mirror/llmd-mirror/

  Then on the HIGH side:

    oc-mirror --v2 --from /mnt/mirror/llmd-mirror \\
      docker://${MIRROR_REGISTRY:-<mirror-registry>}

  Then repoint the aliased catalog at the regenerated index — without this OLM
  keeps serving the old one and still cannot see the package:

    NEW=\$(awk '/image:/{print \$2; exit}' \\
      /mnt/mirror/llmd-mirror/working-dir/cluster-resources/cs-redhat-operator-index-*.yaml)
    oc patch catalogsource redhat-operators -n openshift-marketplace \\
      --type=merge -p "{\"spec\":{\"image\":\"\${NEW}\"}}"

  The regenerated index must still carry servicemeshoperator3, or the Gateway
  breaks. config/imageset-config-llmd.yaml includes it for that reason.

EOF
  exit 1
fi

# cert-manager is a hard dependency and OLM will not say so clearly.
if oc get crd certificates.cert-manager.io >/dev/null 2>&1; then
  ok "cert-manager present"
else
  die "cert-manager is not installed — LWS depends on it.
     CRIAB installs it when INSTALL_CERT_MANAGER=true."
fi

# ---------------------------------------------------------------------------
step "2/4  Namespace, OperatorGroup and Subscription"

apply_stdin "namespace/${LWS_NS}" <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${LWS_NS}
  labels:
    openshift.io/cluster-monitoring: "true"
YAML

apply_stdin "operatorgroup/openshift-lws-operator" <<YAML
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-lws-operator
  namespace: ${LWS_NS}
spec:
  targetNamespaces:
    - ${LWS_NS}
YAML

apply_stdin "subscription/${LWS_PKG}" <<YAML
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${LWS_PKG}
  namespace: ${LWS_NS}
spec:
  name: ${LWS_PKG}
  channel: ${LWS_CHANNEL}
  source: ${LWS_CATALOG}
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
YAML

# ---------------------------------------------------------------------------
step "3/4  Waiting for the CSV"

csv_ready() {
  local p
  p="$(oc get csv -n "$LWS_NS" -o json 2>/dev/null \
       | jq -r '[.items[] | select(.metadata.name | test("lws|leader-worker"; "i")) | .status.phase] | first // ""')"
  [[ "$p" == "Succeeded" ]]
}

if [[ "${DRY_RUN:-false}" != "true" ]]; then
  deadline=$(( SECONDS + 900 ))
  while (( SECONDS < deadline )) && ! csv_ready; do printf '.'; sleep 10; done
  echo
  if ! csv_ready; then
    oc get subscription -n "$LWS_NS" -o jsonpath='{.items[0].status.conditions}' 2>/dev/null | jq . || true
    oc get csv -n "$LWS_NS" 2>/dev/null || true
    die "the LWS CSV did not reach Succeeded.
     A ResolutionFailed condition above means the catalog does not actually
     carry this channel — check the channel name (${LWS_CHANNEL})."
  fi
  ok "CSV Succeeded"
fi

# ---------------------------------------------------------------------------
# The operator ships an operand CR that must exist before it deploys the
# LeaderWorkerSet controller. Installing the operator alone gets you a CSV and
# no CRD, which looks like a successful install right up until llm-d needs it.
step "4/4  Creating the LeaderWorkerSetOperator instance"

if [[ "${DRY_RUN:-false}" != "true" ]]; then
  # Discover the API group rather than hard-coding it — this operator is new
  # and the group has room to move between releases.
  api="$(oc get crd -o json 2>/dev/null | jq -r '
    .items[] | select(.spec.names.kind=="LeaderWorkerSetOperator")
    | .spec.group + "/" + ([.spec.versions[] | select(.served) | .name] | first)' | head -1)"

  if [[ -z "$api" ]]; then
    warn "no LeaderWorkerSetOperator CRD yet — the CSV may still be installing it."
    warn "  Create the instance once it appears:"
    warn "    oc get crd | grep -i leaderworkersetoperator"
  else
    apply_stdin "leaderworkersetoperator/cluster" <<YAML
apiVersion: ${api}
kind: LeaderWorkerSetOperator
metadata:
  name: cluster
  namespace: ${LWS_NS}
spec: {}
YAML
  fi

  crd_ready() { oc get crd leaderworkersets.leaderworkerset.x-k8s.io >/dev/null 2>&1; }
  wait_for "LeaderWorkerSet CRD" 600 crd_ready
fi

echo
oc get csv -n "$LWS_NS" 2>/dev/null | grep -i -E 'lws|leader-worker' || true
ok "Leader Worker Set Operator ready"
