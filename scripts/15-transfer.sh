#!/usr/bin/env bash
# Phase 15 — LOW SIDE. Carry the archive across to the high side.
#
#   scripts/15-transfer.sh
#
# NEVER use rsync --append here, and this script goes out of its way not to.
#
# --append is the obvious choice for a big resumable transfer, and the MaaS
# guide recommends it. It is only safe when resuming an INTERRUPTED copy of an
# UNCHANGED file. Every incremental oc-mirror run rebuilds mirror_000001.tar
# from scratch, so --append keeps whatever prefix is already on the far side and
# bolts the new tail onto it. The result is byte-for-byte the right SIZE and the
# wrong CONTENT.
#
# That failure is genuinely nasty: the transfer reports success, and the error
# surfaces two steps later as oc-mirror failing to read manifests out of its own
# local cache. It cost an hour to find. This script verifies a prefix hash on
# both sides afterwards so it can never happen silently again.
#
# The low -> high hop uses the JUMP BOX's own SSH identity, not yours.
# LAB_SSH_KEY is a path on your laptop and usually does not exist here; passing
# -i with a missing file makes ssh fall back to password auth and hang.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env

require_cmd rsync ssh sha256sum
require_vars LLMD_WORKDIR HIGH_SIDE_HOST

HIGH_SIDE_USER="${HIGH_SIDE_USER:-lab-user}"
DEST="${HIGH_SIDE_USER}@${HIGH_SIDE_HOST}:${LLMD_WORKDIR}/"

SSH_OPTS=(-o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=15)
[[ -n "${LOW_TO_HIGH_SSH_KEY:-}" ]] && SSH_OPTS+=(-i "$LOW_TO_HIGH_SSH_KEY")

step "Phase 15 — transferring to ${HIGH_SIDE_HOST}"

src_tar="$(ls -t "${LLMD_WORKDIR}"/*.tar 2>/dev/null | head -1 || true)"
[[ -n "$src_tar" ]] || die "no archive in ${LLMD_WORKDIR} — run phase 10 first"
name="$(basename "$src_tar")"
size="$(stat -c %s "$src_tar")"
ok "source: ${name} ($(numfmt --to=iec "$size" 2>/dev/null || echo "$size bytes"))"

ssh "${SSH_OPTS[@]}" "${HIGH_SIDE_USER}@${HIGH_SIDE_HOST}" true 2>/dev/null \
  || die "cannot ssh from here to ${HIGH_SIDE_HOST}.

     This hop uses the JUMP BOX's own key, not yours. Check that this host can
     reach the high side without a password:
       ssh ${HIGH_SIDE_USER}@${HIGH_SIDE_HOST} hostname
     If it needs a specific key, set LOW_TO_HIGH_SSH_KEY in config/llmd.env."

# If a stale archive of a DIFFERENT size is already there, remove it. rsync
# would otherwise do a delta transfer against content it cannot trust.
remote_size="$(ssh "${SSH_OPTS[@]}" "${HIGH_SIDE_USER}@${HIGH_SIDE_HOST}" \
  "stat -c %s '${LLMD_WORKDIR}/${name}' 2>/dev/null || echo 0")"
if [[ "$remote_size" != "0" && "$remote_size" != "$size" ]]; then
  warn "a different-sized ${name} is already on the high side — removing it"
  run ssh "${SSH_OPTS[@]}" "${HIGH_SIDE_USER}@${HIGH_SIDE_HOST}" "rm -f '${LLMD_WORKDIR}/${name}'"
fi

run ssh "${SSH_OPTS[@]}" "${HIGH_SIDE_USER}@${HIGH_SIDE_HOST}" "mkdir -p '${LLMD_WORKDIR}'"

step "rsync (--partial for resume; NOT --append, see the header)"
if [[ "${DRY_RUN:-false}" == "true" ]]; then
  dim "would rsync ${LLMD_WORKDIR}/ -> ${DEST}"
  exit 0
fi

rsync -a --partial --info=progress2 -e "ssh ${SSH_OPTS[*]}" \
  "${LLMD_WORKDIR}/" "$DEST" || die "rsync failed"

# --- verify -----------------------------------------------------------------
# Size alone proves nothing; that is exactly what --append gets wrong. Hash a
# prefix on both sides. 200 MB is enough to catch a stale prefix and takes a
# couple of seconds on either host.
step "Verifying the copy (prefix hash, not just size)"

local_h="$(head -c 200000000 "$src_tar" | sha256sum | cut -d' ' -f1)"
remote_h="$(ssh "${SSH_OPTS[@]}" "${HIGH_SIDE_USER}@${HIGH_SIDE_HOST}" \
  "head -c 200000000 '${LLMD_WORKDIR}/${name}' | sha256sum | cut -d' ' -f1")"
remote_size="$(ssh "${SSH_OPTS[@]}" "${HIGH_SIDE_USER}@${HIGH_SIDE_HOST}" \
  "stat -c %s '${LLMD_WORKDIR}/${name}'")"

[[ "$remote_size" == "$size" ]] \
  || die "size mismatch: local ${size}, remote ${remote_size}"
[[ "$local_h" == "$remote_h" ]] \
  || die "PREFIX HASH MISMATCH — the remote archive is corrupt.
     local  ${local_h}
     remote ${remote_h}
     Delete it on the high side and re-run this phase:
       rm -f ${LLMD_WORKDIR}/${name}"

ok "verified: size and prefix hash match"
echo
ok "phase 15 complete — next, on the HIGH side: ./deploy-llmd.sh 18"
