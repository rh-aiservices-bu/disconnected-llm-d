#!/usr/bin/env bash
# Phase 20 — HIGH SIDE. Prove every image llm-d needs is already in Quay.
#
#   scripts/20-verify-mirror.sh
#
# This is the gate. An ImagePullBackOff on a disconnected cluster is almost
# always a missing mirror entry, and finding that out forty minutes into a
# deployment — after the MachineConfig rollout, after the operator install — is
# the expensive way to learn it.
#
# Two sets are checked:
#
#   1. The ModelCar images this project adds. If these are missing, phase 10
#      did not complete or phase 20 of the CRIAB pipeline was never run.
#
#   2. The images the RUNNING cluster says llm-d will use — read out of the
#      LLMInferenceServiceConfig presets and the KServe config, not guessed.
#      These should already be mirrored via the RHOAI bundle; this confirms it
#      rather than assuming it.
#
# Presence is tested with `podman manifest inspect`. Quay's /v2/_catalog returns
# zero repositories in this environment regardless of what is stored, so an
# empty catalog listing is not evidence of anything.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env

require_cmd oc jq podman
require_cluster_admin
mirror_login
load_mirror_rules

rule_count="$(printf '%s' "${MIRROR_RULES:-}" | grep -c . || true)"
step "Phase 20 — verifying mirror contents against ${MIRROR_REGISTRY}"
ok "loaded ${rule_count} mirror rule(s) from the cluster's IDMS/ITMS/ICSP"

MISSING=()
UNMAPPED=()
OTHER_ACCEL=()
PRESENT=0

# Which accelerator families does this cluster actually have? Used to decide
# whether a missing ROCm/Gaudi/Spyre runtime is a real problem or just noise.
gpus_nvidia="$(oc get nodes -o json | jq '[.items[].status.capacity["nvidia.com/gpu"] // "0" | tonumber] | add')"

verify() {
  local ref="$1" label="${2:-}" rc=0
  # Skip anything already pointing at the mirror — nothing to redirect.
  [[ "$ref" == "${MIRROR_REGISTRY}"/* ]] && return 0

  mirror_has_image "$ref" || rc=$?
  case $rc in
    # The `|| true` is load-bearing. As the last statement of this branch a bare
    # `[[ ... ]] && printf` returns 1 whenever VERBOSE is unset, which makes
    # verify() return 1, which under `set -e` silently kills the whole script
    # after the FIRST image that verifies successfully.
    0) PRESENT=$(( PRESENT + 1 ))
       printf '%s  ok%s %s%s\n' "$C_GRN" "$C_RST" "$ref" "${label:+  (${label})}"
       [[ -n "${VERBOSE:-}" ]] && printf '       -> %s\n' "$MIRROR_LAST_REF" || true ;;
    1) MISSING+=("$ref")
       printf '%s MISS%s %s%s\n' "$C_RED" "$C_RST" "$ref" "${label:+  (${label})}"
       printf '       looked for %s\n' "$MIRROR_LAST_REF" ;;
    2) UNMAPPED+=("$ref")
       printf '%sNORULE%s %s%s\n' "$C_YEL" "$C_RST" "$ref" "${label:+  (${label})}" ;;
  esac
}

# ---------------------------------------------------------------------------
step "1/2  ModelCar images added by this project"

verify "$MODELCAR_QWEN25_05B" "$MODELCAR_QWEN25_05B_TAG"
verify "$MODELCAR_QWEN3_4B"   "$MODELCAR_QWEN3_4B_TAG"

# ---------------------------------------------------------------------------
step "2/2  Images the cluster says llm-d will pull"

# Serving-runtime and scheduler images come from the LLMInferenceServiceConfig
# presets the RHOAI operator ships. Reading them beats hard-coding a list that
# goes stale on the next RHOAI z-stream.
preset_images="$(oc get llminferenceserviceconfig -A -o json 2>/dev/null \
  | jq -r '[.. | .image? // empty] | unique[]' 2>/dev/null || true)"

# The storage initializer is named in the KServe config, not in a preset.
si_image="$(oc get configmap inferenceservice-config -n "$KSERVE_NAMESPACE" \
  -o jsonpath='{.data.storageInitializer}' 2>/dev/null | jq -r '.image // empty' || true)"

discovered="$(printf '%s\n%s\n' "$preset_images" "$si_image" | grep -E '^[a-z0-9.-]+\.[a-z]+/' | sort -u || true)"

if [[ -z "$discovered" ]]; then
  warn "found no images in LLMInferenceServiceConfig presets or the KServe config."
  warn "  Either the LLM stack is not installed, or KSERVE_NAMESPACE is wrong"
  warn "  (currently '${KSERVE_NAMESPACE}'). Phase 00 checks this properly."
else
  # The presets declare a runtime image per accelerator family. On an NVIDIA
  # cluster the ROCm/Gaudi/Spyre variants will never be scheduled, and failing
  # the run over them buries the ones that actually matter. Report them, but
  # separately.
  accel_re='vllm-(rocm|gaudi|spyre)'
  for img in $discovered; do
    [[ -n "$img" ]] || continue
    if [[ "$img" =~ $accel_re ]] && (( gpus_nvidia > 0 )); then
      OTHER_ACCEL+=("$img")
      printf '%s skip%s %s  (other accelerator — not used on this cluster)\n' "$C_DIM" "$C_RST" "$img"
      continue
    fi
    verify "$img" "cluster-declared"
  done
fi

# ---------------------------------------------------------------------------
echo
if (( ${#UNMAPPED[@]} > 0 )); then
  step "${#UNMAPPED[@]} image(s) have NO mirror rule"
  printf '  %s\n' "${UNMAPPED[@]}"
  cat <<EOF

  No IDMS/ITMS entry covers these, so CRI-O will not redirect a pull of the
  original reference — putting the image in the registry is not enough on its
  own. oc-mirror generates the matching IDMS when it pushes; the generated file
  then has to be applied:

    oc apply -f /mnt/mirror/<workdir>/working-dir/cluster-resources/idms-oc-mirror.yaml

  Applying it triggers a MachineConfig rollout and the nodes reboot. Batch it
  with any other IDMS/ITMS change rather than applying them one at a time.

EOF
fi

if (( ${#MISSING[@]} > 0 )); then
  step "${#MISSING[@]} image(s) missing from the mirror"
  printf '  %s\n' "${MISSING[@]}"
  cat <<EOF

  Add them on the LOW side and re-run the pipeline:

    cd ${CRIAB_DIR:-~/criab}
    printf '%s\n' ${MISSING[*]@Q} >> config/additional-images.txt
    ./deploy-rhoai.sh 10 && ./deploy-rhoai.sh 15
    # then, back on the high side:
    ./deploy-rhoai.sh 20

  If a "cluster-declared" image is missing, that is worth understanding before
  papering over it — it means the RHOAI bundle mirror did not cover something
  the operator now references, and other RHOAI features will hit it too.

EOF
  exit 1
fi

# Reached only when nothing is missing. An unmapped image is still a failure —
# claiming "all present" while a pull could never be redirected would be worse
# than saying nothing.
if (( ${#UNMAPPED[@]} > 0 )); then
  die "${PRESENT} image(s) present, but ${#UNMAPPED[@]} have no mirror rule (listed above)"
fi

ok "all ${PRESENT} image(s) present in ${MIRROR_REGISTRY}"
