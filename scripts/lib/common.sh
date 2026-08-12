#!/usr/bin/env bash
# Shared helpers. Sourced by every script in this repo.
#
# Deliberately standalone rather than sourcing CRIAB's scripts/lib/common.sh:
# this repo gets rsync'd to the lab hosts on its own, and a cross-repo source
# breaks the moment someone syncs one without the other. It DOES read CRIAB's
# config/criab.env, because MIRROR_REGISTRY and the credentials must not be
# duplicated.

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_DIM=$'\033[2m';  C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_DIM=""; C_RST=""
fi

log()  { printf '%s\n' "$*"; }
step() { printf '\n%s==>%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%swarn%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
die()  { printf '%s fail%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }
dim()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RST"; }

# Run a command, or just print it under DRY_RUN.
run() {
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    dim "would run: $*"
  else
    "$@"
  fi
}

# Apply a manifest from stdin, honouring DRY_RUN.
apply_stdin() {
  local what="$1"
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    dim "would apply: ${what}"
    cat > /dev/null
  else
    oc apply -f - >/dev/null && ok "applied ${what}"
  fi
}

# Case-insensitive regex test against a string, using no pipeline.
#
# `printf '%s' "$text" | grep -q PATTERN` looks equivalent and is not. grep -q
# exits at the FIRST match, the writer then gets SIGPIPE (status 141), and under
# `set -o pipefail` the pipeline reports failure — so a SUCCESSFUL match reads as
# no match. The bug is invisible while the input still fits in the pipe buffer
# and appears only once it grows, which is the worst way to find it. It cost a
# false "no ImageDigestMirrorSet" on a cluster that had four.
#
# nocasematch is off by default, so unconditionally clearing it is safe here.
imatch() {
  local text="$1" pat="$2" rc=0
  shopt -s nocasematch
  [[ "$text" =~ $pat ]] || rc=1
  shopt -u nocasematch
  return $rc
}

# Kubernetes quantity -> bytes. Node status mixes units freely: on the same
# node, capacity.ephemeral-storage came back as "209124332Ki" while
# allocatable.ephemeral-storage was plain bytes. Assuming either one produces
# an answer off by a factor of 1024.
k8s_bytes() {
  local q="${1:-0}"
  case "$q" in
    *Ki) printf '%s' $(( ${q%Ki} * 1024 )) ;;
    *Mi) printf '%s' $(( ${q%Mi} * 1048576 )) ;;
    *Gi) printf '%s' $(( ${q%Gi} * 1073741824 )) ;;
    *Ti) printf '%s' $(( ${q%Ti} * 1099511627776 )) ;;
    *[!0-9]*) printf '0' ;;
    *)   printf '%s' "$q" ;;
  esac
}

# Does this image exist in a registry? Answers without pulling it.
#
# NOT `podman manifest inspect`. That command only understands manifest LISTS
# and fails outright on a single-architecture image:
#
#   Treating single images as manifest lists is not implemented
#
# The ModelCar images are single-arch OCI manifests, so podman reports every one
# of them as absent whether it is there or not. skopeo handles both but is not
# installed on the CRIAB jump box. `oc image info` handles both and oc is
# already a hard requirement everywhere, so it is the reliable default.
registry_inspect() {
  local ref="$1" auth="${2:-}"
  if command -v skopeo >/dev/null 2>&1; then
    if [[ -n "$auth" ]]; then
      skopeo inspect --no-tags --authfile "$auth" "docker://${ref}" 2>/dev/null && return 0
    else
      skopeo inspect --no-tags "docker://${ref}" 2>/dev/null && return 0
    fi
  fi
  local -a args=(image info -o json)
  [[ -n "$auth" ]] && args+=(--registry-config "$auth")

  # Two failure modes to absorb, and they are opposites:
  #
  #   single-arch image  podman manifest inspect refuses it outright
  #   multi-arch image   `oc image info` refuses it without --filter-by-os:
  #                        error: the image is a manifest list and contains
  #                        multiple images - use --filter-by-os to select
  #
  # Both produce a non-zero exit that reads as "not in the registry". The RHOAI
  # llm-d component images are manifest lists and the ModelCars are not, so any
  # single-strategy check is wrong for half of them.
  oc "${args[@]}" "$ref" 2>/dev/null && return 0
  oc "${args[@]}" --filter-by-os "${IMAGE_OS_FILTER:-linux/amd64}" "$ref" 2>/dev/null && return 0

  # Self-signed mirror CA this host does not trust: retry without TLS
  # verification rather than reporting a present image as missing.
  oc "${args[@]}" --insecure "$ref" 2>/dev/null && return 0
  oc "${args[@]}" --insecure --filter-by-os "${IMAGE_OS_FILTER:-linux/amd64}" "$ref" 2>/dev/null
}

inspect_remote() { registry_inspect "$1"; }

# Resolve a tag to its digest.
resolve_digest() {
  local ref="$1"
  if command -v skopeo >/dev/null 2>&1; then
    skopeo inspect --no-tags "docker://${ref}" 2>/dev/null | jq -r '.Digest // empty'
    return
  fi
  oc image info -o json "$ref" 2>/dev/null | jq -r '.digest // .listDigest // empty'
}

require_cmd() {
  local m=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || m+=("$c"); done
  (( ${#m[@]} == 0 )) || die "missing command(s): ${m[*]}"
}

require_vars() {
  local m=()
  for v in "$@"; do [[ -n "${!v:-}" ]] || m+=("$v"); done
  (( ${#m[@]} == 0 )) || die "unset config value(s): ${m[*]} — check config/llmd.env and ${CRIAB_ENV:-criab.env}"
}

# Load config/llmd.env, then CRIAB's config/criab.env for the registry and host
# values. CRIAB's file wins for nothing — every var in both uses the
# ${VAR:-default} form, so whichever is read first sticks. llmd.env is read
# first on purpose: it may legitimately override e.g. WAIT_TIMEOUT.
load_env() {
  local f="${REPO_ROOT}/config/llmd.env"
  if [[ -f "$f" ]]; then
    # shellcheck disable=SC1090
    set -a; source "$f"; set +a
  else
    warn "no config/llmd.env — using defaults from config/llmd.env.example"
    # shellcheck disable=SC1090
    set -a; source "${REPO_ROOT}/config/llmd.env.example"; set +a
  fi

  # The CRIAB checkout lives at ~/criab on the lab hosts and usually under
  # ~/projects on a laptop. Probe rather than make everyone edit the same line
  # twice — this repo gets rsync'd to both, from one config file.
  if [[ ! -f "${CRIAB_ENV:-/nonexistent}" ]]; then
    for c in "${CRIAB_DIR:-}" "${HOME}/criab" "${HOME}/projects/criab" \
             "$(dirname "$REPO_ROOT")/criab"; do
      [[ -n "$c" && -f "${c}/config/criab.env" ]] || continue
      CRIAB_DIR="$c"; CRIAB_ENV="${c}/config/criab.env"
      export CRIAB_DIR CRIAB_ENV
      break
    done
  fi

  if [[ -f "${CRIAB_ENV:-/nonexistent}" ]]; then
    # shellcheck disable=SC1090
    set -a; source "$CRIAB_ENV"; set +a
  else
    warn "no CRIAB env at ${CRIAB_ENV} — MIRROR_REGISTRY and host values will be unset"
    warn "  set CRIAB_DIR in config/llmd.env to your CRIAB checkout"
  fi
}

# Poll until `fn` succeeds or the timeout expires. Prints a dot per attempt so a
# long wait does not look hung — the cheatsheet's rule is to prove progress, and
# for a wait the honest proof is "still polling".
wait_for() {
  local what="$1" timeout="$2"; shift 2
  local deadline=$(( SECONDS + timeout ))
  step "Waiting for ${what} (timeout ${timeout}s)"
  if [[ "${DRY_RUN:-false}" == "true" ]]; then dim "would wait for ${what}"; return 0; fi
  while (( SECONDS < deadline )); do
    if "$@"; then echo; ok "${what}"; return 0; fi
    printf '.'; sleep 10
  done
  echo
  die "timed out after ${timeout}s waiting for ${what}"
}

require_cluster_admin() {
  require_cmd oc
  oc whoami >/dev/null 2>&1 \
    || die "not logged in — run: source ~/criab/scripts/ocp/oc-login.sh  (source it, do not execute it)"
  oc auth can-i '*' '*' --all-namespaces >/dev/null 2>&1 \
    || die "need cluster-admin (current user: $(oc whoami))"
}

# Load the cluster's own mirror rules as "source<TAB>mirror" lines.
#
# Do NOT guess the mirrored path. oc-mirror pushes under a NAMESPACE, so the
# real mapping on this cluster is
#   registry.redhat.io/rhoai  ->  <registry>:8443/maas/rhoai
# and a naive "strip the host, keep the rest" transformation misses the
# namespace entirely and reports every image as missing. The IDMS/ITMS on the
# cluster is the authoritative mapping — it is literally what CRI-O uses.
load_mirror_rules() {
  require_cmd oc jq
  MIRROR_RULES="$(
    oc get imagedigestmirrorset -o json 2>/dev/null \
      | jq -r '.items[]?.spec.imageDigestMirrors[]? | .source as $s | .mirrors[]? | "\($s)\t\(.)"' 2>/dev/null || true
    oc get imagetagmirrorset -o json 2>/dev/null \
      | jq -r '.items[]?.spec.imageTagMirrors[]? | .source as $s | .mirrors[]? | "\($s)\t\(.)"' 2>/dev/null || true
    oc get imagecontentsourcepolicy -o json 2>/dev/null \
      | jq -r '.items[]?.spec.repositoryDigestMirrors[]? | .source as $s | .mirrors[]? | "\($s)\t\(.)"' 2>/dev/null || true
  )"
  export MIRROR_RULES
}

# Split a reference into repository and @digest / :tag suffix. The registry host
# may carry a :port, so a naive "cut at the last colon" is wrong — only a colon
# AFTER the final slash is a tag separator.
_split_ref() {
  local ref="$1"
  if [[ "$ref" == *@* ]]; then
    printf '%s\t%s' "${ref%@*}" "@${ref#*@}"
    return
  fi
  local last="${ref##*/}"
  if [[ "$last" == *:* ]]; then
    printf '%s\t%s' "${ref%:*}" ":${ref##*:}"
  else
    printf '%s\t' "$ref"
  fi
}

# Every mirrored reference the cluster would try for this image, most specific
# rule first. Empty output means NO rule covers it — which is itself a finding:
# pulls of the original reference are never redirected, so the image being
# present in the registry would not help.
mirror_candidates() {
  local ref="$1" repo suffix best=0 src mir
  IFS=$'\t' read -r repo suffix <<< "$(_split_ref "$ref")"

  while IFS=$'\t' read -r src mir; do
    [[ -n "${src:-}" ]] || continue
    [[ "$repo" == "$src" || "$repo" == "$src"/* ]] || continue
    (( ${#src} > best )) && best=${#src}
  done <<< "${MIRROR_RULES:-}"

  (( best > 0 )) || return 0

  while IFS=$'\t' read -r src mir; do
    [[ -n "${src:-}" ]] || continue
    [[ "$repo" == "$src" || "$repo" == "$src"/* ]] || continue
    (( ${#src} == best )) || continue
    printf '%s%s%s\n' "$mir" "${repo#"$src"}" "$suffix"
  done <<< "${MIRROR_RULES:-}"
}

# 0 = present in the mirror, 1 = a rule exists but the image is not there,
# 2 = no mirror rule covers this reference at all.
#
# The mirror registry rejects /v2/_catalog, so presence is tested per-image with
# `podman manifest inspect`. An empty catalog listing is not evidence of
# anything — see the CRIAB cheatsheet.
mirror_has_image() {
  local ref="$1" cand found=1 any=0
  while read -r cand; do
    [[ -n "$cand" ]] || continue
    any=1
    if registry_inspect "$cand" "${PODMAN_AUTHFILE:-${HOME}/.llmd-auth.json}" >/dev/null 2>&1; then
      found=0
      MIRROR_LAST_REF="$cand"
      break
    fi
    MIRROR_LAST_REF="$cand"
  done < <(mirror_candidates "$ref")

  (( any )) || { MIRROR_LAST_REF=""; return 2; }
  return $found
}

# Log into the mirror registry into a throwaway authfile, so we never touch the
# host's shared container auth and never leave credentials behind in a place
# another project would inherit.
mirror_login() {
  require_cmd podman
  require_vars MIRROR_REGISTRY MIRROR_REGISTRY_USER MIRROR_REGISTRY_PASSWORD
  export PODMAN_AUTHFILE="${HOME}/.llmd-auth.json"
  podman login --authfile "$PODMAN_AUTHFILE" \
    -u "$MIRROR_REGISTRY_USER" -p "$MIRROR_REGISTRY_PASSWORD" \
    "$MIRROR_REGISTRY" >/dev/null 2>&1 \
    || die "cannot log in to ${MIRROR_REGISTRY} — check MIRROR_REGISTRY_USER/PASSWORD in ${CRIAB_ENV}"
  chmod 600 "$PODMAN_AUTHFILE"
}

# The overlay directory for the configured model, with a clear error rather
# than a kustomize stack trace when the name is wrong.
model_overlay() {
  local d="${REPO_ROOT}/manifests/${LLMD_MODEL}"
  [[ -d "$d" ]] || die "no manifest overlay for LLMD_MODEL='${LLMD_MODEL}' (expected ${d})
available: $(cd "${REPO_ROOT}/manifests" && ls -d */ | grep -vE '^(base|gateway)/' | tr -d '/' | tr '\n' ' ')"
  printf '%s' "$d"
}

# ModelCar image for the configured model.
model_image() {
  case "$LLMD_MODEL" in
    qwen2.5-0.5b) printf '%s' "$MODELCAR_QWEN25_05B" ;;
    qwen3-4b)     printf '%s' "$MODELCAR_QWEN3_4B" ;;
    *)            die "no ModelCar image mapped for LLMD_MODEL='${LLMD_MODEL}'" ;;
  esac
}

# The LLMInferenceService name each overlay creates.
model_isvc_name() {
  case "$LLMD_MODEL" in
    qwen2.5-0.5b) printf '%s' "qwen25-05b" ;;
    qwen3-4b)     printf '%s' "qwen3-4b" ;;
    *)            die "no LLMInferenceService name mapped for LLMD_MODEL='${LLMD_MODEL}'" ;;
  esac
}
