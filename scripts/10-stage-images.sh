#!/usr/bin/env bash
# Phase 10 — LOW SIDE. Get the ModelCar images into the mirror set.
#
#   scripts/10-stage-images.sh              # add the refs to CRIAB's list
#   scripts/10-stage-images.sh --resolve    # re-pin tags -> digests first
#   scripts/10-stage-images.sh --mirror     # add, then actually run the pipeline
#
# WHAT NEEDS MIRRORING, AND WHAT DOES NOT
#
# Only the model weights. Everything else llm-d runs — the vLLM serving image,
# the endpoint-picker/scheduler, the storage initializer, the Istio proxy behind
# the Gateway — arrives through the RHOAI operator bundle's relatedImages and
# the OSSM 3 bundle, both of which CRIAB already mirrored. Adding them here
# would re-mirror content that is present, which costs an hour and no benefit.
#
# Phase 20 on the high side verifies that assumption instead of trusting it.
#
# This is CRIAB's "Route A" — the reproducible path. A rebuilt environment
# re-mirrors from config/additional-images.txt and llm-d still works. Do not be
# tempted by Route B (podman push straight to Quay) for anything that is
# supposed to survive.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env

RESOLVE=false
MIRROR=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --resolve) RESOLVE=true; shift ;;
    --mirror)  MIRROR=true;  shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

require_vars CRIAB_DIR
ADD_FILE="${CRIAB_DIR}/config/additional-images.txt"
[[ -f "$ADD_FILE" ]] || die "not found: ${ADD_FILE} — is CRIAB_DIR right? (${CRIAB_DIR})"

step "Phase 10 — staging ModelCar images into the mirror set"

# ---------------------------------------------------------------------------
# 1. optionally re-resolve tag -> digest
#
# Tags in the ModelCar catalog do move; the dated tags (…-20260806t1458z) are
# the immutable ones. Re-pinning is a deliberate act, not something to do on
# every run, because it silently changes which weights the cluster serves.
if [[ "$RESOLVE" == "true" ]]; then
  require_cmd jq
  repo="quay.io/redhat-ai-services/modelcar-catalog"
  step "Re-resolving digests from ${repo}"
  for pair in "MODELCAR_QWEN25_05B:${MODELCAR_QWEN25_05B_TAG}" \
              "MODELCAR_QWEN3_4B:${MODELCAR_QWEN3_4B_TAG}"; do
    var="${pair%%:*}"; tag="${pair#*:}"
    d="$(resolve_digest "${repo}:${tag}")"
    [[ "$d" == sha256:* ]] || die "could not resolve ${repo}:${tag}"
    printf '  %-22s %s -> %s\n' "$tag" "$var" "$d"
    printf '%s="%s@%s"\n' "$var" "$repo" "$d" >> "${REPO_ROOT}/config/llmd.env.resolved"
    declare "$var=${repo}@${d}"
  done
  ok "wrote config/llmd.env.resolved — copy the lines you want into config/llmd.env"
fi

# ---------------------------------------------------------------------------
# 2. append to CRIAB's additional-images.txt, idempotently
step "Adding ModelCar references to ${ADD_FILE}"

added=0
for ref in "$MODELCAR_QWEN25_05B" "$MODELCAR_QWEN3_4B" "$KERNEL_REPO_BASE_IMAGE"; do
  [[ -n "$ref" ]] || continue
  if grep -qxF "$ref" "$ADD_FILE"; then
    ok "already present: ${ref##*/}"
  elif [[ "${DRY_RUN:-false}" == "true" ]]; then
    dim "would append: ${ref}"
  else
    # Comment the human-readable tag alongside the digest. Six months from now
    # a bare sha256 in this file tells nobody which model it is.
    case "$ref" in
      "$MODELCAR_QWEN25_05B")   note="ModelCar ${MODELCAR_QWEN25_05B_TAG}" ;;
      "$MODELCAR_QWEN3_4B")     note="ModelCar ${MODELCAR_QWEN3_4B_TAG}" ;;
      "$KERNEL_REPO_BASE_IMAGE") note="httpd base for the disconnected GPU kernel/CUDA repo" ;;
      *)                        note="llm-d" ;;
    esac
    printf '\n# llm-d: %s\n%s\n' "$note" "$ref" >> "$ADD_FILE"
    ok "appended: ${note}"
    added=$(( added + 1 ))
  fi
done

if (( added == 0 )) && [[ "$MIRROR" != "true" && "${DRY_RUN:-false}" != "true" ]]; then
  ok "nothing new to mirror"
fi

# ---------------------------------------------------------------------------
# 3. run the pipeline, or print it
#
# oc-mirror re-walks the whole ImageSetConfiguration, so this transfers only the
# new blobs but still takes a while. Under nohup with a per-run log, per the
# CRIAB convention — a monitoring command timing out must not kill the mirror.
LOG="${LLMD_LOG_DIR}/llmd-mirror-$(date +%Y%m%d-%H%M%S).log"

if [[ "$MIRROR" == "true" ]]; then
  step "Running the CRIAB mirror pipeline (log: ${LOG})"
  run bash -c "cd '${CRIAB_DIR}' && ./deploy-rhoai.sh 10 2>&1 | tee -a '${LOG}'"
  run bash -c "cd '${CRIAB_DIR}' && ./deploy-rhoai.sh 15 2>&1 | tee -a '${LOG}'"
  ok "mirrored to disk and transferred — now run phase 20 on the HIGH side:"
  echo "    scripts/remote.sh run high -- 'cd ~/criab && ./deploy-rhoai.sh 20'"
else
  step "Next steps (not run — pass --mirror to run them here)"
  cat <<EOF

  On the LOW side, mirror to disk and then transfer. Chained with && , not two
  background jobs — phase 15 rsyncs the archive phase 10 produces, so starting
  them together transfers a half-written file:

    cd ${CRIAB_DIR}
    nohup bash -c './deploy-rhoai.sh 10 && ./deploy-rhoai.sh 15' > ${LOG} 2>&1 &

  Then on the HIGH side, push into Quay:

    cd ~/criab && nohup ./deploy-rhoai.sh 20 > ${LLMD_LOG_DIR}/llmd-push.log 2>&1 &

  Poll the logs; do not judge progress by process liveness. The honest signal
  is the archive growing:

    f=/mnt/mirror/criab-mirror/mirror_seq1.tar
    a=\$(stat -c %s \$f); sleep 30; b=\$(stat -c %s \$f)
    echo "\$(( (b-a)/1048576 )) MB in 30s"

EOF
fi

ok "phase 10 complete"
