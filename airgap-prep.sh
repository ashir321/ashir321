#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# airgap-prep.sh
#
# Prepare artefacts for an air-gapped Kubernetes + Calico +
# Longhorn deployment on RHEL-family systems.
#
# Prerequisites (prep machine — must be RHEL / CentOS / Rocky):
#   • dnf          (RPM downloads)
#   • docker or podman  (image pulls)
#   • curl
#   • root / sudo privileges
#
# Usage:
#   sudo ./airgap-prep.sh [inventory.ini]
#
# Outputs a bundle/ directory (or the path set by bundle_dir
# in inventory.ini):
#   bundle/
#     rpms/containerd/  — containerd.io + container-selinux RPMs
#     rpms/k8s/         — kubelet, kubeadm, kubectl RPMs
#     rpms/utils/       — curl, conntrack-tools, socat, etc.
#     images/           — container images saved as OCI tarballs
#     manifests/        — calico.yaml, longhorn.yaml
#     bundle-info.txt   — version metadata
#
# Transfer the entire bundle/ directory to the air-gapped
# environment, then run airgap-bootstrap.sh from the same
# working directory.
# ─────────────────────────────────────────────────────────────
set -euo pipefail

# ── Colour helpers ──────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header(){ echo -e "\n${BLUE}══════════════════════════════════════${NC}"; echo -e "${BLUE}  $*${NC}"; echo -e "${BLUE}══════════════════════════════════════${NC}"; }

# ── Defaults ────────────────────────────────────────────────
KUBE_VERSION="1.30"
KUBE_RPM_VERSION=""
CONTAINERD_VERSION="1.7.27"
CALICO_VERSION="3.29.3"
LONGHORN_VERSION="1.7.2"
BUNDLE_DIR="bundle"
EXTRA_IMAGES=""

# ── INI parser (minimal — handles [section] / key = value) ─
parse_ini() {
    local file="$1" section=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Strip inline comments and leading/trailing whitespace
        line="${line%%#*}"
        line="${line%%;;*}"
        line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ -z "$line" ]] && continue

        # Section header
        if [[ "$line" =~ ^\[([a-zA-Z0-9_]+)\]$ ]]; then
            section="${BASH_REMATCH[1]}"
            continue
        fi

        # Key = value
        if [[ "$line" =~ ^([a-zA-Z_][a-zA-Z0-9_]*)\ *=\ *(.*) ]]; then
            local key="${BASH_REMATCH[1]}" val="${BASH_REMATCH[2]}"
            val="$(echo "$val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            case "${section}/${key}" in
                versions/kube_version)      KUBE_VERSION="$val" ;;
                versions/kube_rpm_version)  KUBE_RPM_VERSION="$val" ;;
                versions/containerd_version) CONTAINERD_VERSION="$val" ;;
                versions/calico_version)    CALICO_VERSION="$val" ;;
                versions/longhorn_version)  LONGHORN_VERSION="$val" ;;
                paths/bundle_dir)           BUNDLE_DIR="$val" ;;
                images/extra)               EXTRA_IMAGES="$val" ;;
            esac
        fi
    done < "$file"
}

# ── Read optional inventory file ────────────────────────────
INVENTORY="${1:-}"
if [[ -n "$INVENTORY" ]]; then
    if [[ ! -f "$INVENTORY" ]]; then
        err "Inventory file not found: $INVENTORY"
        exit 1
    fi
    info "Loading configuration from $INVENTORY"
    parse_ini "$INVENTORY"
fi

# ── Pre-flight checks ──────────────────────────────────────
header "Pre-flight checks"

if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (or via sudo)."
    exit 1
fi

for cmd in dnf curl; do
    if ! command -v "$cmd" &>/dev/null; then
        err "Required command not found: $cmd"
        exit 1
    fi
done

CONTAINER_RT=""
if command -v docker &>/dev/null; then
    CONTAINER_RT="docker"
elif command -v podman &>/dev/null; then
    CONTAINER_RT="podman"
else
    err "Neither docker nor podman found. Install one to pull images."
    exit 1
fi
info "Container runtime: $CONTAINER_RT"

# ── Create bundle directory tree ────────────────────────────
header "Creating bundle directory: $BUNDLE_DIR"
mkdir -p "${BUNDLE_DIR}/rpms/containerd"
mkdir -p "${BUNDLE_DIR}/rpms/k8s"
mkdir -p "${BUNDLE_DIR}/rpms/utils"
mkdir -p "${BUNDLE_DIR}/images"
mkdir -p "${BUNDLE_DIR}/manifests"
info "Directory tree created."

# ── Helper: download RPMs ──────────────────────────────────
download_rpms() {
    local dest="$1"; shift
    # $@ = package names
    info "Downloading RPMs to ${dest}: $*"
    dnf download --resolve --alldeps --destdir "$dest" "$@" -y 2>&1 | tail -5
}

# ── 1. containerd RPMs ──────────────────────────────────────
header "1/6  containerd RPMs"

# Add Docker CE repo (provides containerd.io)
if [[ ! -f /etc/yum.repos.d/docker-ce.repo ]]; then
    info "Adding Docker CE repository…"
    dnf config-manager --add-repo \
        https://download.docker.com/linux/centos/docker-ce.repo 2>/dev/null \
    || dnf config-manager --add-repo \
        https://download.docker.com/linux/rhel/docker-ce.repo 2>/dev/null \
    || true
fi

CONTAINERD_PKG="containerd.io"
if [[ -n "$CONTAINERD_VERSION" ]]; then
    CONTAINERD_PKG="containerd.io-${CONTAINERD_VERSION}"
fi
download_rpms "${BUNDLE_DIR}/rpms/containerd" "$CONTAINERD_PKG" container-selinux

info "containerd RPMs downloaded ✓"

# ── 2. Kubernetes RPMs ──────────────────────────────────────
header "2/6  Kubernetes RPMs"

# Add Kubernetes yum repo
KUBE_REPO_FILE="/etc/yum.repos.d/kubernetes.repo"
cat > "$KUBE_REPO_FILE" <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${KUBE_VERSION}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${KUBE_VERSION}/rpm/repodata/repomd.xml.key
EOF
info "Kubernetes v${KUBE_VERSION} repo configured."

K8S_PKGS=(kubelet kubeadm kubectl)
if [[ -n "$KUBE_RPM_VERSION" ]]; then
    K8S_PKGS=("kubelet-${KUBE_RPM_VERSION}" "kubeadm-${KUBE_RPM_VERSION}" "kubectl-${KUBE_RPM_VERSION}")
fi
download_rpms "${BUNDLE_DIR}/rpms/k8s" "${K8S_PKGS[@]}" kubernetes-cni cri-tools

info "Kubernetes RPMs downloaded ✓"

# ── 3. Utility RPMs ────────────────────────────────────────
header "3/6  Utility RPMs"

UTIL_PKGS=(
    curl
    conntrack-tools
    socat
    iproute
    iptables
    ebtables
    ethtool
    bash-completion
    tar
    yum-utils
    nfs-utils
    open-iscsi
    cryptsetup
)
download_rpms "${BUNDLE_DIR}/rpms/utils" "${UTIL_PKGS[@]}"

info "Utility RPMs downloaded ✓"

# ── 4. Container images ────────────────────────────────────
header "4/6  Container images"

# Well-known image list for the chosen Kubernetes version.
KUBE_IMG_TAG="v${KUBE_VERSION}.0"
if [[ -n "$KUBE_RPM_VERSION" ]]; then
    KUBE_IMG_TAG="v${KUBE_RPM_VERSION}"
fi

CORE_IMAGES=(
    "registry.k8s.io/kube-apiserver:${KUBE_IMG_TAG}"
    "registry.k8s.io/kube-controller-manager:${KUBE_IMG_TAG}"
    "registry.k8s.io/kube-scheduler:${KUBE_IMG_TAG}"
    "registry.k8s.io/kube-proxy:${KUBE_IMG_TAG}"
    "registry.k8s.io/coredns/coredns:v1.11.3"
    "registry.k8s.io/etcd:3.5.15-0"
    "registry.k8s.io/pause:3.9"
)

# Calico images
CALICO_IMAGES=(
    "docker.io/calico/cni:v${CALICO_VERSION}"
    "docker.io/calico/node:v${CALICO_VERSION}"
    "docker.io/calico/kube-controllers:v${CALICO_VERSION}"
)

# Longhorn images
LONGHORN_IMAGES=(
    "longhornio/longhorn-manager:v${LONGHORN_VERSION}"
    "longhornio/longhorn-engine:v${LONGHORN_VERSION}"
    "longhornio/longhorn-ui:v${LONGHORN_VERSION}"
    "longhornio/longhorn-instance-manager:v${LONGHORN_VERSION}"
    "longhornio/longhorn-share-manager:v${LONGHORN_VERSION}"
    "longhornio/backing-image-manager:v${LONGHORN_VERSION}"
    "longhornio/support-bundle-kit:v0.0.45"
    "longhornio/csi-attacher:v4.7.0"
    "longhornio/csi-provisioner:v4.0.1"
    "longhornio/csi-resizer:v1.12.0"
    "longhornio/csi-snapshotter:v7.0.2"
    "longhornio/csi-node-driver-registrar:v2.12.0"
    "longhornio/livenessprobe:v2.14.0"
)

ALL_IMAGES=( "${CORE_IMAGES[@]}" "${CALICO_IMAGES[@]}" "${LONGHORN_IMAGES[@]}" )

# Append any extra images from inventory
if [[ -n "$EXTRA_IMAGES" ]]; then
    while IFS= read -r img; do
        img="$(echo "$img" | xargs)"
        [[ -n "$img" ]] && ALL_IMAGES+=("$img")
    done <<< "$EXTRA_IMAGES"
fi

pull_and_save() {
    local image="$1"
    local safe_name
    safe_name="$(echo "$image" | tr '/:' '_')"
    local tarball="${BUNDLE_DIR}/images/${safe_name}.tar"

    if [[ -f "$tarball" ]]; then
        info "Already saved: $image"
        return 0
    fi

    info "Pulling $image …"
    if ! $CONTAINER_RT pull "$image" 2>&1 | tail -2; then
        warn "Failed to pull $image — skipping."
        return 0
    fi

    info "Saving $image → ${tarball}"
    $CONTAINER_RT save -o "$tarball" "$image"
}

for img in "${ALL_IMAGES[@]}"; do
    pull_and_save "$img"
done

info "Container images saved ✓"

# ── 5. Manifests ────────────────────────────────────────────
header "5/6  Manifests"

CALICO_MANIFEST_URL="https://raw.githubusercontent.com/projectcalico/calico/v${CALICO_VERSION}/manifests/calico.yaml"
LONGHORN_MANIFEST_URL="https://raw.githubusercontent.com/longhorn/longhorn/v${LONGHORN_VERSION}/deploy/longhorn.yaml"

info "Downloading Calico manifest (v${CALICO_VERSION}) …"
curl -fsSL -o "${BUNDLE_DIR}/manifests/calico.yaml" "$CALICO_MANIFEST_URL"

info "Downloading Longhorn manifest (v${LONGHORN_VERSION}) …"
curl -fsSL -o "${BUNDLE_DIR}/manifests/longhorn.yaml" "$LONGHORN_MANIFEST_URL"

info "Manifests downloaded ✓"

# ── 6. bundle-info.txt ─────────────────────────────────────
header "6/6  Writing bundle-info.txt"

cat > "${BUNDLE_DIR}/bundle-info.txt" <<EOF
# ── Airgap Bundle Info ──────────────────────────────────────
generated_at      : $(date -u '+%Y-%m-%dT%H:%M:%SZ')
generated_on      : $(hostname -f 2>/dev/null || hostname)
generated_by      : $(whoami)

kube_version      : ${KUBE_VERSION}
kube_rpm_version  : ${KUBE_RPM_VERSION:-latest in repo}
containerd_version: ${CONTAINERD_VERSION}
calico_version    : ${CALICO_VERSION}
longhorn_version  : ${LONGHORN_VERSION}

container_runtime : ${CONTAINER_RT}
bundle_dir        : $(cd "$BUNDLE_DIR" && pwd)

# RPM counts
containerd_rpms   : $(find "${BUNDLE_DIR}/rpms/containerd" -name '*.rpm' 2>/dev/null | wc -l)
k8s_rpms          : $(find "${BUNDLE_DIR}/rpms/k8s" -name '*.rpm' 2>/dev/null | wc -l)
util_rpms         : $(find "${BUNDLE_DIR}/rpms/utils" -name '*.rpm' 2>/dev/null | wc -l)

# Image tarballs
image_tarballs    : $(find "${BUNDLE_DIR}/images" -name '*.tar' 2>/dev/null | wc -l)

# Manifests
manifests         : $(find "${BUNDLE_DIR}/manifests" -name '*.yaml' -print0 2>/dev/null | xargs -0 -n1 basename 2>/dev/null | tr '\n' ', ' | sed 's/,$//')
EOF

info "bundle-info.txt written ✓"

# ── Summary ─────────────────────────────────────────────────
header "Bundle complete!"
echo ""
info "Bundle location : $(cd "$BUNDLE_DIR" && pwd)"
info "Total size      : $(du -sh "$BUNDLE_DIR" | cut -f1)"
echo ""
info "Contents:"
find "$BUNDLE_DIR" -mindepth 1 -maxdepth 1 -printf '  %f/\n' | sort
echo ""
info "Transfer the entire ${BUNDLE_DIR}/ directory to the"
info "air-gapped environment, then run airgap-bootstrap.sh."
