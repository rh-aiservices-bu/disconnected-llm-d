#!/usr/bin/env bash
# Phase 14 — get the NVIDIA driver to build on a disconnected cluster.
#
#   scripts/14-gpu-driver-disconnected.sh diagnose      # HIGH — start here
#   scripts/14-gpu-driver-disconnected.sh fetch-cuda    # LOW  — download CUDA RPMs
#   scripts/14-gpu-driver-disconnected.sh build-repo    # HIGH — kernel RPMs + repo image
#   scripts/14-gpu-driver-disconnected.sh deploy-repo   # HIGH — serve it in-cluster
#   scripts/14-gpu-driver-disconnected.sh patch         # HIGH — point the driver at it
#   scripts/14-gpu-driver-disconnected.sh verify        # HIGH — GPU capacity appears
#
# THE PROBLEM
#
# The NVIDIA GPU operator compiles its kernel module on the node at runtime. To
# do that it needs kernel-devel/kernel-headers matching the running kernel, and
# CUDA development packages. Connected, it downloads both. Disconnected, both
# fetches fail and the node never reports nvidia.com/gpu capacity — which looks
# identical to "the hardware is missing".
#
# There are two halves and they fail independently, which is why `diagnose`
# exists and why you should run it before doing any of the work below:
#
#   kernel packages   OpenShift solves this itself. The Driver Toolkit (DTK)
#                     image ships in the OCP release payload, is therefore
#                     already mirrored, and contains the matching kernel
#                     sources. The GPU operator uses it when the ClusterPolicy
#                     has operator.use_ocp_driver_toolkit: true. Very often
#                     this half is already fine.
#
#   CUDA packages     Genuinely external. The driver container fetches these
#                     from developer.download.nvidia.com, which does not exist
#                     from here. This is usually the half that is broken.
#
# So the common case needs only the CUDA half, and `diagnose` will say so.
# Doing the kernel half when you did not need it costs an hour and changes
# nothing.
#
# WHY AN IN-CLUSTER REPO RATHER THAN A BASTION HTTP SERVER
#
# The obvious fix is `python3 -m http.server` on the high side. It works, and it
# breaks the next time anything restarts: the driver pod runs dnf install on
# every start — node reboots, MachineSet scale-ups, operator upgrades — and a
# background python process on a jump host is not there for any of them.
# Building the repo into an image, pushing it to Quay and running it as a
# Deployment makes it survive all of that, and makes it reproducible from the
# mirror after an environment rebuild. Pass --bastion to use the throwaway
# version anyway when you just need the GPU working in the next ten minutes.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env

CMD="${1:-diagnose}"; shift 2>/dev/null || true
BASTION=false
[[ "${1:-}" == "--bastion" ]] && BASTION=true

GPU_NS="${GPU_NS:-nvidia-gpu-operator}"
NFD_NS="${NFD_NS:-openshift-nfd}"
REPO_WORK="${REPO_WORK:-${LLMD_LOG_DIR}/gpu-kernel-repo}"
REPO_IMAGE_PATH="${REPO_IMAGE_PATH:-llmd/gpu-kernel-repo}"

# ===========================================================================
cmd_diagnose() {
  require_cmd oc jq
  require_cluster_admin

  step "Diagnosing the GPU stack"
  local problems=()

  # --- is there even a GPU node -------------------------------------------
  local gpu_nodes
  gpu_nodes="$(oc get nodes -l feature.node.kubernetes.io/pci-10de.present=true -o name 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$gpu_nodes" == "0" ]]; then
    # NFD may simply not have labelled it yet; check for the instance type too.
    local g6
    g6="$(oc get nodes -o json | jq -r '[.items[] | select(.metadata.labels["node.kubernetes.io/instance-type"] // "" | test("^(g[0-9]|p[0-9])"))] | length')"
    if [[ "$g6" == "0" ]]; then
      problems+=("no GPU instances in the cluster — run scripts/12-gpu-machineset.sh")
      printf '%s fail%s no node with an NVIDIA PCI device or a GPU instance type\n' "$C_RED" "$C_RST"
    else
      problems+=("GPU instance exists but NFD has not labelled it — check NFD below")
      printf '%swarn%s %s GPU instance(s) present but not labelled by NFD\n' "$C_YEL" "$C_RST" "$g6"
    fi
  else
    ok "${gpu_nodes} node(s) labelled with an NVIDIA PCI device"
  fi

  # --- NFD health ----------------------------------------------------------
  # A failed NFD upgrade leaves nfd-master not Ready on a missing CRD, and then
  # nothing gets labelled — which presents as a GPU problem, not an NFD one.
  if oc get ns "$NFD_NS" >/dev/null 2>&1; then
    local nfd_bad
    nfd_bad="$(oc get pods -n "$NFD_NS" --no-headers 2>/dev/null | grep -vcE 'Running|Completed' || true)"
    if [[ "${nfd_bad:-0}" -gt 0 ]]; then
      problems+=("NFD pods are not healthy in ${NFD_NS}")
      printf '%s fail%s NFD pods unhealthy:\n' "$C_RED" "$C_RST"
      oc get pods -n "$NFD_NS" --no-headers | grep -vE 'Running|Completed' | sed 's/^/      /'
      oc get crd nodefeaturegroups.nfd.openshift.io >/dev/null 2>&1 \
        || printf '      missing CRD nodefeaturegroups.nfd.openshift.io — a partial NFD upgrade\n'
    else
      ok "NFD pods healthy"
    fi
  else
    problems+=("namespace ${NFD_NS} not found — is NFD installed?")
    printf '%s fail%s no %s namespace\n' "$C_RED" "$C_RST" "$NFD_NS"
  fi

  # --- ClusterPolicy -------------------------------------------------------
  local cp dtk repocm
  cp="$(oc get clusterpolicy -o name 2>/dev/null | head -1)"
  if [[ -z "$cp" ]]; then
    problems+=("no ClusterPolicy — the NVIDIA GPU operator is not configured")
    printf '%s fail%s no ClusterPolicy found\n' "$C_RED" "$C_RST"
  else
    dtk="$(oc get "$cp" -o jsonpath='{.spec.operator.use_ocp_driver_toolkit}' 2>/dev/null)"
    repocm="$(oc get "$cp" -o jsonpath='{.spec.driver.repoConfig.configMapName}' 2>/dev/null)"
    if [[ "$dtk" == "true" ]]; then
      ok "use_ocp_driver_toolkit: true — kernel sources come from the mirrored DTK"
    else
      problems+=("use_ocp_driver_toolkit is '${dtk:-unset}' — set it true before building kernel RPMs by hand")
      printf '%swarn%s use_ocp_driver_toolkit is %s\n' "$C_YEL" "$C_RST" "${dtk:-unset}"
    fi
    [[ -n "$repocm" ]] && ok "driver.repoConfig.configMapName: ${repocm}" \
                       || log "  driver.repoConfig.configMapName is empty (no local repo configured yet)"
  fi

  # --- the DTK image itself ------------------------------------------------
  local dtk_img
  dtk_img="$(oc adm release info --image-for=driver-toolkit 2>/dev/null || true)"
  if [[ -n "$dtk_img" ]]; then
    ok "driver-toolkit image: ${dtk_img}"
  else
    problems+=("could not resolve the driver-toolkit image from the release payload")
    printf '%swarn%s could not read the driver-toolkit image (oc adm release info failed)\n' "$C_YEL" "$C_RST"
  fi

  # --- driver pods ---------------------------------------------------------
  step "NVIDIA driver DaemonSet"
  if ! oc get ns "$GPU_NS" >/dev/null 2>&1; then
    problems+=("namespace ${GPU_NS} not found — the GPU operator is not installed")
    printf '%s fail%s no %s namespace\n' "$C_RED" "$C_RST" "$GPU_NS"
  else
    oc get pods -n "$GPU_NS" -o wide 2>/dev/null | head -25

    local dpod
    dpod="$(oc get pods -n "$GPU_NS" -l app=nvidia-driver-daemonset -o name 2>/dev/null | head -1)"
    if [[ -z "$dpod" ]]; then
      dpod="$(oc get pods -n "$GPU_NS" -o name 2>/dev/null | grep nvidia-driver | head -1)"
    fi

    if [[ -z "$dpod" ]]; then
      problems+=("no nvidia-driver pod — nothing is trying to build the driver")
      printf '\n%swarn%s no nvidia-driver pod found\n' "$C_YEL" "$C_RST"
    else
      step "Last 60 lines from ${dpod}"
      local logs
      logs="$(oc logs -n "$GPU_NS" "$dpod" --all-containers --tail=200 2>/dev/null || true)"
      printf '%s\n' "$logs" | tail -60 | sed 's/^/    /'

      echo
      step "Signature match"
      # Classify rather than make the reader grep. These strings are the ones
      # that actually distinguish the two halves of the problem.
      # imatch, not `| grep -q`: the logs are 200 lines, so an early match makes
      # grep exit, SIGPIPEs the writer, and under pipefail the successful match
      # reads as no match. See lib/common.sh.
      if imatch "$logs" 'developer\.download\.nvidia\.com|Could not resolve host.*nvidia|cuda.*repo.*(fail|error)'; then
        problems+=("CUDA packages unreachable — run fetch-cuda / build-repo / deploy-repo / patch")
        printf '%s >>%s CUDA package fetch is failing. This is the common disconnected case.\n' "$C_RED" "$C_RST"
        printf '      Fix: fetch-cuda (low) -> build-repo -> deploy-repo -> patch\n'
      fi
      if imatch "$logs" 'Unable to find a match: kernel|No match for argument: kernel-(devel|headers)|kernel-devel.*not (found|available)'; then
        problems+=("kernel packages unreachable — DTK is not supplying them")
        printf '%s >>%s Kernel sources are missing. Check use_ocp_driver_toolkit is true and\n' "$C_RED" "$C_RST"
        printf '      that the openshift-driver-toolkit-ctr container is running in this pod.\n'
      fi
      if imatch "$logs" 'x509|certificate signed by unknown authority'; then
        problems+=("TLS trust failure reaching the repo — mirror CA not trusted by the driver pod")
        printf '%s >>%s TLS trust failure. The mirror CA must be in the cluster trust bundle.\n' "$C_RED" "$C_RST"
      fi
      # Previously written as a negative lookahead, which ERE does not support —
      # it silently never matched. Match any resolve failure, then exclude the
      # nvidia one already reported above.
      if imatch "$logs" 'Could not resolve host' && ! imatch "$logs" 'Could not resolve host: [^ ]*nvidia'; then
        printf '%swarn%s a DNS failure to a non-NVIDIA host appears in the log\n' "$C_YEL" "$C_RST"
      fi

      # The DTK sidecar is what supplies kernel sources; if it is absent or
      # crashing, the kernel half cannot work no matter what the policy says.
      local dtk_state
      dtk_state="$(oc get -n "$GPU_NS" "$dpod" -o json 2>/dev/null \
        | jq -r '.status.containerStatuses[]? | select(.name=="openshift-driver-toolkit-ctr")
                 | (.state | keys[0]) + " " + ((.state[].reason) // "")' || true)"
      [[ -n "$dtk_state" ]] && log "  openshift-driver-toolkit-ctr: ${dtk_state}" \
                            || printf '%swarn%s no openshift-driver-toolkit-ctr container in the driver pod\n' "$C_YEL" "$C_RST"
    fi
  fi

  # --- the actual outcome --------------------------------------------------
  step "GPU capacity"
  oc get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.capacity.nvidia\\.com/gpu 2>/dev/null

  local total
  total="$(oc get nodes -o json | jq '[.items[].status.capacity["nvidia.com/gpu"] // "0" | tonumber] | add')"

  echo
  if (( total > 0 )); then
    ok "${total} GPU(s) allocatable — the driver is working, nothing to fix here"
    return 0
  fi

  step "${#problems[@]} problem(s)"
  printf '  - %s\n' "${problems[@]:-none identified — read the driver log above}"
  cat <<EOF

  Kernel version on the GPU node, needed by build-repo:

    oc get nodes -l feature.node.kubernetes.io/pci-10de.present=true \\
      -o jsonpath='{.items[0].status.nodeInfo.kernelVersion}{"\\n"}'

EOF
  return 1
}

# ===========================================================================
# LOW SIDE. CUDA development packages, which live nowhere in the OCP payload.
cmd_fetch_cuda() {
  require_cmd dnf

  local ver="${CUDA_VERSION:-12-6}"
  local out="${CUDA_RPM_DIR:-${LLMD_LOG_DIR}/cuda-rpms}"

  step "Downloading CUDA ${ver} development packages"
  cat <<EOF

  The version must match what the driver container expects. Read it off the
  running (or crash-looping) driver pod on the HIGH side:

    oc get clusterpolicy -o jsonpath='{.items[0].spec.driver.version}{"\\n"}'
    oc logs -n ${GPU_NS} -l app=nvidia-driver-daemonset --tail=200 | grep -i cuda

  Then re-run with CUDA_VERSION=<major-minor>, e.g. CUDA_VERSION=12-8.
  Currently: ${ver}

EOF

  run mkdir -p "$out"

  repos="$(dnf repolist 2>/dev/null || true)"
  if ! imatch "$repos" 'cuda'; then
    step "Adding the NVIDIA CUDA repository"
    run sudo dnf config-manager --add-repo \
      "https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/cuda-rhel9.repo"
  fi

  run dnf download --resolve --destdir "$out" \
    "cuda-devel-${ver}" "cuda-nvcc-${ver}" "cuda-cudart-devel-${ver}"

  if [[ "${DRY_RUN:-false}" != "true" ]]; then
    local n; n="$(find "$out" -name '*.rpm' | wc -l | tr -d ' ')"
    [[ "$n" -gt 0 ]] || die "no RPMs downloaded into ${out}"
    ok "${n} RPM(s) in ${out}"
    run tar -czf "${out}.tar.gz" -C "$(dirname "$out")" "$(basename "$out")"
    ok "packed: ${out}.tar.gz"
  fi

  cat <<EOF

  Transfer to the high side, then continue there:

    rsync -avP ${out}.tar.gz lab-user@\${HIGH_IP}:${LLMD_LOG_DIR}/
    # on the high side:
    tar -xzf ${LLMD_LOG_DIR}/$(basename "$out").tar.gz -C ${LLMD_LOG_DIR}/
    scripts/14-gpu-driver-disconnected.sh build-repo

EOF
}

# ===========================================================================
# HIGH SIDE. Kernel sources out of the mirrored DTK, plus the CUDA RPMs, into
# one yum repo — and then into an image so it outlives this shell.
cmd_build_repo() {
  require_cmd oc podman
  require_cluster_admin

  local kver
  kver="${KERNEL_VERSION:-$(oc get nodes -l feature.node.kubernetes.io/pci-10de.present=true \
        -o jsonpath='{.items[0].status.nodeInfo.kernelVersion}' 2>/dev/null)}"
  [[ -n "$kver" ]] || die "could not read the GPU node kernel version.
     Either no GPU node is labelled yet, or pass it: KERNEL_VERSION=5.14.0-... $0 build-repo"
  ok "target kernel: ${kver}"

  local dtk_img
  dtk_img="$(oc adm release info --image-for=driver-toolkit 2>/dev/null)"
  [[ -n "$dtk_img" ]] || die "could not resolve the driver-toolkit image from the release payload"
  ok "DTK image: ${dtk_img}"

  local cuda_dir="${CUDA_RPM_DIR:-${LLMD_LOG_DIR}/cuda-rpms}"
  [[ -d "$cuda_dir" ]] || die "no CUDA RPMs at ${cuda_dir} — run fetch-cuda on the low side and transfer them"

  run mkdir -p "${REPO_WORK}/rpms"

  # --- pull the DTK and take the kernel packages out of it -----------------
  # DTK carries kernel-devel and kernel-headers as INSTALLED rpms for exactly
  # this kernel. Extracting the installed rpm files is more reliable than
  # rebuilding them from /usr/src, which is what makes the spec-file route in
  # other guides so fiddly.
  step "Extracting kernel packages from the Driver Toolkit"

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    dim "would pull ${dtk_img} and extract kernel rpms for ${kver}"
  else
    podman pull --authfile "${PODMAN_AUTHFILE:-${HOME}/.llmd-auth.json}" "$dtk_img" 2>/dev/null \
      || podman pull "$dtk_img" \
      || die "could not pull the DTK image — it should be in the mirror; check IDMS and registry auth"

    # yumdownloader inside the DTK reconstructs the rpms from the local cache
    # when they are present; otherwise fall back to packing the source tree.
    podman run --rm -v "${REPO_WORK}/rpms:/out:z" --entrypoint /bin/bash "$dtk_img" -c "
      set -e
      if command -v yumdownloader >/dev/null 2>&1; then
        yumdownloader --destdir=/out kernel-devel-${kver} kernel-headers 2>/dev/null || true
      fi
      # Whatever we could not download, package straight from the filesystem so
      # the repo still satisfies the driver build.
      if ! ls /out/kernel-devel-*.rpm >/dev/null 2>&1; then
        echo 'packaging kernel sources directly from the DTK filesystem'
        tar -czf /out/kernel-src-${kver}.tar.gz -C /usr/src/kernels ${kver} 2>/dev/null || true
      fi
      ls -la /out
    " || warn "DTK extraction returned non-zero — inspect ${REPO_WORK}/rpms before continuing"
  fi

  # --- fold in the CUDA rpms ----------------------------------------------
  step "Adding CUDA packages"
  run bash -c "cp -f '${cuda_dir}'/*.rpm '${REPO_WORK}/rpms/' 2>/dev/null || true"
  if [[ "${DRY_RUN:-false}" != "true" ]]; then
    local n; n="$(find "${REPO_WORK}/rpms" -name '*.rpm' | wc -l | tr -d ' ')"
    ok "${n} RPM(s) staged in ${REPO_WORK}/rpms"
    (( n > 0 )) || die "no RPMs staged — nothing to serve"
  fi

  # --- repo metadata -------------------------------------------------------
  step "Generating repo metadata"
  if command -v createrepo_c >/dev/null 2>&1; then
    run createrepo_c "${REPO_WORK}/rpms"
  else
    warn "createrepo_c not installed locally — generating inside a container"
    run podman run --rm -v "${REPO_WORK}/rpms:/rpms:z" --entrypoint /bin/bash "$dtk_img" \
      -c "dnf install -y createrepo_c >/dev/null 2>&1 && createrepo_c /rpms"
  fi

  if [[ "$BASTION" == "true" ]]; then
    cat <<EOF

  --bastion: serve it from this host instead of building an image.

    cd ${REPO_WORK}/rpms && nohup python3 -m http.server 8088 > ${LLMD_LOG_DIR}/kernel-repo.log 2>&1 &

  Then patch with the bastion URL:

    KERNEL_REPO_URL=http://\$(hostname -I | awk '{print \$1}'):8088/ \\
      scripts/14-gpu-driver-disconnected.sh patch

  This dies with the shell, the host, or the next reboot, and the driver pod
  reinstalls from it on every restart. Do the image route before you rely on it.

EOF
    return 0
  fi

  # --- bake it into an image and push --------------------------------------
  step "Building the repo image"
  require_vars MIRROR_REGISTRY
  mirror_login

  local base="${KERNEL_REPO_BASE_IMAGE:-registry.access.redhat.com/ubi9/httpd-24:latest}"
  local target="${MIRROR_REGISTRY}/${REPO_IMAGE_PATH}:${kver}"

  cat > "${REPO_WORK}/Containerfile" <<EOF
# Serves the kernel + CUDA yum repo to the NVIDIA driver pods.
#
# Base image must be MIRRORED. It is listed in config/additional-images.txt for
# exactly this reason — an httpd image that is not in Quay makes this pod
# ImagePullBackOff, and then the driver failure looks unchanged.
FROM ${base}
COPY rpms/ /var/www/html/
EXPOSE 8080
EOF

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    dim "would build and push ${target}"
  else
    podman build -t "$target" "${REPO_WORK}" \
      || die "build failed — is ${base} in the mirror? See config/additional-images.txt"
    podman push --authfile "$PODMAN_AUTHFILE" "$target" \
      || die "push to ${MIRROR_REGISTRY} failed"
    ok "pushed ${target}"
  fi

  printf '%s\n' "$target" > "${REPO_WORK}/image-ref"
  cat <<EOF

  Next:

    scripts/14-gpu-driver-disconnected.sh deploy-repo
    scripts/14-gpu-driver-disconnected.sh patch

EOF
}

# ===========================================================================
cmd_deploy_repo() {
  require_cmd oc envsubst
  require_cluster_admin

  local img
  img="${KERNEL_REPO_IMAGE:-$(cat "${REPO_WORK}/image-ref" 2>/dev/null || true)}"
  [[ -n "$img" ]] || die "no repo image reference — run build-repo first, or set KERNEL_REPO_IMAGE"

  step "Deploying the kernel repo into ${GPU_NS}"
  KERNEL_REPO_IMAGE="$img" GPU_NS="$GPU_NS" \
    envsubst < "${REPO_ROOT}/manifests/gpu/kernel-repo.yaml" \
    | { [[ "${DRY_RUN:-false}" == "true" ]] && { sed 's/^/  /'; dim "would apply the above"; } || oc apply -f -; }

  [[ "${DRY_RUN:-false}" == "true" ]] && return 0

  oc rollout status deploy/gpu-kernel-repo -n "$GPU_NS" --timeout=300s \
    || die "the repo pod did not become ready — check: oc get pods -n ${GPU_NS} -l app=gpu-kernel-repo"
  ok "repo serving at http://gpu-kernel-repo.${GPU_NS}.svc:8080/"
}

# ===========================================================================
cmd_patch() {
  require_cmd oc
  require_cluster_admin

  local url="${KERNEL_REPO_URL:-http://gpu-kernel-repo.${GPU_NS}.svc:8080/}"
  step "Pointing the NVIDIA driver at ${url}"

  local cp; cp="$(oc get clusterpolicy -o name 2>/dev/null | head -1)"
  [[ -n "$cp" ]] || die "no ClusterPolicy found — is the NVIDIA GPU operator installed?"

  if [[ "${DRY_RUN:-false}" != "true" ]]; then
    oc create configmap kernel-repo-config -n "$GPU_NS" \
      --from-literal=local-kernel.repo="[local-kernel]
name=Local kernel and CUDA packages (disconnected)
baseurl=${url}
enabled=1
gpgcheck=0
priority=1" --dry-run=client -o yaml | oc apply -f - >/dev/null
    ok "ConfigMap kernel-repo-config"
  else
    dim "would create ConfigMap kernel-repo-config with baseurl=${url}"
  fi

  run oc patch "$cp" --type=merge \
    -p '{"spec":{"driver":{"repoConfig":{"configMapName":"kernel-repo-config"}}}}'
  ok "ClusterPolicy patched"

  # The operator rolls the driver DaemonSet itself, but only on the next
  # reconcile. Deleting the pods makes the retry immediate and, more usefully,
  # gives a clean log to read instead of one with the old failures in it.
  step "Restarting the driver pods"
  run oc delete pod -n "$GPU_NS" -l app=nvidia-driver-daemonset --ignore-not-found

  cat <<EOF

  The driver now compiles against the local repo. This takes 5-10 minutes.

    oc logs -n ${GPU_NS} -l app=nvidia-driver-daemonset --all-containers -f
    scripts/14-gpu-driver-disconnected.sh verify

EOF
}

# ===========================================================================
cmd_verify() {
  require_cmd oc jq
  require_cluster_admin

  step "Waiting for nvidia.com/gpu capacity"
  gpu_present() {
    local n
    n="$(oc get nodes -o json | jq '[.items[].status.capacity["nvidia.com/gpu"] // "0" | tonumber] | add')"
    [[ "${n:-0}" -gt 0 ]]
  }
  wait_for "at least one allocatable GPU" "${WAIT_TIMEOUT:-1800}" gpu_present

  oc get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.capacity.nvidia\\.com/gpu

  step "GPU operator pods"
  oc get pods -n "$GPU_NS" --no-headers | grep -vE 'Running|Completed' \
    && warn "some GPU operator pods are not Running" \
    || ok "all GPU operator pods Running or Completed"

  echo
  ok "GPU stack ready — continue with ./deploy-llmd.sh 40"
}

# ===========================================================================
case "$CMD" in
  diagnose)    cmd_diagnose ;;
  fetch-cuda)  cmd_fetch_cuda ;;
  build-repo)  cmd_build_repo ;;
  deploy-repo) cmd_deploy_repo ;;
  patch)       cmd_patch ;;
  verify)      cmd_verify ;;
  *) sed -n '2,12p' "$0" >&2; exit 1 ;;
esac
