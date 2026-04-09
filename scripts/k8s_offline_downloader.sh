#!/usr/bin/env bash
###############################################################################
# k8s_offline_downloader.sh
#
# Downloads ALL files needed for K8s Automation_Ansible air-gapped Kubernetes deployment.
# Input:  Kubernetes version (e.g., v1.32.4)
# Output: binaries.tar.gz, images.tar.gz, packages.tar.gz, other/ directory
#
# Usage:
#   ./k8s_offline_downloader.sh --k8s-version v1.32.4 --output-dir /path/to/K8s Automation_Ansible
#
# Requirements:
#   - Linux x86_64 with internet access
#   - docker (for pulling/saving container images)
#   - curl, tar, jq
#   - yumdownloader + yum-utils (optional, for RPM downloads)
#
# Author: OpenCode Agent
# Date:   2026-03-29
###############################################################################

set -euo pipefail

# ============================================================================
# CONSTANTS & DEFAULTS
# ============================================================================
SCRIPT_VERSION="2.4.0"
ARCH="amd64"
ARCH_RPM="x86_64"
OS="linux"
PLATFORM="${OS}-${ARCH}"

# Phase outcome tracking
PHASE1_TOTAL=0; PHASE1_FAILED=0
PHASE2_TOTAL=0; PHASE2_FAILED=0
PHASE3_TOTAL=0; PHASE3_FAILED=0
PHASE4_TOTAL=0; PHASE4_FAILED=0

# Default component versions (overridden by auto-resolution)
DEFAULT_ETCD_VERSION="v3.5.21"
DEFAULT_HELM_VERSION="v3.17.3"
DEFAULT_CONTAINERD_VERSION="1.7.27"
DEFAULT_CRICTL_VERSION="v1.32.0"
DEFAULT_CFSSL_VERSION="1.6.5"
DEFAULT_SOCAT_VERSION="1.8.0.3"
DEFAULT_KEEPALIVED_VERSION="v2.2.8"
DEFAULT_YQ_VERSION="v4.44.6"

# RPM package versions — now set dynamically by setup_rpm_tables() based on TARGET_EL
DEFAULT_TAR_RPM=""
DEFAULT_UNZIP_RPM=""
DEFAULT_ZIP_RPM=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ============================================================================
# LOGGING
# ============================================================================
log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "${BLUE}[STEP]${NC}  $*"; }
log_debug() { [[ "${DEBUG:-0}" == "1" ]] && echo -e "${CYAN}[DEBUG]${NC} $*" || true; }

# ============================================================================
# USAGE
# ============================================================================
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Downloads all files for K8s Automation_Ansible offline Kubernetes deployment.

Required:
  --k8s-version VERSION    Kubernetes version (e.g., v1.32.4)

Optional:
  --output-dir DIR         Output directory (default: current directory)
  --target-os OS           Target cluster OS: el8 or el9 (default: el9)
                           el8 = RHEL 8 / AlmaLinux 8 / Rocky 8
                           el9 = RHEL 9 / AlmaLinux 9 / Rocky 9
  --etcd-version VERSION   Override etcd version (default: auto-resolved)
  --helm-version VERSION   Override Helm version (default: ${DEFAULT_HELM_VERSION})
  --containerd-version V   Override containerd version (default: ${DEFAULT_CONTAINERD_VERSION})
  --crictl-version V       Override crictl version (default: auto-matched to K8s)
  --cfssl-version V        Override cfssl version (default: ${DEFAULT_CFSSL_VERSION})
  --yq-version V           Override yq version (default: ${DEFAULT_YQ_VERSION})
  --calico-version V       Override Calico version (default: auto-resolved from K8s mapping)
  --arch ARCH              Target binary architecture: amd64 or arm64 (default: amd64)
  --rpm-config FILE        JSON file with RPM version overrides (see docs for schema)
                           Overrides the hardcoded RPM tables set by --target-os.
                           The agent generates this file after researching current
                           AlmaLinux mirror package versions via WebFetch.
  --skip-binaries          Skip binary downloads
  --skip-images            Skip container image downloads
  --skip-packages          Skip RPM package downloads
  --skip-other             Skip other/ directory files
  --skip-version-resolve   Skip auto-resolution from kubeadm source
  --existing-bundle DIR    Path to existing K8s Automation_Ansible dir with tar.gz files
                           Used to copy socat, keepalived, keepalivedbundle,
                           and RPM packages that can't be downloaded
  --proxy URL              HTTP proxy for downloads (e.g., http://proxy:80)
  --debug                  Enable debug output
  --dry-run                Show what would be downloaded without downloading
  --help                   Show this help message

Examples:
  $0 --k8s-version v1.32.4 --output-dir /root/K8s Automation_Ansible
  $0 --k8s-version v1.35.3 --target-os el9 --output-dir /root/K8s Automation_Ansible
  $0 --k8s-version v1.35.3 --target-os el8 --existing-bundle /root/without_k8s_automation/K8s Automation_Ansible --output-dir /root/K8s Automation_Ansible
  $0 --k8s-version v1.37.0 --target-os el9 --rpm-config /tmp/rpm_versions.json --calico-version 3.32.0
  $0 --k8s-version v1.29.6 --dry-run

EOF
    exit 0
}

# ============================================================================
# ARGUMENT PARSING
# ============================================================================
K8S_VERSION=""
OUTPUT_DIR="."
ETCD_VERSION=""
HELM_VERSION="${DEFAULT_HELM_VERSION}"
CONTAINERD_VERSION="${DEFAULT_CONTAINERD_VERSION}"
CRICTL_VERSION=""
CFSSL_VERSION="${DEFAULT_CFSSL_VERSION}"
YQ_VERSION="${DEFAULT_YQ_VERSION}"
SKIP_BINARIES=0
SKIP_IMAGES=0
SKIP_PACKAGES=0
SKIP_OTHER=0
SKIP_VERSION_RESOLVE=0
EXISTING_BUNDLE=""
PROXY_URL=""
DEBUG=0
DRY_RUN=0
HAS_YUMDOWNLOADER=0
HAS_DNF=0
NEED_KEEPALIVED_FROM_RPM=0
IS_EL9=0
HOST_OS_EL=""
TARGET_EL=""          # Target cluster OS: "el8" or "el9" — set by --target-os or defaults to "el9"
TARGET_EL_MAJOR=""    # Just the number: "8" or "9"
RPM_CONFIG_FILE=""    # Optional JSON file with RPM version overrides (--rpm-config)
CALICO_VERSION_OVERRIDE=""  # Optional CLI override for Calico version (--calico-version)

# RPM lookup table variables (populated by setup_rpm_tables)
ALMA_APPSTREAM_BASE=""
ALMA_BASEOS_BASE=""
ALMA_VAULT_BASE=""
DOCKER_REPO_BASE=""

# Versions resolved from kubeadm
COREDNS_VERSION=""
PAUSE_VERSION=""
CALICO_VERSION=""

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --k8s-version)       K8S_VERSION="$2"; shift 2;;
            --output-dir)        OUTPUT_DIR="$2"; shift 2;;
            --target-os)         TARGET_EL="$2"; shift 2;;
            --arch)              ARCH="$2"; shift 2;;
            --etcd-version)      ETCD_VERSION="$2"; shift 2;;
            --helm-version)      HELM_VERSION="$2"; shift 2;;
            --containerd-version) CONTAINERD_VERSION="$2"; shift 2;;
            --crictl-version)    CRICTL_VERSION="$2"; shift 2;;
            --cfssl-version)     CFSSL_VERSION="$2"; shift 2;;
            --yq-version)        YQ_VERSION="$2"; shift 2;;
            --calico-version)    CALICO_VERSION_OVERRIDE="$2"; shift 2;;
            --rpm-config)        RPM_CONFIG_FILE="$2"; shift 2;;
            --skip-binaries)     SKIP_BINARIES=1; shift;;
            --skip-images)       SKIP_IMAGES=1; shift;;
            --skip-packages)     SKIP_PACKAGES=1; shift;;
            --skip-other)        SKIP_OTHER=1; shift;;
            --skip-version-resolve) SKIP_VERSION_RESOLVE=1; shift;;
            --existing-bundle)   EXISTING_BUNDLE="$2"; shift 2;;
            --proxy)             PROXY_URL="$2"; shift 2;;
            --debug)             DEBUG=1; shift;;
            --dry-run)           DRY_RUN=1; shift;;
            --help|-h)           usage;;
            *)                   log_error "Unknown option: $1"; usage;;
        esac
    done

    # Derive RPM arch from binary arch
    case "$ARCH" in
        amd64)  ARCH_RPM="x86_64"  ;;
        arm64)  ARCH_RPM="aarch64" ;;
        *)      log_error "Invalid --arch '${ARCH}'. Must be 'amd64' or 'arm64'"; exit 1 ;;
    esac

    # Validate required args
    if [[ -z "$K8S_VERSION" ]]; then
        log_error "--k8s-version is required"
        usage
    fi

    # Normalize version: ensure it starts with 'v'
    if [[ "$K8S_VERSION" != v* ]]; then
        K8S_VERSION="v${K8S_VERSION}"
    fi

    # Validate --target-os if provided
    if [[ -n "$TARGET_EL" ]]; then
        case "$TARGET_EL" in
            el8|EL8) TARGET_EL="el8" ;;
            el9|EL9) TARGET_EL="el9" ;;
            8)       TARGET_EL="el8" ;;
            9)       TARGET_EL="el9" ;;
            *)
                log_error "--target-os must be 'el8' or 'el9' (got: ${TARGET_EL})"
                log_error "  el8 = RHEL 8 / AlmaLinux 8 / Rocky 8"
                log_error "  el9 = RHEL 9 / AlmaLinux 9 / Rocky 9"
                exit 1
                ;;
        esac
    fi

    # Validate --rpm-config if provided
    if [[ -n "$RPM_CONFIG_FILE" ]]; then
        if [[ ! -f "$RPM_CONFIG_FILE" ]]; then
            log_error "--rpm-config file not found: ${RPM_CONFIG_FILE}"
            exit 1
        fi
        if ! jq empty "$RPM_CONFIG_FILE" 2>/dev/null; then
            log_error "--rpm-config file is not valid JSON: ${RPM_CONFIG_FILE}"
            exit 1
        fi
        log_info "RPM config override file: ${RPM_CONFIG_FILE}"
    fi

    # Set proxy environment variables if provided
    if [[ -n "$PROXY_URL" ]]; then
        export http_proxy="$PROXY_URL"
        export https_proxy="$PROXY_URL"
        export HTTP_PROXY="$PROXY_URL"
        export HTTPS_PROXY="$PROXY_URL"
        export no_proxy="localhost,127.0.0.1"
        log_info "Using proxy: ${PROXY_URL}"
    fi
}

# ============================================================================
# PREREQUISITE CHECKS
# ============================================================================
check_prerequisites() {
    log_step "Checking prerequisites..."

    local missing=()
    for cmd in curl tar jq; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        exit 1
    fi

    # Check for container runtime (for image downloads)
    if [[ $SKIP_IMAGES -eq 0 ]]; then
        if command -v docker &>/dev/null; then
            CONTAINER_RUNTIME="docker"
            log_info "Using Docker for container images"
        elif command -v skopeo &>/dev/null; then
            CONTAINER_RUNTIME="skopeo"
            log_info "Using Skopeo for container images"
        elif command -v ctr &>/dev/null; then
            CONTAINER_RUNTIME="ctr"
            log_info "Using ctr (containerd) for container images"
        else
            log_warn "No container runtime found (docker/skopeo/ctr). Image downloads will be skipped."
            SKIP_IMAGES=1
        fi
    fi

    # Check for yumdownloader / dnf (for RPM downloads)
    if [[ $SKIP_PACKAGES -eq 0 || $SKIP_OTHER -eq 0 ]]; then
        if command -v yumdownloader &>/dev/null; then
            HAS_YUMDOWNLOADER=1
            HAS_DNF=0
            log_info "yumdownloader available for RPM downloads"
        elif command -v dnf &>/dev/null; then
            HAS_YUMDOWNLOADER=0
            HAS_DNF=1
            log_info "dnf available (will use 'dnf download' as fallback for RPMs)"
        else
            HAS_YUMDOWNLOADER=0
            HAS_DNF=0
            log_warn "Neither yumdownloader nor dnf found. RPM downloads will use direct AlmaLinux mirror URLs."
            log_warn "This is fine but may not resolve all dependencies automatically."
        fi
    fi

    log_info "Prerequisites OK"
}

# ============================================================================
# AUTO-DETECT EXISTING BUNDLE
# ============================================================================
auto_detect_existing_bundle() {
    if [[ -n "$EXISTING_BUNDLE" ]]; then
        if [[ -d "$EXISTING_BUNDLE" ]]; then
            log_info "Using user-specified existing bundle: ${EXISTING_BUNDLE}"
            return 0
        else
            log_warn "Specified --existing-bundle path does not exist: ${EXISTING_BUNDLE}"
            EXISTING_BUNDLE=""
        fi
    fi

    # Auto-detect: search common paths for an existing K8s Automation_Ansible deployment
    local search_paths=(
        "/root/without_k8s_automation/K8s Automation_Ansible"
        "/root/K8s Automation_Ansible"
        "/home/K8s Automation_Ansible"
        "/opt/K8s Automation_Ansible"
    )

    # Also check parent of output dir (e.g., if output is /root/test/K8s Automation_Ansible,
    # check /root/K8s Automation_Ansible)
    local parent_dir
    parent_dir=$(dirname "$OUTPUT_DIR")
    if [[ "$parent_dir" != "/" ]]; then
        search_paths+=("${parent_dir}/K8s Automation_Ansible")
    fi

    for candidate in "${search_paths[@]}"; do
        # Skip if candidate is the output dir itself
        if [[ "$(realpath "$candidate" 2>/dev/null)" == "$(realpath "$OUTPUT_DIR" 2>/dev/null)" ]]; then
            continue
        fi
        if [[ -d "$candidate" && -f "${candidate}/packages.tar.gz" ]]; then
            EXISTING_BUNDLE="$candidate"
            log_info "Auto-detected existing bundle: ${EXISTING_BUNDLE}"
            return 0
        fi
    done

    log_warn "No existing K8s Automation_Ansible bundle found. Will download everything from scratch."
    return 0
}

# ============================================================================
# DETECT HOST OS VERSION
# ============================================================================
detect_host_os() {
    HOST_OS_VERSION_ID=""
    HOST_OS_EL=""
    if [[ -f /etc/os-release ]]; then
        HOST_OS_VERSION_ID=$(grep -oP 'VERSION_ID="\K[^"]+' /etc/os-release 2>/dev/null | cut -d. -f1 || echo "")
    fi
    if [[ -n "$HOST_OS_VERSION_ID" ]]; then
        HOST_OS_EL="el${HOST_OS_VERSION_ID}"
    fi
    IS_EL9=0
    if [[ "$HOST_OS_VERSION_ID" == "9" ]]; then
        IS_EL9=1
    fi
    log_debug "Host OS: el${HOST_OS_VERSION_ID:-unknown}, IS_EL9=${IS_EL9}"
}

# ============================================================================
# RESOLVE TARGET OS — Determines which RPMs to download (el8 or el9)
# ============================================================================
resolve_target_os() {
    if [[ -n "$TARGET_EL" ]]; then
        # User explicitly specified --target-os
        TARGET_EL_MAJOR="${TARGET_EL#el}"
        log_info "Target cluster OS: ${TARGET_EL} (from --target-os)"
    else
        # Default to el9
        TARGET_EL="el9"
        TARGET_EL_MAJOR="9"
        log_info "Target cluster OS: ${TARGET_EL} (default — use --target-os el8 for RHEL8/AlmaLinux8)"
    fi

    # Set up AlmaLinux mirror base URLs for the target OS
    ALMA_APPSTREAM_BASE="https://repo.almalinux.org/almalinux/${TARGET_EL_MAJOR}/AppStream/${ARCH_RPM}/os/Packages"
    ALMA_BASEOS_BASE="https://repo.almalinux.org/almalinux/${TARGET_EL_MAJOR}/BaseOS/${ARCH_RPM}/os/Packages"
    ALMA_VAULT_BASE="https://vault.almalinux.org"
    DOCKER_REPO_BASE="https://download.docker.com/linux/centos/${TARGET_EL_MAJOR}/${ARCH_RPM}/stable/Packages"

    log_debug "ALMA_APPSTREAM_BASE=${ALMA_APPSTREAM_BASE}"
    log_debug "ALMA_BASEOS_BASE=${ALMA_BASEOS_BASE}"
    log_debug "DOCKER_REPO_BASE=${DOCKER_REPO_BASE}"
}

# ============================================================================
# RPM LOOKUP TABLES — el8 vs el9 package versions
# ============================================================================
# Uses bash 4.x associative arrays. These are populated by setup_rpm_tables()
# and consumed by download_packages() and download_other_files().
#
# IMPORTANT: containerd.io for el8 maxes out at 1.6.32 (Docker stopped el8
# builds after that). For el9, we use the latest 1.7.x.
# ============================================================================
setup_rpm_tables() {
    log_step "Setting up RPM lookup tables for ${TARGET_EL}..."

    # --- containerd ---
    if [[ "$TARGET_EL" == "el8" ]]; then
        # Docker stopped publishing el8 containerd builds after 1.6.32
        CONTAINERD_RPM="containerd.io-1.6.32-3.1.el8.${ARCH_RPM}.rpm"
        CONTAINERD_VERSION_EFFECTIVE="1.6.32"
        log_warn "containerd.io for el8 is limited to version 1.6.32 (Docker ended el8 builds)"
        log_warn "  el9 uses containerd ${CONTAINERD_VERSION}. el8 targets will get 1.6.32."
    else
        CONTAINERD_RPM="containerd.io-${CONTAINERD_VERSION}-3.1.el9.${ARCH_RPM}.rpm"
        CONTAINERD_VERSION_EFFECTIVE="${CONTAINERD_VERSION}"
    fi

    # --- socat RPM URLs (for binary extraction fallback) ---
    if [[ "$TARGET_EL" == "el8" ]]; then
        SOCAT_RPM_URLS=(
            "${ALMA_APPSTREAM_BASE}/socat-1.7.4.1-2.el8_10.${ARCH_RPM}.rpm"
            "${ALMA_APPSTREAM_BASE}/socat-1.7.4.1-1.el8.${ARCH_RPM}.rpm"
        )
    else
        SOCAT_RPM_URLS=(
            "${ALMA_APPSTREAM_BASE}/socat-1.7.4.1-8.el9.alma.1.${ARCH_RPM}.rpm"
            "${ALMA_APPSTREAM_BASE}/socat-1.7.4.1-8.el9.${ARCH_RPM}.rpm"
        )
    fi

    # --- keepalived RPM (for binary extraction fallback) ---
    if [[ "$TARGET_EL" == "el8" ]]; then
        KEEPALIVED_RPM_URL="${ALMA_APPSTREAM_BASE}/keepalived-2.1.5-11.el8_10.${ARCH_RPM}.rpm"
    else
        KEEPALIVED_RPM_URL="${ALMA_APPSTREAM_BASE}/keepalived-2.2.8-6.el9.${ARCH_RPM}.rpm"
    fi

    # --- chrony RPM ---
    if [[ "$TARGET_EL" == "el8" ]]; then
        CHRONY_RPM_URLS=(
            "${ALMA_BASEOS_BASE}/chrony-4.5-2.el8_10.${ARCH_RPM}.rpm"
            "${ALMA_BASEOS_BASE}/chrony-4.3-2.el8.${ARCH_RPM}.rpm"
        )
    else
        CHRONY_RPM_URLS=(
            "${ALMA_BASEOS_BASE}/chrony-4.6.1-2.el9.${ARCH_RPM}.rpm"
            "${ALMA_VAULT_BASE}/9.4/BaseOS/${ARCH_RPM}/os/Packages/chrony-4.5-1.el9.${ARCH_RPM}.rpm"
            "${ALMA_VAULT_BASE}/9.3/BaseOS/${ARCH_RPM}/os/Packages/chrony-4.3-1.el9.${ARCH_RPM}.rpm"
        )
    fi

    # --- keepalived + dependencies RPMs ---
    # Core keepalived deps: net-snmp-libs, net-snmp-agent-libs, lm_sensors-libs,
    # mariadb-connector-c, mariadb-connector-c-config
    # NOTE: On el8, net-snmp-libs and lm_sensors-libs are in BaseOS (not AppStream)
    if [[ "$TARGET_EL" == "el8" ]]; then
        KA_CORE_RPMS=(
            "${ALMA_APPSTREAM_BASE}/keepalived-2.1.5-11.el8_10.${ARCH_RPM}.rpm"
            "${ALMA_BASEOS_BASE}/net-snmp-libs-5.8-33.el8_10.${ARCH_RPM}.rpm"
            "${ALMA_APPSTREAM_BASE}/net-snmp-agent-libs-5.8-33.el8_10.${ARCH_RPM}.rpm"
            "${ALMA_BASEOS_BASE}/lm_sensors-libs-3.4.0-23.el8.${ARCH_RPM}.rpm"
            "${ALMA_APPSTREAM_BASE}/mariadb-connector-c-3.1.11-2.el8_3.${ARCH_RPM}.rpm"
            "${ALMA_APPSTREAM_BASE}/mariadb-connector-c-config-3.1.11-2.el8_3.noarch.rpm"
        )
    else
        KA_CORE_RPMS=(
            "${ALMA_APPSTREAM_BASE}/keepalived-2.2.8-6.el9.${ARCH_RPM}.rpm"
            "${ALMA_APPSTREAM_BASE}/net-snmp-libs-5.9.1-17.el9.${ARCH_RPM}.rpm"
            "${ALMA_APPSTREAM_BASE}/net-snmp-agent-libs-5.9.1-17.el9.${ARCH_RPM}.rpm"
            "${ALMA_APPSTREAM_BASE}/lm_sensors-libs-3.6.0-10.el9.${ARCH_RPM}.rpm"
            "${ALMA_APPSTREAM_BASE}/mariadb-connector-c-3.2.6-1.el9_0.${ARCH_RPM}.rpm"
            "${ALMA_APPSTREAM_BASE}/mariadb-connector-c-config-3.2.6-1.el9_0.noarch.rpm"
        )
    fi

    # --- Perl dependency RPMs for keepalived ---
    # el9: perl 5.32.1-480, el8: perl 5.26.3-423
    if [[ "$TARGET_EL" == "el8" ]]; then
        PERL_RPM_BASE="${ALMA_BASEOS_BASE}"
        PERL_RPM_APPSTREAM="${ALMA_APPSTREAM_BASE}"
        PERL_RPMS=(
            "perl-interpreter-5.26.3-423.el8_10.${ARCH_RPM}.rpm"
            "perl-libs-5.26.3-423.el8_10.${ARCH_RPM}.rpm"
            "perl-AutoLoader-5.74-423.el8_10.noarch.rpm"
            "perl-B-1.74-423.el8_10.${ARCH_RPM}.rpm"
            "perl-base-2.27-423.el8_10.noarch.rpm"
            "perl-Carp-1.42-396.el8.noarch.rpm"
            "perl-Class-Struct-0.65-423.el8_10.noarch.rpm"
            "perl-constant-1.33-396.el8.noarch.rpm"
            "perl-Data-Dumper-2.167-399.el8.${ARCH_RPM}.rpm"
            "perl-Digest-1.17-395.el8.noarch.rpm"
            "perl-Digest-MD5-2.55-396.el8.${ARCH_RPM}.rpm"
            "perl-Encode-2.97-3.el8.${ARCH_RPM}.rpm"
            "perl-Errno-1.28-423.el8_10.${ARCH_RPM}.rpm"
            "perl-Exporter-5.72-396.el8.noarch.rpm"
            "perl-Fcntl-1.11-423.el8_10.${ARCH_RPM}.rpm"
            "perl-File-Basename-2.85-423.el8_10.noarch.rpm"
            "perl-FileHandle-2.02-423.el8_10.noarch.rpm"
            "perl-File-Path-2.15-2.el8.noarch.rpm"
            "perl-File-stat-1.07-423.el8_10.noarch.rpm"
            "perl-File-Temp-0.230.600-1.el8.noarch.rpm"
            "perl-Getopt-Long-2.50-4.el8.noarch.rpm"
            "perl-Getopt-Std-1.12-423.el8_10.noarch.rpm"
            "perl-HTTP-Tiny-0.074-1.el8.noarch.rpm"
            "perl-if-0.60.800-423.el8_10.noarch.rpm"
            "perl-IO-1.38-423.el8_10.${ARCH_RPM}.rpm"
            "perl-IO-Socket-IP-0.39-5.el8.noarch.rpm"
            "perl-IO-Socket-SSL-2.066-4.module_el8.6.0+2811+af9eff40.noarch.rpm"
            "perl-IPC-Open3-1.16-423.el8_10.noarch.rpm"
            "perl-libnet-3.11-3.el8.noarch.rpm"
            "perl-MIME-Base64-3.15-396.el8.${ARCH_RPM}.rpm"
            "perl-Mozilla-CA-20160104-7.module_el8.5.0+2812+ed912d05.noarch.rpm"
            "perl-mro-1.22-423.el8_10.${ARCH_RPM}.rpm"
            "perl-NDBM_File-1.14-423.el8_10.${ARCH_RPM}.rpm"
            "perl-Net-SSLeay-1.88-2.module_el8.6.0+2811+af9eff40.${ARCH_RPM}.rpm"
            "perl-overload-1.30-423.el8_10.noarch.rpm"
            "perl-overloading-0.02-423.el8_10.noarch.rpm"
            "perl-parent-0.237-1.el8.noarch.rpm"
            "perl-PathTools-3.74-1.el8.${ARCH_RPM}.rpm"
            "perl-Pod-Escapes-1.07-395.el8.noarch.rpm"
            "perl-podlators-4.11-1.el8.noarch.rpm"
            "perl-Pod-Perldoc-3.28-396.el8.noarch.rpm"
            "perl-Pod-Simple-3.35-395.el8.noarch.rpm"
            "perl-Pod-Usage-1.69-395.el8.noarch.rpm"
            "perl-POSIX-1.75-423.el8_10.${ARCH_RPM}.rpm"
            "perl-Scalar-List-Utils-1.49-2.el8.${ARCH_RPM}.rpm"
            "perl-SelectSaver-1.02-423.el8_10.noarch.rpm"
            "perl-Socket-2.027-3.el8.${ARCH_RPM}.rpm"
            "perl-Storable-3.11-3.el8.${ARCH_RPM}.rpm"
            "perl-subs-1.03-423.el8_10.noarch.rpm"
            "perl-Symbol-1.08-423.el8_10.noarch.rpm"
            "perl-Term-ANSIColor-4.06-396.el8.noarch.rpm"
            "perl-Term-Cap-1.17-395.el8.noarch.rpm"
            "perl-Text-ParseWords-3.30-395.el8.noarch.rpm"
            "perl-Text-Tabs+Wrap-2013.0523-395.el8.noarch.rpm"
            "perl-Time-Local-1.280-1.el8.noarch.rpm"
            "perl-URI-1.73-3.el8.noarch.rpm"
            "perl-vars-1.04-423.el8_10.noarch.rpm"
        )
    else
        PERL_RPM_BASE="${ALMA_BASEOS_BASE}"
        PERL_RPM_APPSTREAM="${ALMA_APPSTREAM_BASE}"
        PERL_RPMS=(
            "perl-interpreter-5.32.1-480.el9.${ARCH_RPM}.rpm"
            "perl-libs-5.32.1-480.el9.${ARCH_RPM}.rpm"
            "perl-AutoLoader-5.74-480.el9.noarch.rpm"
            "perl-B-1.80-480.el9.${ARCH_RPM}.rpm"
            "perl-base-2.27-480.el9.noarch.rpm"
            "perl-Carp-1.50-460.el9.noarch.rpm"
            "perl-Class-Struct-0.66-480.el9.noarch.rpm"
            "perl-constant-1.33-461.el9.noarch.rpm"
            "perl-Data-Dumper-2.174-462.el9.${ARCH_RPM}.rpm"
            "perl-Digest-1.19-4.el9.noarch.rpm"
            "perl-Digest-MD5-2.58-4.el9.${ARCH_RPM}.rpm"
            "perl-Encode-3.08-462.el9.${ARCH_RPM}.rpm"
            "perl-Errno-1.30-480.el9.${ARCH_RPM}.rpm"
            "perl-Exporter-5.74-461.el9.noarch.rpm"
            "perl-Fcntl-1.13-480.el9.${ARCH_RPM}.rpm"
            "perl-File-Basename-2.85-480.el9.noarch.rpm"
            "perl-FileHandle-2.03-480.el9.noarch.rpm"
            "perl-File-Path-2.18-4.el9.noarch.rpm"
            "perl-File-stat-1.09-480.el9.noarch.rpm"
            "perl-File-Temp-0.231.100-4.el9.noarch.rpm"
            "perl-Getopt-Long-2.52-4.el9.noarch.rpm"
            "perl-Getopt-Std-1.12-480.el9.noarch.rpm"
            "perl-HTTP-Tiny-0.076-461.el9.noarch.rpm"
            "perl-if-0.60.800-480.el9.noarch.rpm"
            "perl-IO-1.43-480.el9.${ARCH_RPM}.rpm"
            "perl-IO-Socket-IP-0.41-5.el9.noarch.rpm"
            "perl-IO-Socket-SSL-2.073-1.el9.noarch.rpm"
            "perl-IPC-Open3-1.21-480.el9.noarch.rpm"
            "perl-libnet-3.13-4.el9.noarch.rpm"
            "perl-MIME-Base64-3.16-4.el9.${ARCH_RPM}.rpm"
            "perl-Mozilla-CA-20200520-6.el9.noarch.rpm"
            "perl-mro-1.23-480.el9.${ARCH_RPM}.rpm"
            "perl-NDBM_File-1.15-480.el9.${ARCH_RPM}.rpm"
            "perl-Net-SSLeay-1.92-2.el9.${ARCH_RPM}.rpm"
            "perl-overload-1.31-480.el9.noarch.rpm"
            "perl-overloading-0.02-480.el9.noarch.rpm"
            "perl-parent-0.238-460.el9.noarch.rpm"
            "perl-PathTools-3.78-461.el9.${ARCH_RPM}.rpm"
            "perl-Pod-Escapes-1.07-460.el9.noarch.rpm"
            "perl-podlators-4.14-460.el9.noarch.rpm"
            "perl-Pod-Perldoc-3.28.01-461.el9.noarch.rpm"
            "perl-Pod-Simple-3.42-4.el9.noarch.rpm"
            "perl-Pod-Usage-2.01-4.el9.noarch.rpm"
            "perl-POSIX-1.94-480.el9.${ARCH_RPM}.rpm"
            "perl-Scalar-List-Utils-1.56-461.el9.${ARCH_RPM}.rpm"
            "perl-SelectSaver-1.02-480.el9.noarch.rpm"
            "perl-Socket-2.031-4.el9.${ARCH_RPM}.rpm"
            "perl-Storable-3.21-460.el9.${ARCH_RPM}.rpm"
            "perl-subs-1.03-480.el9.noarch.rpm"
            "perl-Symbol-1.08-480.el9.noarch.rpm"
            "perl-Term-ANSIColor-5.01-461.el9.noarch.rpm"
            "perl-Term-Cap-1.17-460.el9.noarch.rpm"
            "perl-Text-ParseWords-3.30-460.el9.noarch.rpm"
            "perl-Text-Tabs+Wrap-2013.0523-460.el9.noarch.rpm"
            "perl-Time-Local-1.300-7.el9.noarch.rpm"
            "perl-URI-5.09-3.el9.noarch.rpm"
            "perl-vars-1.05-480.el9.noarch.rpm"
        )
    fi

    # --- libnftnl RPM (for keepalivedbundle shared libs) ---
    if [[ "$TARGET_EL" == "el8" ]]; then
        LIBNFTNL_RPM_URL="${ALMA_BASEOS_BASE}/libnftnl-1.2.2-3.el8.${ARCH_RPM}.rpm"
    else
        LIBNFTNL_RPM_URL="${ALMA_BASEOS_BASE}/libnftnl-1.2.6-4.el9_4.${ARCH_RPM}.rpm"
    fi

    # --- tar/unzip/zip RPMs for other/ ---
    if [[ "$TARGET_EL" == "el8" ]]; then
        TAR_RPM_URLS=(
            "${ALMA_BASEOS_BASE}/tar-1.30-11.el8_10.${ARCH_RPM}.rpm"
            "${ALMA_BASEOS_BASE}/tar-1.30-9.el8.${ARCH_RPM}.rpm"
        )
        UNZIP_RPM_URLS=(
            "${ALMA_BASEOS_BASE}/unzip-6.0-48.el8_10.${ARCH_RPM}.rpm"
            "${ALMA_BASEOS_BASE}/unzip-6.0-46.el8.${ARCH_RPM}.rpm"
        )
        ZIP_RPM_URLS=(
            "${ALMA_BASEOS_BASE}/zip-3.0-23.el8.${ARCH_RPM}.rpm"
        )
    else
        TAR_RPM_URLS=(
            "${ALMA_BASEOS_BASE}/tar-1.34-7.el9.${ARCH_RPM}.rpm"
            "${ALMA_BASEOS_BASE}/tar-1.34-6.el9_1.${ARCH_RPM}.rpm"
            "${ALMA_VAULT_BASE}/9.5/BaseOS/${ARCH_RPM}/os/Packages/tar-1.34-7.el9.${ARCH_RPM}.rpm"
            "${ALMA_VAULT_BASE}/9.4/BaseOS/${ARCH_RPM}/os/Packages/tar-1.34-6.el9_1.${ARCH_RPM}.rpm"
        )
        UNZIP_RPM_URLS=(
            "${ALMA_BASEOS_BASE}/unzip-6.0-56.el9.${ARCH_RPM}.rpm"
            "${ALMA_VAULT_BASE}/9.5/BaseOS/${ARCH_RPM}/os/Packages/unzip-6.0-56.el9.${ARCH_RPM}.rpm"
            "${ALMA_VAULT_BASE}/9.4/BaseOS/${ARCH_RPM}/os/Packages/unzip-6.0-56.el9.${ARCH_RPM}.rpm"
        )
        ZIP_RPM_URLS=(
            "${ALMA_BASEOS_BASE}/zip-3.0-35.el9.${ARCH_RPM}.rpm"
            "${ALMA_VAULT_BASE}/9.5/BaseOS/${ARCH_RPM}/os/Packages/zip-3.0-35.el9.${ARCH_RPM}.rpm"
            "${ALMA_VAULT_BASE}/9.4/BaseOS/${ARCH_RPM}/os/Packages/zip-3.0-35.el9.${ARCH_RPM}.rpm"
        )
    fi

    log_info "RPM tables configured for ${TARGET_EL}"
    log_info "  containerd RPM: ${CONTAINERD_RPM}"
    log_info "  keepalived RPM: $(basename "${KEEPALIVED_RPM_URL}")"
    log_info "  Perl RPMs: ${#PERL_RPMS[@]} packages"
}

# ============================================================================
# LOAD RPM CONFIG OVERRIDES — Reads JSON file and overrides setup_rpm_tables()
# ============================================================================
# Called after setup_rpm_tables() when --rpm-config is specified.
# The JSON file allows the agent to override hardcoded RPM filenames with
# dynamically discovered versions from AlmaLinux mirrors.
#
# JSON schema (all fields optional — only specified fields override defaults):
# {
#   "target_os": "el9",                    // informational, must match --target-os
#   "containerd": {
#     "rpm": "containerd.io-1.7.28-3.1.el9.x86_64.rpm"
#   },
#   "socat": {
#     "rpm_urls": ["https://repo.almalinux.org/.../socat-1.7.4.1-9.el9.x86_64.rpm"]
#   },
#   "keepalived": {
#     "rpm_url": "https://repo.almalinux.org/.../keepalived-2.2.8-7.el9.x86_64.rpm",
#     "core_rpms": ["https://...keepalived-2.2.8-7.el9.x86_64.rpm", "..."],
#     "perl_rpms": ["perl-interpreter-5.32.1-481.el9.x86_64.rpm", "..."],
#     "perl_rpm_base": "https://repo.almalinux.org/almalinux/9/BaseOS/x86_64/os/Packages",
#     "perl_rpm_appstream": "https://repo.almalinux.org/almalinux/9/AppStream/x86_64/os/Packages"
#   },
#   "chrony": {
#     "rpm_urls": ["https://repo.almalinux.org/.../chrony-4.6.1-3.el9.x86_64.rpm"]
#   },
#   "libnftnl": {
#     "rpm_url": "https://repo.almalinux.org/.../libnftnl-1.2.6-5.el9.x86_64.rpm"
#   },
#   "tar": {
#     "rpm_urls": ["https://repo.almalinux.org/.../tar-1.34-8.el9.x86_64.rpm"]
#   },
#   "unzip": {
#     "rpm_urls": ["https://repo.almalinux.org/.../unzip-6.0-57.el9.x86_64.rpm"]
#   },
#   "zip": {
#     "rpm_urls": ["https://repo.almalinux.org/.../zip-3.0-36.el9.x86_64.rpm"]
#   }
# }
# ============================================================================
load_rpm_config() {
    if [[ -z "$RPM_CONFIG_FILE" ]]; then
        return 0
    fi

    log_step "Loading RPM config overrides from ${RPM_CONFIG_FILE}..."

    # Validate target_os in the JSON matches --target-os if present
    local json_target_os
    json_target_os=$(jq -r '.target_os // empty' "$RPM_CONFIG_FILE")
    if [[ -n "$json_target_os" && "$json_target_os" != "$TARGET_EL" ]]; then
        log_warn "RPM config target_os '${json_target_os}' does not match --target-os '${TARGET_EL}'"
        log_warn "The RPM config file may contain wrong package versions for this target OS!"
    fi

    # --- containerd ---
    local val
    val=$(jq -r '.containerd.rpm // empty' "$RPM_CONFIG_FILE")
    if [[ -n "$val" ]]; then
        log_info "  Override containerd RPM: ${val}"
        CONTAINERD_RPM="$val"
    fi

    # --- socat RPM URLs ---
    local count
    count=$(jq -r '.socat.rpm_urls | length // 0' "$RPM_CONFIG_FILE" 2>/dev/null || echo "0")
    if [[ "$count" -gt 0 ]]; then
        SOCAT_RPM_URLS=()
        local i
        for ((i=0; i<count; i++)); do
            val=$(jq -r ".socat.rpm_urls[$i]" "$RPM_CONFIG_FILE")
            SOCAT_RPM_URLS+=("$val")
        done
        log_info "  Override socat RPM URLs: ${count} entries"
    fi

    # --- keepalived RPM URL ---
    val=$(jq -r '.keepalived.rpm_url // empty' "$RPM_CONFIG_FILE")
    if [[ -n "$val" ]]; then
        log_info "  Override keepalived RPM URL: $(basename "$val")"
        KEEPALIVED_RPM_URL="$val"
    fi

    # --- keepalived core RPMs (full URLs) ---
    count=$(jq -r '.keepalived.core_rpms | length // 0' "$RPM_CONFIG_FILE" 2>/dev/null || echo "0")
    if [[ "$count" -gt 0 ]]; then
        KA_CORE_RPMS=()
        local i
        for ((i=0; i<count; i++)); do
            val=$(jq -r ".keepalived.core_rpms[$i]" "$RPM_CONFIG_FILE")
            KA_CORE_RPMS+=("$val")
        done
        log_info "  Override keepalived core RPMs: ${count} entries"
    fi

    # --- perl RPMs (filenames only — downloaded from perl_rpm_base/perl_rpm_appstream) ---
    count=$(jq -r '.keepalived.perl_rpms | length // 0' "$RPM_CONFIG_FILE" 2>/dev/null || echo "0")
    if [[ "$count" -gt 0 ]]; then
        PERL_RPMS=()
        local i
        for ((i=0; i<count; i++)); do
            val=$(jq -r ".keepalived.perl_rpms[$i]" "$RPM_CONFIG_FILE")
            PERL_RPMS+=("$val")
        done
        log_info "  Override perl RPMs: ${count} entries"
    fi

    # --- perl RPM base URLs ---
    val=$(jq -r '.keepalived.perl_rpm_base // empty' "$RPM_CONFIG_FILE")
    if [[ -n "$val" ]]; then
        log_info "  Override perl RPM base URL: ${val}"
        PERL_RPM_BASE="$val"
    fi
    val=$(jq -r '.keepalived.perl_rpm_appstream // empty' "$RPM_CONFIG_FILE")
    if [[ -n "$val" ]]; then
        log_info "  Override perl RPM appstream URL: ${val}"
        PERL_RPM_APPSTREAM="$val"
    fi

    # --- chrony RPM URLs ---
    count=$(jq -r '.chrony.rpm_urls | length // 0' "$RPM_CONFIG_FILE" 2>/dev/null || echo "0")
    if [[ "$count" -gt 0 ]]; then
        CHRONY_RPM_URLS=()
        local i
        for ((i=0; i<count; i++)); do
            val=$(jq -r ".chrony.rpm_urls[$i]" "$RPM_CONFIG_FILE")
            CHRONY_RPM_URLS+=("$val")
        done
        log_info "  Override chrony RPM URLs: ${count} entries"
    fi

    # --- libnftnl RPM URL ---
    val=$(jq -r '.libnftnl.rpm_url // empty' "$RPM_CONFIG_FILE")
    if [[ -n "$val" ]]; then
        log_info "  Override libnftnl RPM URL: $(basename "$val")"
        LIBNFTNL_RPM_URL="$val"
    fi

    # --- tar RPM URLs ---
    count=$(jq -r '.tar.rpm_urls | length // 0' "$RPM_CONFIG_FILE" 2>/dev/null || echo "0")
    if [[ "$count" -gt 0 ]]; then
        TAR_RPM_URLS=()
        local i
        for ((i=0; i<count; i++)); do
            val=$(jq -r ".tar.rpm_urls[$i]" "$RPM_CONFIG_FILE")
            TAR_RPM_URLS+=("$val")
        done
        log_info "  Override tar RPM URLs: ${count} entries"
    fi

    # --- unzip RPM URLs ---
    count=$(jq -r '.unzip.rpm_urls | length // 0' "$RPM_CONFIG_FILE" 2>/dev/null || echo "0")
    if [[ "$count" -gt 0 ]]; then
        UNZIP_RPM_URLS=()
        local i
        for ((i=0; i<count; i++)); do
            val=$(jq -r ".unzip.rpm_urls[$i]" "$RPM_CONFIG_FILE")
            UNZIP_RPM_URLS+=("$val")
        done
        log_info "  Override unzip RPM URLs: ${count} entries"
    fi

    # --- zip RPM URLs ---
    count=$(jq -r '.zip.rpm_urls | length // 0' "$RPM_CONFIG_FILE" 2>/dev/null || echo "0")
    if [[ "$count" -gt 0 ]]; then
        ZIP_RPM_URLS=()
        local i
        for ((i=0; i<count; i++)); do
            val=$(jq -r ".zip.rpm_urls[$i]" "$RPM_CONFIG_FILE")
            ZIP_RPM_URLS+=("$val")
        done
        log_info "  Override zip RPM URLs: ${count} entries"
    fi

    log_info "RPM config overrides applied from ${RPM_CONFIG_FILE}"
}

# ============================================================================
# VERSION RESOLUTION — AUTO-DETECT FROM KUBEADM SOURCE
# ============================================================================
resolve_versions_from_kubeadm() {
    if [[ $SKIP_VERSION_RESOLVE -eq 1 ]]; then
        log_warn "Skipping version auto-resolution (--skip-version-resolve)"
        return
    fi

    log_step "Resolving component versions from kubeadm source for ${K8S_VERSION}..."

    local constants_url="https://raw.githubusercontent.com/kubernetes/kubernetes/${K8S_VERSION}/cmd/kubeadm/app/constants/constants.go"
    local constants_file
    constants_file=$(mktemp /tmp/kubeadm_constants.XXXXXX)

    if ! curl -sS -f -o "$constants_file" "$constants_url"; then
        log_warn "Failed to fetch kubeadm constants.go for ${K8S_VERSION}. Using default versions."
        rm -f "$constants_file"
        return
    fi

    # Extract CoreDNS version
    local resolved_coredns
    resolved_coredns=$(grep -oP 'CoreDNSVersion\s*=\s*"v?\K[^"]+' "$constants_file" || true)
    if [[ -n "$resolved_coredns" ]]; then
        COREDNS_VERSION="v${resolved_coredns#v}"
        log_info "  CoreDNS version: ${COREDNS_VERSION}"
    else
        log_warn "  Could not resolve CoreDNS version from kubeadm source"
    fi

    # Extract pause version
    local resolved_pause
    resolved_pause=$(grep -oP 'PauseVersion\s*=\s*"\K[^"]+' "$constants_file" || true)
    if [[ -n "$resolved_pause" ]]; then
        PAUSE_VERSION="${resolved_pause}"
        log_info "  Pause version: ${PAUSE_VERSION}"
    else
        log_warn "  Could not resolve pause version from kubeadm source"
    fi

    # Extract etcd version (from DefaultEtcdVersion or SupportedEtcdVersion map)
    if [[ -z "$ETCD_VERSION" ]]; then
        local resolved_etcd
        resolved_etcd=$(grep -oP 'DefaultEtcdVersion\s*=\s*"\K[^"]+' "$constants_file" || true)
        if [[ -n "$resolved_etcd" ]]; then
            # kubeadm etcd version format: "3.5.16-0" — strip trailing -0
            resolved_etcd="${resolved_etcd%-0}"
            resolved_etcd="${resolved_etcd%-*}"
            # We use a newer external etcd — keep default if set
            log_info "  kubeadm bundled etcd: v${resolved_etcd} (using external: ${DEFAULT_ETCD_VERSION})"
            ETCD_VERSION="${DEFAULT_ETCD_VERSION}"
        else
            ETCD_VERSION="${DEFAULT_ETCD_VERSION}"
        fi
    fi

    rm -f "$constants_file"
}

# Resolve Calico version based on K8s version (from ansible role mapping)
resolve_calico_version() {
    log_step "Resolving Calico version for ${K8S_VERSION}..."

    # Mapping from ansible/roles/kubernetes/tasks/main.yaml
    local k8s_minor
    k8s_minor=$(echo "$K8S_VERSION" | grep -oP 'v\K\d+\.\d+')

    case "$k8s_minor" in
        1.29) CALICO_VERSION="3.26.1" ;;
        1.30) CALICO_VERSION="3.28.2" ;;
        1.31) CALICO_VERSION="3.28.2" ;;
        1.32) CALICO_VERSION="3.29.0" ;;
        1.33) CALICO_VERSION="3.29.0" ;;
        1.34) CALICO_VERSION="3.30.7" ;;
        1.35) CALICO_VERSION="3.31.4" ;;
        *)
            CALICO_VERSION="3.31.4"  # default fallback — use latest known version
            log_warn "Unknown K8s minor version ${k8s_minor}. Defaulting Calico to ${CALICO_VERSION} (latest known)"
            ;;
    esac
    log_info "  Calico version: v${CALICO_VERSION}"
}

# Resolve crictl version to match K8s minor
resolve_crictl_version() {
    if [[ -z "$CRICTL_VERSION" ]]; then
        local k8s_minor
        k8s_minor=$(echo "$K8S_VERSION" | grep -oP 'v\K\d+\.\d+')
        # crictl releases match K8s minor versions
        CRICTL_VERSION="v${k8s_minor}.0"
        log_info "  crictl version: ${CRICTL_VERSION}"
    fi
}

# Set all version defaults that weren't auto-resolved
finalize_versions() {
    [[ -z "$COREDNS_VERSION" ]] && COREDNS_VERSION="v1.11.3" || true
    [[ -z "$PAUSE_VERSION" ]] && PAUSE_VERSION="3.10" || true
    [[ -z "$ETCD_VERSION" ]] && ETCD_VERSION="${DEFAULT_ETCD_VERSION}" || true
    [[ -z "$CALICO_VERSION" ]] && CALICO_VERSION="3.31.4" || true
    [[ -z "$CRICTL_VERSION" ]] && resolve_crictl_version || true
}

print_version_summary() {
    echo ""
    log_step "============ VERSION SUMMARY ============"
    echo "  Kubernetes:  ${K8S_VERSION}"
    echo "  Target OS:   ${TARGET_EL} (RHEL/AlmaLinux/Rocky)"
    echo "  etcd:        ${ETCD_VERSION}"
    echo "  CoreDNS:     ${COREDNS_VERSION}"
    echo "  Pause:       ${PAUSE_VERSION}"
    echo "  Calico:      ${CALICO_VERSION}"
    echo "  Helm:        ${HELM_VERSION}"
    echo "  containerd:  ${CONTAINERD_VERSION}"
    if [[ "$TARGET_EL" == "el8" && "$CONTAINERD_VERSION_EFFECTIVE" != "$CONTAINERD_VERSION" ]]; then
        echo "  containerd (${TARGET_EL}): ${CONTAINERD_VERSION_EFFECTIVE} (el8 max — Docker ended el8 builds)"
    fi
    echo "  crictl:      ${CRICTL_VERSION}"
    echo "  cfssl:       ${CFSSL_VERSION}"
    echo "  yq:          ${YQ_VERSION}"
    log_step "========================================="
    echo ""
}

# ============================================================================
# DOWNLOAD HELPERS
# ============================================================================
download_file() {
    local url="$1"
    local dest="$2"
    local desc="${3:-$(basename "$dest")}"

    if [[ $DRY_RUN -eq 1 ]]; then
        echo "  [DRY-RUN] Would download: ${desc}"
        echo "            URL:  ${url}"
        echo "            Dest: ${dest}"
        return 0
    fi

    if [[ -f "$dest" ]]; then
        log_info "  Already exists: ${desc}"
        return 0
    fi

    log_info "  Downloading: ${desc}..."
    local http_code
    http_code=$(curl -sS -L --connect-timeout 30 --max-time 600 --retry 2 --retry-delay 5 -w "%{http_code}" -o "$dest" "$url" 2>/dev/null || echo "000")

    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 && -f "$dest" && -s "$dest" ]]; then
        log_info "  Downloaded: ${desc} ($(du -h "$dest" | cut -f1))"
        return 0
    else
        log_error "  Failed to download ${desc} (HTTP ${http_code})"
        rm -f "$dest"
        return 1
    fi
}

# ============================================================================
# PHASE 1: BINARIES
# ============================================================================
download_binaries() {
    if [[ $SKIP_BINARIES -eq 1 ]]; then
        log_warn "Skipping binaries (--skip-binaries)"
        return 0
    fi

    log_step "=== PHASE 1: Downloading Binaries ==="

    local bindir="${WORK_DIR}/binaries"
    mkdir -p "$bindir"

    local failed=0
    local total=0

    # --- Kubernetes binaries ---
    log_info "Downloading Kubernetes binaries (${K8S_VERSION})..."
    for bin in kubeadm kubectl kubelet; do
        local url="https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/${ARCH}/${bin}"
        total=$((total + 1))
        download_file "$url" "${bindir}/${bin}" "${bin} ${K8S_VERSION}" || failed=$((failed + 1))
    done
    # Make K8s binaries executable
    [[ $DRY_RUN -eq 0 ]] && chmod +x "${bindir}/kubeadm" "${bindir}/kubectl" "${bindir}/kubelet" 2>/dev/null || true

    # --- etcd binaries ---
    log_info "Downloading etcd (${ETCD_VERSION})..."
    local etcd_tarball="etcd-${ETCD_VERSION}-linux-${ARCH}.tar.gz"
    local etcd_url="https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/${etcd_tarball}"
    local etcd_tmp="${WORK_DIR}/tmp_etcd"
    mkdir -p "$etcd_tmp"

    total=$((total + 1))
    if download_file "$etcd_url" "${etcd_tmp}/${etcd_tarball}" "etcd ${ETCD_VERSION}"; then
        if [[ $DRY_RUN -eq 0 ]]; then
            tar -xzf "${etcd_tmp}/${etcd_tarball}" -C "$etcd_tmp" --strip-components=1
            for bin in etcd etcdctl etcdutl; do
                if [[ -f "${etcd_tmp}/${bin}" ]]; then
                    cp "${etcd_tmp}/${bin}" "${bindir}/${bin}"
                    chmod +x "${bindir}/${bin}"
                    log_info "  Extracted: ${bin}"
                else
                    log_warn "  ${bin} not found in etcd tarball"
                fi
            done
        fi
    else
        failed=$((failed + 1))
    fi
    rm -rf "$etcd_tmp"

    # --- Helm ---
    log_info "Downloading Helm (${HELM_VERSION})..."
    local helm_tarball="helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"
    local helm_url="https://get.helm.sh/${helm_tarball}"
    local helm_tmp="${WORK_DIR}/tmp_helm"
    mkdir -p "$helm_tmp"

    total=$((total + 1))
    if download_file "$helm_url" "${helm_tmp}/${helm_tarball}" "helm ${HELM_VERSION}"; then
        if [[ $DRY_RUN -eq 0 ]]; then
            tar -xzf "${helm_tmp}/${helm_tarball}" -C "$helm_tmp"
            if [[ -f "${helm_tmp}/linux-${ARCH}/helm" ]]; then
                cp "${helm_tmp}/linux-${ARCH}/helm" "${bindir}/helm"
                chmod +x "${bindir}/helm"
                log_info "  Extracted: helm"
            fi
        fi
    else
        failed=$((failed + 1))
    fi
    rm -rf "$helm_tmp"

    # --- crictl ---
    log_info "Downloading crictl (${CRICTL_VERSION})..."
    local crictl_tarball="crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz"
    local crictl_url="https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/${crictl_tarball}"
    local crictl_tmp="${WORK_DIR}/tmp_crictl"
    mkdir -p "$crictl_tmp"

    total=$((total + 1))
    if download_file "$crictl_url" "${crictl_tmp}/${crictl_tarball}" "crictl ${CRICTL_VERSION}"; then
        if [[ $DRY_RUN -eq 0 ]]; then
            tar -xzf "${crictl_tmp}/${crictl_tarball}" -C "$crictl_tmp"
            if [[ -f "${crictl_tmp}/crictl" ]]; then
                cp "${crictl_tmp}/crictl" "${bindir}/crictl"
                chmod +x "${bindir}/crictl"
                log_info "  Extracted: crictl"
            fi
        fi
    else
        failed=$((failed + 1))
    fi
    rm -rf "$crictl_tmp"

    # --- cfssl + cfssljson ---
    log_info "Downloading cfssl (${CFSSL_VERSION})..."
    local cfssl_url="https://github.com/cloudflare/cfssl/releases/download/v${CFSSL_VERSION}/cfssl_${CFSSL_VERSION}_linux_${ARCH}"
    local cfssljson_url="https://github.com/cloudflare/cfssl/releases/download/v${CFSSL_VERSION}/cfssljson_${CFSSL_VERSION}_linux_${ARCH}"
    total=$((total + 1)); download_file "$cfssl_url" "${bindir}/cfssl" "cfssl ${CFSSL_VERSION}" || failed=$((failed + 1))
    total=$((total + 1)); download_file "$cfssljson_url" "${bindir}/cfssljson" "cfssljson ${CFSSL_VERSION}" || failed=$((failed + 1))
    [[ $DRY_RUN -eq 0 ]] && chmod +x "${bindir}/cfssl" "${bindir}/cfssljson" 2>/dev/null || true

    # --- socat (RPM extract → existing bundle → system binary → compile from source) ---
    total=$((total + 1))
    log_info "socat: obtaining binary..."
    if [[ -f "${bindir}/socat" ]]; then
        log_info "  Already exists: socat"
    elif [[ -n "$EXISTING_BUNDLE" && -f "${EXISTING_BUNDLE}/binaries.tar.gz" ]]; then
        log_info "  Extracting socat from existing bundle..."
        if [[ $DRY_RUN -eq 0 ]]; then
            tar -xzf "${EXISTING_BUNDLE}/binaries.tar.gz" -C "${WORK_DIR}" binaries/socat 2>/dev/null && \
                log_info "  Copied socat from existing bundle" || \
                log_warn "  socat not found in existing bundle"
        else
            echo "  [DRY-RUN] Would extract socat from existing bundle"
        fi
    fi
    # Fallback chain if socat still not obtained
    if [[ ! -f "${bindir}/socat" && $DRY_RUN -eq 0 ]]; then
        # Strategy 1: Download socat RPM from AlmaLinux and extract binary
        log_info "  Trying socat RPM from AlmaLinux (${TARGET_EL})..."
        local socat_rpm_urls=("${SOCAT_RPM_URLS[@]}")
        local socat_rpm_ok=0
        for socat_rpm_url in "${socat_rpm_urls[@]}"; do
            local socat_rpm_tmp="${WORK_DIR}/tmp_socat.rpm"
            if download_file "$socat_rpm_url" "$socat_rpm_tmp" "socat RPM"; then
                local socat_extract="${WORK_DIR}/tmp_socat_rpm"
                mkdir -p "$socat_extract"
                (cd "$socat_extract" && rpm2cpio "$socat_rpm_tmp" | cpio -idm 2>/dev/null || true)
                if [[ -f "${socat_extract}/usr/bin/socat" ]]; then
                    cp "${socat_extract}/usr/bin/socat" "${bindir}/socat"
                    chmod +x "${bindir}/socat"
                    log_info "  Extracted socat binary from RPM"
                    socat_rpm_ok=1
                fi
                rm -rf "$socat_extract"
            fi
            rm -f "$socat_rpm_tmp"
            [[ $socat_rpm_ok -eq 1 ]] && break
        done

        # Strategy 2: Copy from system if installed
        if [[ ! -f "${bindir}/socat" ]] && command -v socat &>/dev/null; then
            local sys_socat
            sys_socat=$(command -v socat)
            cp "$sys_socat" "${bindir}/socat"
            chmod +x "${bindir}/socat"
            log_info "  Copied socat from system: ${sys_socat}"
        fi

        # Strategy 3: Compile from source (updated URL — v1.8.0.3)
        if [[ ! -f "${bindir}/socat" ]]; then
            log_info "  Compiling socat 1.8.0.3 from source..."
            local socat_src_dir="${WORK_DIR}/tmp_socat_src"
            mkdir -p "$socat_src_dir"
            local socat_tarball="socat-1.8.0.3.tar.gz"
            local socat_url="http://www.dest-unreach.org/socat/download/${socat_tarball}"
            if download_file "$socat_url" "${socat_src_dir}/${socat_tarball}" "socat source 1.8.0.3"; then
                (
                    cd "$socat_src_dir"
                    tar -xzf "$socat_tarball"
                    cd "socat-1.8.0.3"
                    if command -v gcc &>/dev/null && command -v make &>/dev/null; then
                        ./configure --prefix=/usr 2>&1 | tail -5
                        make -j"$(nproc)" 2>&1 | tail -5
                        if [[ -f socat ]]; then
                            cp socat "${bindir}/socat"
                            chmod +x "${bindir}/socat"
                            log_info "  Compiled socat successfully"
                        else
                            log_warn "  socat compile produced no binary"
                        fi
                    else
                        log_warn "  gcc/make not available. Cannot compile socat."
                    fi
                ) || log_warn "  socat compilation failed"
            else
                log_warn "  Could not download socat source"
            fi
            rm -rf "$socat_src_dir"
        fi

        if [[ ! -f "${bindir}/socat" ]]; then
            log_warn "  FAILED to obtain socat binary via any method"
            failed=$((failed + 1))
        fi
    fi

    # --- keepalived (RPM extract → existing bundle → system binary) ---
    total=$((total + 1))
    log_info "keepalived: obtaining binary..."
    if [[ -f "${bindir}/keepalived" ]]; then
        log_info "  Already exists: keepalived"
    elif [[ -n "$EXISTING_BUNDLE" && -f "${EXISTING_BUNDLE}/binaries.tar.gz" ]]; then
        log_info "  Extracting keepalived from existing bundle..."
        if [[ $DRY_RUN -eq 0 ]]; then
            tar -xzf "${EXISTING_BUNDLE}/binaries.tar.gz" -C "${WORK_DIR}" binaries/keepalived 2>/dev/null && \
                log_info "  Copied keepalived from existing bundle" || \
                log_warn "  keepalived not found in existing bundle"
        else
            echo "  [DRY-RUN] Would extract keepalived from existing bundle"
        fi
    fi
    # Fallback chain if keepalived still not obtained
    if [[ ! -f "${bindir}/keepalived" && $DRY_RUN -eq 0 ]]; then
        # Strategy 1: Download keepalived RPM directly and extract binary (no Phase 3 dependency)
        log_info "  Trying keepalived RPM from AlmaLinux (${TARGET_EL})..."
        local ka_rpm_urls=(
            "${KEEPALIVED_RPM_URL}"
        )
        local ka_rpm_ok=0
        for ka_rpm_url in "${ka_rpm_urls[@]}"; do
            local ka_rpm_tmp="${WORK_DIR}/tmp_keepalived.rpm"
            if download_file "$ka_rpm_url" "$ka_rpm_tmp" "keepalived RPM"; then
                local ka_extract="${WORK_DIR}/tmp_ka_rpm"
                mkdir -p "$ka_extract"
                (cd "$ka_extract" && rpm2cpio "$ka_rpm_tmp" | cpio -idm 2>/dev/null || true)
                if [[ -f "${ka_extract}/usr/sbin/keepalived" ]]; then
                    cp "${ka_extract}/usr/sbin/keepalived" "${bindir}/keepalived"
                    chmod +x "${bindir}/keepalived"
                    log_info "  Extracted keepalived binary from RPM"
                    ka_rpm_ok=1
                fi
                rm -rf "$ka_extract"
            fi
            rm -f "$ka_rpm_tmp"
            [[ $ka_rpm_ok -eq 1 ]] && break
        done

        # Strategy 2: Copy from system if installed
        if [[ ! -f "${bindir}/keepalived" ]] && command -v keepalived &>/dev/null; then
            local sys_ka
            sys_ka=$(command -v keepalived)
            cp "$sys_ka" "${bindir}/keepalived"
            chmod +x "${bindir}/keepalived"
            log_info "  Copied keepalived from system: ${sys_ka}"
        fi

        # Strategy 3: Still defer to packages phase as last resort
        if [[ ! -f "${bindir}/keepalived" ]]; then
            log_info "  Will attempt keepalived extraction from RPM in packages phase"
            NEED_KEEPALIVED_FROM_RPM=1
        fi
    fi

    # --- Create binaries.tar.gz ---
    if [[ $DRY_RUN -eq 0 ]]; then
        log_info "Creating binaries.tar.gz..."
        tar -czf "${OUTPUT_DIR}/binaries.tar.gz" -C "${WORK_DIR}" binaries/
        local size
        size=$(du -h "${OUTPUT_DIR}/binaries.tar.gz" | cut -f1)
        log_info "binaries.tar.gz created (${size})"
    else
        echo "  [DRY-RUN] Would create binaries.tar.gz"
    fi

    if [[ $failed -gt 0 ]]; then
        log_warn "${failed} binary download(s) failed"
    fi

    PHASE1_TOTAL=$((total))
    PHASE1_FAILED=$((failed))
    return $failed
}

# ============================================================================
# PHASE 2: CONTAINER IMAGES
# ============================================================================
download_images() {
    if [[ $SKIP_IMAGES -eq 1 ]]; then
        log_warn "Skipping images (--skip-images)"
        return 0
    fi

    log_step "=== PHASE 2: Downloading Container Images ==="

    local imgdir="${WORK_DIR}/images"
    mkdir -p "$imgdir"

    # Build image list: name -> full_image_ref
    # File naming follows reference convention: registry_image_version.tar.gz
    declare -A IMAGES
    declare -A IMAGE_FILENAMES
    # Kubernetes core images
    IMAGES["kube-apiserver"]="registry.k8s.io/kube-apiserver:${K8S_VERSION}"
    IMAGE_FILENAMES["kube-apiserver"]="registry.k8s.io_kube-apiserver_${K8S_VERSION}.tar.gz"
    IMAGES["kube-controller-manager"]="registry.k8s.io/kube-controller-manager:${K8S_VERSION}"
    IMAGE_FILENAMES["kube-controller-manager"]="registry.k8s.io_kube-controller-manager_${K8S_VERSION}.tar.gz"
    IMAGES["kube-proxy"]="registry.k8s.io/kube-proxy:${K8S_VERSION}"
    IMAGE_FILENAMES["kube-proxy"]="registry.k8s.io_kube-proxy_${K8S_VERSION}.tar.gz"
    IMAGES["kube-scheduler"]="registry.k8s.io/kube-scheduler:${K8S_VERSION}"
    IMAGE_FILENAMES["kube-scheduler"]="registry.k8s.io_kube-scheduler_${K8S_VERSION}.tar.gz"
    IMAGES["pause"]="registry.k8s.io/pause:${PAUSE_VERSION}"
    IMAGE_FILENAMES["pause"]="registry.k8s.io_pause_${PAUSE_VERSION}.tar.gz"
    IMAGES["coredns"]="registry.k8s.io/coredns/coredns:${COREDNS_VERSION}"
    IMAGE_FILENAMES["coredns"]="registry.k8s.io_coredns_${COREDNS_VERSION}.tar.gz"

    # Calico images
    IMAGES["calico-node"]="docker.io/calico/node:v${CALICO_VERSION}"
    IMAGE_FILENAMES["calico-node"]="calico_node_v${CALICO_VERSION}.tar.gz"
    IMAGES["calico-cni"]="docker.io/calico/cni:v${CALICO_VERSION}"
    IMAGE_FILENAMES["calico-cni"]="calico_cni_v${CALICO_VERSION}.tar.gz"
    IMAGES["calico-kube-controllers"]="docker.io/calico/kube-controllers:v${CALICO_VERSION}"
    IMAGE_FILENAMES["calico-kube-controllers"]="calico_kube-controllers_v${CALICO_VERSION}.tar.gz"

    local failed=0
    local total=0

    for name in "${!IMAGES[@]}"; do
        local image="${IMAGES[$name]}"
        local filename="${IMAGE_FILENAMES[$name]}"
        local tarfile="${imgdir}/${filename}"

        total=$((total + 1))

        if [[ $DRY_RUN -eq 1 ]]; then
            echo "  [DRY-RUN] Would pull and save: ${image} -> ${filename}"
            continue
        fi

        if [[ -f "$tarfile" ]]; then
            log_info "  Already exists: ${filename}"
            continue
        fi

        log_info "  Pulling: ${image}..."
        case "${CONTAINER_RUNTIME}" in
            docker)
                if docker pull "$image" 2>&1; then
                    # Save as raw (uncompressed) tar — ctr import does NOT support gzip.
                    # File is named .tar.gz to match reference convention, but content is raw tar.
                    docker save -o "$tarfile" "$image" 2>&1
                    log_info "  Saved: ${filename} ($(du -h "$tarfile" | cut -f1))"
                else
                    log_error "  Failed to pull: ${image}"
                    failed=$((failed + 1))
                fi
                ;;
            skopeo)
                if skopeo copy "docker://${image}" "docker-archive:${tarfile}:${image}" 2>&1; then
                    log_info "  Saved: ${filename} ($(du -h "$tarfile" | cut -f1))"
                else
                    log_error "  Failed to copy: ${image}"
                    failed=$((failed + 1))
                fi
                ;;
            ctr)
                if ctr images pull "$image" 2>&1; then
                    ctr images export "$tarfile" "$image" 2>&1
                    log_info "  Saved: ${filename} ($(du -h "$tarfile" | cut -f1))"
                else
                    log_error "  Failed to pull: ${image}"
                    failed=$((failed + 1))
                fi
                ;;
        esac
    done

    # --- Legacy images note ---
    log_info ""
    log_info "NOTE: Legacy images from existing deployment are NOT downloaded:"
    log_info "  - calico/pod2daemon-flexvol:v3.21.0"
    log_info "  - weaveworks/scope:1.13.2"
    log_info "  - k8s.gcr.io/coredns:1.3.1"
    log_info "  - kubernetes-helm/tiller:v2.16.3"
    log_info "  - coredns-init-container:v1.0.0"
    log_info "These appear to be from older deployments and may not be needed."
    log_info ""

    # --- Create images.tar.gz ---
    if [[ $DRY_RUN -eq 0 ]]; then
        log_info "Creating images.tar.gz..."
        tar -czf "${OUTPUT_DIR}/images.tar.gz" -C "${WORK_DIR}" images/
        local size
        size=$(du -h "${OUTPUT_DIR}/images.tar.gz" | cut -f1)
        log_info "images.tar.gz created (${size})"
    else
        echo "  [DRY-RUN] Would create images.tar.gz"
    fi

    if [[ $failed -gt 0 ]]; then
        log_warn "${failed} image download(s) failed"
    fi

    PHASE2_TOTAL=$((total))
    PHASE2_FAILED=$((failed))
    return $failed
}

# ============================================================================
# PHASE 3: RPM PACKAGES
# ============================================================================
download_packages() {
    if [[ $SKIP_PACKAGES -eq 1 ]]; then
        log_warn "Skipping packages (--skip-packages)"
        return 0
    fi

    log_step "=== PHASE 3: Downloading RPM Packages ==="

    local pkgdir="${WORK_DIR}/packages"
    mkdir -p "$pkgdir"
    mkdir -p "${pkgdir}/keepalivedbundle"

    local failed=0
    local total=0

    # --- containerd RPM ---
    total=$((total + 1))
    log_info "Downloading containerd RPM (${CONTAINERD_VERSION_EFFECTIVE} for ${TARGET_EL})..."
    local containerd_rpm="${CONTAINERD_RPM}"
    local containerd_urls=(
        "${DOCKER_REPO_BASE}/${containerd_rpm}"
        "https://download.docker.com/linux/rhel/${TARGET_EL_MAJOR}/${ARCH_RPM}/stable/Packages/${containerd_rpm}"
    )

    local containerd_downloaded=0
    for url in "${containerd_urls[@]}"; do
        if download_file "$url" "${pkgdir}/${containerd_rpm}" "containerd.io RPM"; then
            containerd_downloaded=1
            break
        fi
    done

    if [[ $containerd_downloaded -eq 0 ]]; then
        log_warn "Could not download containerd RPM with known URL patterns."
        failed=$((failed + 1))
    fi

    # --- Helper: copy RPMs from existing bundle by wildcard ---
    copy_rpms_from_bundle() {
        local pattern="$1"
        local description="$2"
        local copied=0
        if [[ -n "$EXISTING_BUNDLE" && -f "${EXISTING_BUNDLE}/packages.tar.gz" ]]; then
            log_info "  Copying ${description} from existing bundle..."
            if [[ $DRY_RUN -eq 0 ]]; then
                # Use tar to list matching files first, then extract
                local matched
                matched=$(tar -tzf "${EXISTING_BUNDLE}/packages.tar.gz" 2>/dev/null | grep -E "${pattern}" || true)
                if [[ -n "$matched" ]]; then
                    echo "$matched" | while IFS= read -r entry; do
                        tar -xzf "${EXISTING_BUNDLE}/packages.tar.gz" -C "${WORK_DIR}" "$entry" 2>/dev/null || true
                    done
                    copied=$(echo "$matched" | wc -l)
                    log_info "  Copied ${copied} ${description} files from existing bundle"
                else
                    log_warn "  No ${description} found in existing bundle"
                fi
            fi
        fi
        return $copied
    }

    # --- chrony RPMs ---
    total=$((total + 1))
    log_info "Downloading chrony RPMs (${TARGET_EL})..."
    local chrony_downloaded=0
    if [[ "$HOST_OS_EL" == "$TARGET_EL" ]]; then
        # Tier 1: yumdownloader (resolves dependencies automatically)
        if command -v yumdownloader &>/dev/null; then
            log_info "  Using yumdownloader (${TARGET_EL}) for chrony + dependencies..."
            if [[ $DRY_RUN -eq 0 ]]; then
                if yumdownloader --destdir="${pkgdir}" --resolve chrony 2>&1; then
                    chrony_downloaded=1
                else
                    log_warn "  yumdownloader failed for chrony, trying dnf download..."
                fi
            else
                chrony_downloaded=1
            fi
        fi
        # Tier 2: dnf download (available on most el8/el9 systems)
        if [[ $chrony_downloaded -eq 0 ]] && command -v dnf &>/dev/null; then
            log_info "  Using dnf download (${TARGET_EL}) for chrony..."
            if [[ $DRY_RUN -eq 0 ]]; then
                if dnf download --destdir="${pkgdir}" --resolve chrony 2>&1; then
                    chrony_downloaded=1
                else
                    log_warn "  dnf download failed for chrony, falling back to direct URL..."
                fi
            else
                chrony_downloaded=1
            fi
        fi
        # Tier 3: Direct URL download from AlmaLinux mirrors
        if [[ $chrony_downloaded -eq 0 ]]; then
            log_info "  Falling back to direct URL download for chrony ${TARGET_EL} RPM..."
            if [[ $DRY_RUN -eq 0 ]]; then
                for url in "${CHRONY_RPM_URLS[@]}"; do
                    local rpm_name
                    rpm_name=$(basename "$url")
                    if download_file "$url" "${pkgdir}/${rpm_name}" "chrony RPM (${TARGET_EL})"; then
                        chrony_downloaded=1
                        break
                    fi
                done
            else
                chrony_downloaded=1
            fi
        fi
    elif [[ -n "$EXISTING_BUNDLE" && -f "${EXISTING_BUNDLE}/packages.tar.gz" ]]; then
        log_info "  Host OS (${HOST_OS_EL}) != target (${TARGET_EL}). Copying chrony RPMs from existing bundle..."
        if [[ $DRY_RUN -eq 0 ]]; then
            tar -xzf "${EXISTING_BUNDLE}/packages.tar.gz" -C "${WORK_DIR}" --wildcards 'packages/chrony-*' 2>/dev/null && \
                { log_info "  Copied chrony RPMs from existing bundle"; chrony_downloaded=1; } || \
                log_warn "  Could not extract chrony RPMs from existing bundle"
        fi
    else
        # Host OS != target, no existing bundle — download from AlmaLinux mirror for target OS
        log_info "  Downloading chrony ${TARGET_EL} RPM from AlmaLinux mirror..."
        for url in "${CHRONY_RPM_URLS[@]}"; do
            local rpm_name
            rpm_name=$(basename "$url")
            if download_file "$url" "${pkgdir}/${rpm_name}" "chrony RPM (${TARGET_EL})"; then
                chrony_downloaded=1
                break
            fi
        done
    fi
    if [[ $chrony_downloaded -eq 0 && $DRY_RUN -eq 0 ]]; then
        log_warn "  WARNING: All methods failed for chrony RPM download! chrony may already be on target nodes."
        failed=$((failed + 1))
    fi

    # --- keepalived RPMs + all perl dependencies ---
    total=$((total + 1))
    log_info "Downloading keepalived RPMs + dependencies (${TARGET_EL})..."
    local keepalived_downloaded=0
    if [[ "$HOST_OS_EL" == "$TARGET_EL" ]]; then
        # Tier 1: yumdownloader (resolves all dependencies automatically)
        if command -v yumdownloader &>/dev/null; then
            log_info "  Using yumdownloader (${TARGET_EL}) for keepalived + ALL dependencies..."
            if [[ $DRY_RUN -eq 0 ]]; then
                if yumdownloader --destdir="${pkgdir}" --resolve keepalived 2>&1; then
                    keepalived_downloaded=1
                else
                    log_warn "  yumdownloader failed for keepalived, trying dnf download..."
                fi
            else
                keepalived_downloaded=1
            fi
        fi
        # Tier 2: dnf download
        if [[ $keepalived_downloaded -eq 0 ]] && command -v dnf &>/dev/null; then
            log_info "  Using dnf download (${TARGET_EL}) for keepalived..."
            if [[ $DRY_RUN -eq 0 ]]; then
                if dnf download --destdir="${pkgdir}" --resolve keepalived 2>&1; then
                    keepalived_downloaded=1
                else
                    log_warn "  dnf download failed for keepalived, falling back to direct URL..."
                fi
            else
                keepalived_downloaded=1
            fi
        fi
        # Tier 3: Direct URL download from AlmaLinux mirrors
        if [[ $keepalived_downloaded -eq 0 ]]; then
            log_info "  Falling back to direct URL download for keepalived ${TARGET_EL} RPMs..."
            if [[ $DRY_RUN -eq 0 ]]; then
                # Core keepalived RPMs (from setup_rpm_tables)
                local ka_core_ok=0
                for url in "${KA_CORE_RPMS[@]}"; do
                    local rpm_name
                    rpm_name=$(basename "$url")
                    if download_file "$url" "${pkgdir}/${rpm_name}" "${rpm_name}"; then
                        ka_core_ok=1
                    fi
                done

                # Perl dependency RPMs (from setup_rpm_tables)
                local perl_dl=0
                local perl_fl=0
                for rpm_name in "${PERL_RPMS[@]}"; do
                    if download_file "${PERL_RPM_BASE}/${rpm_name}" "${pkgdir}/${rpm_name}" "${rpm_name}"; then
                        perl_dl=$((perl_dl + 1))
                    else
                        # Try AppStream as fallback
                        if download_file "${PERL_RPM_APPSTREAM}/${rpm_name}" "${pkgdir}/${rpm_name}" "${rpm_name}"; then
                            perl_dl=$((perl_dl + 1))
                        else
                            perl_fl=$((perl_fl + 1))
                            log_debug "  Could not download: ${rpm_name}"
                        fi
                    fi
                done
                log_info "  Direct URL fallback: ${perl_dl} perl RPMs downloaded (${perl_fl} failed)"
                [[ $ka_core_ok -eq 1 ]] && keepalived_downloaded=1
            else
                keepalived_downloaded=1
            fi
        fi
    elif [[ -n "$EXISTING_BUNDLE" && -f "${EXISTING_BUNDLE}/packages.tar.gz" ]]; then
        log_info "  Host OS (${HOST_OS_EL}) != target (${TARGET_EL}). Copying keepalived RPMs from existing bundle..."
        if [[ $DRY_RUN -eq 0 ]]; then
            tar -xzf "${EXISTING_BUNDLE}/packages.tar.gz" -C "${WORK_DIR}" --wildcards \
                'packages/keepalived-*' 'packages/perl-*' 'packages/net-snmp-*' \
                'packages/libseccomp-*' 'packages/lm_sensors-*' 'packages/mariadb-*' \
                2>/dev/null && \
                { log_info "  Copied keepalived + dependency RPMs from existing bundle"; keepalived_downloaded=1; } || \
                log_warn "  Could not extract all keepalived RPMs from existing bundle"
        fi
    else
        # Download keepalived RPMs from AlmaLinux mirrors for target OS
        log_info "  Downloading keepalived ${TARGET_EL} RPMs from AlmaLinux mirrors..."
        if [[ $DRY_RUN -eq 0 ]]; then
            # Core keepalived RPMs (from setup_rpm_tables)
            for url in "${KA_CORE_RPMS[@]}"; do
                local rpm_name
                rpm_name=$(basename "$url")
                download_file "$url" "${pkgdir}/${rpm_name}" "${rpm_name}" || true
            done

            # Perl dependency RPMs (from setup_rpm_tables)
            local perl_downloaded=0
            local perl_failed=0
            for rpm_name in "${PERL_RPMS[@]}"; do
                if download_file "${PERL_RPM_BASE}/${rpm_name}" "${pkgdir}/${rpm_name}" "${rpm_name}"; then
                    perl_downloaded=$((perl_downloaded + 1))
                else
                    # Try AppStream as fallback
                    if download_file "${PERL_RPM_APPSTREAM}/${rpm_name}" "${pkgdir}/${rpm_name}" "${rpm_name}"; then
                        perl_downloaded=$((perl_downloaded + 1))
                    else
                        perl_failed=$((perl_failed + 1))
                        log_debug "  Could not download: ${rpm_name}"
                    fi
                fi
            done
            log_info "  Downloaded ${perl_downloaded} perl RPMs (${perl_failed} failed)"
            keepalived_downloaded=1
        fi
    fi
    if [[ $keepalived_downloaded -eq 0 && $DRY_RUN -eq 0 ]]; then
        log_warn "  WARNING: All methods failed for keepalived RPM download! This is critical — keepalived is required for HA."
        failed=$((failed + 1))
    fi

    # --- keepalivedbundle shared libraries ---
    log_info "keepalivedbundle/ shared libraries..."
    if [[ -n "$EXISTING_BUNDLE" && -f "${EXISTING_BUNDLE}/packages.tar.gz" ]]; then
        log_info "  Extracting keepalivedbundle/ from existing bundle..."
        if [[ $DRY_RUN -eq 0 ]]; then
            tar -xzf "${EXISTING_BUNDLE}/packages.tar.gz" -C "${WORK_DIR}" --wildcards 'packages/keepalivedbundle/*' 2>/dev/null && \
                log_info "  Copied keepalivedbundle/ from existing bundle ($(ls "${pkgdir}/keepalivedbundle/" 2>/dev/null | wc -l) files)" || \
                log_warn "  keepalivedbundle/ not found in existing bundle"
        fi
    elif [[ $DRY_RUN -eq 0 ]]; then
        # Extract shared libs from the keepalived RPM we just downloaded
        local ka_rpm_file
        ka_rpm_file=$(find "${pkgdir}" -maxdepth 1 -name "keepalived-*.rpm" 2>/dev/null | head -1)
        if [[ -n "$ka_rpm_file" && -f "$ka_rpm_file" ]]; then
            log_info "  Extracting shared libs from keepalived RPM..."
            local rpm_extract_dir="${WORK_DIR}/tmp_rpm_extract"
            mkdir -p "$rpm_extract_dir"
            (
                cd "$rpm_extract_dir"
                rpm2cpio "$ka_rpm_file" | cpio -idm 2>/dev/null || true
            )
            # The keepalived binary is inside the RPM at usr/sbin/keepalived
            if [[ -f "${rpm_extract_dir}/usr/sbin/keepalived" ]]; then
                cp "${rpm_extract_dir}/usr/sbin/keepalived" "${WORK_DIR}/binaries/keepalived" 2>/dev/null || true
                chmod +x "${WORK_DIR}/binaries/keepalived" 2>/dev/null || true
                log_info "  Extracted keepalived binary from RPM"
                NEED_KEEPALIVED_FROM_RPM=0
            fi
            rm -rf "$rpm_extract_dir"
        fi

        # For shared libs, we need them from a matching ${TARGET_EL} system — try to extract from the RPMs
        # that we downloaded (net-snmp-libs, lm_sensors-libs, perl-libs, etc.)
        local libdir="${pkgdir}/keepalivedbundle"
        local libs_extracted=0
        local lib_rpms_to_extract=(
            "net-snmp-libs"
            "net-snmp-agent-libs"
            "lm_sensors-libs"
        )
        for lib_rpm_pattern in "${lib_rpms_to_extract[@]}"; do
            local lib_rpm
            lib_rpm=$(find "${pkgdir}" -maxdepth 1 -name "${lib_rpm_pattern}*.rpm" 2>/dev/null | head -1)
            if [[ -n "$lib_rpm" && -f "$lib_rpm" ]]; then
                local extract_tmp="${WORK_DIR}/tmp_lib_extract"
                mkdir -p "$extract_tmp"
                (
                    cd "$extract_tmp"
                    rpm2cpio "$lib_rpm" | cpio -idm 2>/dev/null || true
                )
                # Copy all .so files
                find "$extract_tmp" -name "*.so*" -type f 2>/dev/null | while IFS= read -r so_file; do
                    local so_name
                    so_name=$(basename "$so_file")
                    cp "$so_file" "${libdir}/${so_name}"
                    libs_extracted=$((libs_extracted + 1))
                done
                rm -rf "$extract_tmp"
            fi
        done

        # Also need libperl, librpm, librpmio, libnftnl, libssl, libcrypto
        # These come from perl-libs, rpm-libs, libnftnl, openssl-libs
        local extra_lib_rpms=("perl-libs" "rpm-libs")
        for lib_rpm_pattern in "${extra_lib_rpms[@]}"; do
            local lib_rpm
            lib_rpm=$(find "${pkgdir}" -maxdepth 1 -name "${lib_rpm_pattern}*.rpm" 2>/dev/null | head -1)
            if [[ -n "$lib_rpm" && -f "$lib_rpm" ]]; then
                local extract_tmp="${WORK_DIR}/tmp_lib_extract"
                mkdir -p "$extract_tmp"
                (
                    cd "$extract_tmp"
                    rpm2cpio "$lib_rpm" | cpio -idm 2>/dev/null || true
                )
                find "$extract_tmp" -name "*.so*" -type f 2>/dev/null | while IFS= read -r so_file; do
                    local so_name
                    so_name=$(basename "$so_file")
                    cp "$so_file" "${libdir}/${so_name}"
                done
                rm -rf "$extract_tmp"
            fi
        done

        # Download remaining critical shared libs directly from AlmaLinux if not yet present
        # These are system libs that may not be in the RPMs we downloaded
        local missing_lib_rpms=()
        if [[ ! -f "${libdir}/libnftnl.so.11.6.0" && ! -f "${libdir}/libnftnl.so.11" ]]; then
            missing_lib_rpms+=("${LIBNFTNL_RPM_URL}")
        fi

        for url in "${missing_lib_rpms[@]}"; do
            local rpm_name
            rpm_name=$(basename "$url")
            local tmp_rpm="${WORK_DIR}/tmp_${rpm_name}"
            if download_file "$url" "$tmp_rpm" "${rpm_name}"; then
                local extract_tmp="${WORK_DIR}/tmp_lib_extract"
                mkdir -p "$extract_tmp"
                (
                    cd "$extract_tmp"
                    rpm2cpio "$tmp_rpm" | cpio -idm 2>/dev/null || true
                )
                find "$extract_tmp" -name "*.so*" -type f 2>/dev/null | while IFS= read -r so_file; do
                    local so_name
                    so_name=$(basename "$so_file")
                    cp "$so_file" "${libdir}/${so_name}"
                done
                rm -rf "$extract_tmp"
            fi
            rm -f "$tmp_rpm"
        done

        local lib_count
        lib_count=$(find "${libdir}" -type f 2>/dev/null | wc -l)
        if [[ "$lib_count" -gt 0 ]]; then
            log_info "  keepalivedbundle/ has ${lib_count} shared library files"
        else
            log_warn "  keepalivedbundle/ is still empty. Some libs may need to come from a ${TARGET_EL} system."
        fi
    fi

    # --- Extract keepalived binary from RPM if deferred from binaries phase ---
    if [[ "${NEED_KEEPALIVED_FROM_RPM:-0}" -eq 1 && $DRY_RUN -eq 0 ]]; then
        local ka_rpm_file
        ka_rpm_file=$(find "${pkgdir}" -maxdepth 1 -name "keepalived-*.rpm" 2>/dev/null | head -1)
        if [[ -n "$ka_rpm_file" && -f "$ka_rpm_file" ]]; then
            log_info "  Extracting keepalived binary from RPM..."
            local rpm_extract_dir="${WORK_DIR}/tmp_rpm_ka"
            mkdir -p "$rpm_extract_dir"
            (
                cd "$rpm_extract_dir"
                rpm2cpio "$ka_rpm_file" | cpio -idm 2>/dev/null || true
            )
            if [[ -f "${rpm_extract_dir}/usr/sbin/keepalived" ]]; then
                cp "${rpm_extract_dir}/usr/sbin/keepalived" "${WORK_DIR}/binaries/keepalived"
                chmod +x "${WORK_DIR}/binaries/keepalived"
                log_info "  Extracted keepalived binary from RPM"
                # Re-create binaries.tar.gz with keepalived included
                log_info "  Updating binaries.tar.gz to include keepalived..."
                tar -czf "${OUTPUT_DIR}/binaries.tar.gz" -C "${WORK_DIR}" binaries/
                log_info "  binaries.tar.gz updated ($(du -h "${OUTPUT_DIR}/binaries.tar.gz" | cut -f1))"
            else
                log_warn "  keepalived binary not found in RPM"
            fi
            rm -rf "$rpm_extract_dir"
        else
            log_warn "  No keepalived RPM found to extract binary from"
        fi
    fi

    # --- Create packages.tar.gz ---
    if [[ $DRY_RUN -eq 0 ]]; then
        log_info "Creating packages.tar.gz..."
        tar -czf "${OUTPUT_DIR}/packages.tar.gz" -C "${WORK_DIR}" packages/
        local size
        size=$(du -h "${OUTPUT_DIR}/packages.tar.gz" | cut -f1)
        log_info "packages.tar.gz created (${size})"
    else
        echo "  [DRY-RUN] Would create packages.tar.gz"
    fi

    if [[ $failed -gt 0 ]]; then
        log_warn "${failed} package download(s) failed"
    fi

    PHASE3_TOTAL=$((total))
    PHASE3_FAILED=$((failed))
    return $failed
}

# ============================================================================
# PHASE 4: OTHER FILES
# ============================================================================
download_other_files() {
    if [[ $SKIP_OTHER -eq 1 ]]; then
        log_warn "Skipping other files (--skip-other)"
        return 0
    fi

    log_step "=== PHASE 4: Downloading other/ Files ==="

    local otherdir="${OUTPUT_DIR}/other"
    local cisdir="${otherdir}/cis_hardening_scripts"
    mkdir -p "$cisdir"

    local failed=0
    local total=0

    # --- tar/unzip/zip RPMs ---
    total=$((total + 1))
    log_info "Downloading system RPMs (tar, unzip, zip) for other/ (${TARGET_EL})..."

    local sysrpms_downloaded=0
    if [[ "$HOST_OS_EL" == "$TARGET_EL" ]]; then
        # Tier 1: yumdownloader
        if command -v yumdownloader &>/dev/null; then
            log_info "  Using yumdownloader (${TARGET_EL}) for tar, unzip, zip..."
            if [[ $DRY_RUN -eq 0 ]]; then
                if yumdownloader --destdir="${otherdir}" tar unzip zip 2>&1; then
                    sysrpms_downloaded=1
                else
                    log_warn "  yumdownloader failed for tar/unzip/zip RPMs, trying dnf download..."
                fi
            else
                sysrpms_downloaded=1
            fi
        fi
        # Tier 2: dnf download
        if [[ $sysrpms_downloaded -eq 0 ]] && command -v dnf &>/dev/null; then
            log_info "  Using dnf download (${TARGET_EL}) for tar, unzip, zip..."
            if [[ $DRY_RUN -eq 0 ]]; then
                if dnf download --destdir="${otherdir}" tar unzip zip 2>&1; then
                    sysrpms_downloaded=1
                else
                    log_warn "  dnf download failed for tar/unzip/zip RPMs, falling back to direct URL..."
                fi
            else
                sysrpms_downloaded=1
            fi
        fi
        # Tier 3: Direct URL download from AlmaLinux mirrors
        if [[ $sysrpms_downloaded -eq 0 ]]; then
            log_info "  Falling back to direct URL download for tar/unzip/zip ${TARGET_EL} RPMs..."
            if [[ $DRY_RUN -eq 0 ]]; then
                local tar_ok=0
                for tar_url in "${TAR_RPM_URLS[@]}"; do
                    local tar_rpm_name
                    tar_rpm_name=$(basename "$tar_url")
                    if download_file "$tar_url" "${otherdir}/${tar_rpm_name}" "tar RPM (${TARGET_EL})"; then
                        tar_ok=1
                        break
                    fi
                done
                [[ $tar_ok -eq 0 ]] && log_warn "  Could not download tar RPM from AlmaLinux mirrors" && failed=$((failed + 1))

                local unzip_ok=0
                for unzip_url in "${UNZIP_RPM_URLS[@]}"; do
                    local unzip_rpm_name
                    unzip_rpm_name=$(basename "$unzip_url")
                    if download_file "$unzip_url" "${otherdir}/${unzip_rpm_name}" "unzip RPM (${TARGET_EL})"; then
                        unzip_ok=1
                        break
                    fi
                done
                [[ $unzip_ok -eq 0 ]] && log_warn "  Could not download unzip RPM from AlmaLinux mirrors" && failed=$((failed + 1))

                local zip_ok=0
                for zip_url in "${ZIP_RPM_URLS[@]}"; do
                    local zip_rpm_name
                    zip_rpm_name=$(basename "$zip_url")
                    if download_file "$zip_url" "${otherdir}/${zip_rpm_name}" "zip RPM (${TARGET_EL})"; then
                        zip_ok=1
                        break
                    fi
                done
                [[ $zip_ok -eq 0 ]] && log_warn "  Could not download zip RPM from AlmaLinux mirrors" && failed=$((failed + 1))
                # Consider it downloaded if at least tar succeeded (critical one)
                [[ $tar_ok -eq 1 ]] && sysrpms_downloaded=1
            else
                sysrpms_downloaded=1
            fi
        fi
    elif [[ -n "$EXISTING_BUNDLE" ]]; then
        # Host OS != target — copy from existing bundle
        log_info "  Host OS (${HOST_OS_EL}) != target (${TARGET_EL}). Copying RPMs from existing bundle..."
        if [[ $DRY_RUN -eq 0 ]]; then
            local copied=0
            while IFS= read -r rpm_file; do
                cp "$rpm_file" "${otherdir}/"
                log_info "  Copied: $(basename "$rpm_file")"
                copied=$((copied + 1))
            done < <(find "${EXISTING_BUNDLE}/other/" -maxdepth 1 -name "*.rpm" -type f 2>/dev/null)
            if [[ $copied -eq 0 ]]; then
                log_warn "  No RPMs found in existing bundle's other/ directory."
            else
                sysrpms_downloaded=1
            fi
        else
            echo "  [DRY-RUN] Would copy RPMs from existing bundle's other/"
        fi
    else
        # Not matching host and no existing bundle — download from AlmaLinux mirrors for target OS
        log_info "  Host OS (${HOST_OS_EL:-unknown}) != target (${TARGET_EL}). Downloading ${TARGET_EL} RPMs from AlmaLinux mirrors..."
        if [[ $DRY_RUN -eq 0 ]]; then
            # tar RPM — try multiple known versions
            local tar_ok=0
            for tar_url in "${TAR_RPM_URLS[@]}"; do
                local tar_rpm_name
                tar_rpm_name=$(basename "$tar_url")
                if download_file "$tar_url" "${otherdir}/${tar_rpm_name}" "tar RPM (${TARGET_EL})"; then
                    tar_ok=1
                    break
                fi
            done
            [[ $tar_ok -eq 0 ]] && log_warn "  Could not download tar RPM from AlmaLinux mirrors" && failed=$((failed + 1))

            # unzip RPM
            local unzip_ok=0
            for unzip_url in "${UNZIP_RPM_URLS[@]}"; do
                local unzip_rpm_name
                unzip_rpm_name=$(basename "$unzip_url")
                if download_file "$unzip_url" "${otherdir}/${unzip_rpm_name}" "unzip RPM (${TARGET_EL})"; then
                    unzip_ok=1
                    break
                fi
            done
            [[ $unzip_ok -eq 0 ]] && log_warn "  Could not download unzip RPM from AlmaLinux mirrors" && failed=$((failed + 1))

            # zip RPM
            local zip_ok=0
            for zip_url in "${ZIP_RPM_URLS[@]}"; do
                local zip_rpm_name
                zip_rpm_name=$(basename "$zip_url")
                if download_file "$zip_url" "${otherdir}/${zip_rpm_name}" "zip RPM (${TARGET_EL})"; then
                    zip_ok=1
                    break
                fi
            done
            [[ $zip_ok -eq 0 ]] && log_warn "  Could not download zip RPM from AlmaLinux mirrors" && failed=$((failed + 1))
        fi
    fi
    if [[ $sysrpms_downloaded -eq 0 && $DRY_RUN -eq 0 ]]; then
        log_warn "  WARNING: All methods failed for tar/unzip/zip RPM downloads!"
        failed=$((failed + 1))
    fi

    # --- yq ---
    total=$((total + 1))
    log_info "Downloading yq (${YQ_VERSION})..."
    local yq_url="https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${ARCH}"
    download_file "$yq_url" "${cisdir}/yq_linux_${ARCH}" "yq ${YQ_VERSION}" || failed=$((failed + 1))
    [[ $DRY_RUN -eq 0 ]] && chmod +x "${cisdir}/yq_linux_${ARCH}" 2>/dev/null || true

    # --- cfssl + cfssljson in other/ (required by etcd role: ../other/cfssl) ---
    log_info "Placing cfssl + cfssljson in other/ (required by etcd role)..."
    local cfssl_url="https://github.com/cloudflare/cfssl/releases/download/v${CFSSL_VERSION}/cfssl_${CFSSL_VERSION}_linux_${ARCH}"
    local cfssljson_url="https://github.com/cloudflare/cfssl/releases/download/v${CFSSL_VERSION}/cfssljson_${CFSSL_VERSION}_linux_${ARCH}"
    total=$((total + 1)); download_file "$cfssl_url" "${otherdir}/cfssl" "cfssl ${CFSSL_VERSION} (other/)" || failed=$((failed + 1))
    total=$((total + 1)); download_file "$cfssljson_url" "${otherdir}/cfssljson" "cfssljson ${CFSSL_VERSION} (other/)" || failed=$((failed + 1))
    [[ $DRY_RUN -eq 0 ]] && chmod +x "${otherdir}/cfssl" "${otherdir}/cfssljson" 2>/dev/null || true

    # --- Calico manifest in other/calico/ ---
    total=$((total + 1))
    log_info "Downloading Calico v${CALICO_VERSION} manifest..."
    local calico_dir="${otherdir}/calico"
    mkdir -p "$calico_dir"
    local calico_manifest_url="https://raw.githubusercontent.com/projectcalico/calico/v${CALICO_VERSION}/manifests/calico.yaml"
    download_file "$calico_manifest_url" "${calico_dir}/calico_v${CALICO_VERSION}.yml" "calico v${CALICO_VERSION} manifest" || {
        # Fallback to older URL pattern
        calico_manifest_url="https://docs.projectcalico.org/v${CALICO_VERSION%.*}/manifests/calico.yaml"
        download_file "$calico_manifest_url" "${calico_dir}/calico_v${CALICO_VERSION}.yml" "calico v${CALICO_VERSION} manifest (fallback)" || failed=$((failed + 1))
    }

    # --- CIS hardening scripts ---
    log_info "CIS hardening scripts..."
    log_info "  cis_harden_master.sh, cis_harden_node.sh, cis_ca.cnf, etc."
    log_info "  These are custom scripts — NOT downloadable from the internet."
    log_info "  They should already exist in the K8s Automation_Ansible git repository."

    for script in cis_harden_master.sh cis_harden_node.sh cis_ca.cnf cis_ca_worker.cnf index.txt serial.txt; do
        if [[ ! -f "${cisdir}/${script}" ]]; then
            log_warn "  Missing: ${cisdir}/${script} (should come from git repo)"
        else
            log_info "  Found: ${script}"
        fi
    done

    # --- CRITICAL: Verify RPMs exist in other/ (ansible prerequisite check will fail without them) ---
    total=$((total + 1))
    local rpm_count
    rpm_count=$(find "${otherdir}" -maxdepth 1 -name "*.rpm" -type f 2>/dev/null | wc -l)
    if [[ $DRY_RUN -eq 0 && "$rpm_count" -eq 0 ]]; then
        log_error "============================================================"
        log_error "CRITICAL: No RPM packages found in ${otherdir}/"
        log_error "The ansible prerequisite check WILL FAIL without tar/unzip/zip RPMs."
        log_error ""
        log_error "Fix: Re-run with --existing-bundle pointing to an existing deployment:"
        log_error "  $0 --k8s-version ${K8S_VERSION} --output-dir ${OUTPUT_DIR} \\"
        log_error "    --existing-bundle /path/to/existing/K8s Automation_Ansible"
        log_error "============================================================"
        failed=$((failed + 1))
    elif [[ $DRY_RUN -eq 0 ]]; then
        log_info "Verified: ${rpm_count} RPM(s) in other/ directory"
    fi

    if [[ $failed -gt 0 ]]; then
        log_warn "${failed} other file download(s) failed"
    fi

    PHASE4_TOTAL=$((total))
    PHASE4_FAILED=$((failed))
    return $failed
}

# ============================================================================
# PHASE 5: UPDATE k8s_version_constants.json
# ============================================================================
update_version_constants() {
    log_step "=== PHASE 5: Updating k8s_version_constants.json ==="

    local constants_file="${OUTPUT_DIR}/ansible/k8s_version_constants.json"

    if [[ ! -f "$constants_file" ]]; then
        log_warn "k8s_version_constants.json not found at ${constants_file}"
        log_info "Creating new k8s_version_constants.json..."

        if [[ $DRY_RUN -eq 0 ]]; then
            cat > "$constants_file" <<JSONEOF
{
    "k8s_version": "${K8S_VERSION}",
    "etcd_version": "${ETCD_VERSION}",
    "helm_version": "${HELM_VERSION}",
    "containerd_version": "v${CONTAINERD_VERSION}",
    "calico_version": "v${CALICO_VERSION}",
    "socat_version": "${DEFAULT_SOCAT_VERSION}",
    "keepalived_version": "${DEFAULT_KEEPALIVED_VERSION}"
}
JSONEOF
            log_info "Created k8s_version_constants.json"
        else
            echo "  [DRY-RUN] Would create k8s_version_constants.json"
        fi
        return 0
    fi

    if [[ $DRY_RUN -eq 0 ]]; then
        log_info "Updating existing k8s_version_constants.json..."
        local tmp
        tmp=$(mktemp)
        jq \
            --arg k8s "${K8S_VERSION}" \
            --arg etcd "${ETCD_VERSION}" \
            --arg helm "${HELM_VERSION}" \
            --arg containerd "v${CONTAINERD_VERSION}" \
            --arg calico "v${CALICO_VERSION}" \
            '.k8s_version = $k8s | .etcd_version = $etcd | .helm_version = $helm | .containerd_version = $containerd | .calico_version = $calico' \
            "$constants_file" > "$tmp"
        mv "$tmp" "$constants_file"
        log_info "Updated k8s_version_constants.json:"
        cat "$constants_file"
    else
        echo "  [DRY-RUN] Would update k8s_version_constants.json with:"
        echo "    k8s_version: ${K8S_VERSION}"
        echo "    etcd_version: ${ETCD_VERSION}"
        echo "    helm_version: ${HELM_VERSION}"
        echo "    containerd_version: v${CONTAINERD_VERSION}"
        echo "    calico_version: v${CALICO_VERSION}"
    fi
}

# ============================================================================
# MANIFEST — Write a manifest of what was downloaded
# ============================================================================
write_manifest() {
    log_step "=== Writing Download Manifest ==="

    local manifest="${OUTPUT_DIR}/download_manifest.json"

    if [[ $DRY_RUN -eq 1 ]]; then
        echo "  [DRY-RUN] Would write manifest to ${manifest}"
        return 0
    fi

    cat > "$manifest" <<MANIFESTEOF
{
    "download_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "script_version": "${SCRIPT_VERSION}",
    "kubernetes_version": "${K8S_VERSION}",
    "target_os": "${TARGET_EL}",
    "rpm_config_file": "${RPM_CONFIG_FILE:-none}",
    "components": {
        "etcd": "${ETCD_VERSION}",
        "coredns": "${COREDNS_VERSION}",
        "pause": "${PAUSE_VERSION}",
        "calico": "${CALICO_VERSION}",
        "helm": "${HELM_VERSION}",
        "containerd": "${CONTAINERD_VERSION_EFFECTIVE}",
        "crictl": "${CRICTL_VERSION}",
        "cfssl": "${CFSSL_VERSION}",
        "yq": "${YQ_VERSION}"
    },
    "archives": {
        "binaries": "binaries.tar.gz",
        "images": "images.tar.gz",
        "packages": "packages.tar.gz"
    },
    "other_files": {
        "cfssl": "other/cfssl",
        "cfssljson": "other/cfssljson",
        "calico_manifest": "other/calico/calico_v${CALICO_VERSION}.yml",
        "yq": "other/cis_hardening_scripts/yq_linux_${ARCH}"
    },
    "container_images": [
        "registry.k8s.io/kube-apiserver:${K8S_VERSION}",
        "registry.k8s.io/kube-controller-manager:${K8S_VERSION}",
        "registry.k8s.io/kube-proxy:${K8S_VERSION}",
        "registry.k8s.io/kube-scheduler:${K8S_VERSION}",
        "registry.k8s.io/pause:${PAUSE_VERSION}",
        "registry.k8s.io/coredns/coredns:${COREDNS_VERSION}",
        "docker.io/calico/node:v${CALICO_VERSION}",
        "docker.io/calico/cni:v${CALICO_VERSION}",
        "docker.io/calico/kube-controllers:v${CALICO_VERSION}"
    ]
}
MANIFESTEOF

    log_info "Manifest written to ${manifest}"
}

# ============================================================================
# SUMMARY
# ============================================================================
print_summary() {
    local overall_rc=0

    # Phase 4 failures are fatal (Ansible requires other/ RPMs)
    if [[ $PHASE4_FAILED -gt 0 ]]; then
        overall_rc=1
    elif [[ $((PHASE1_FAILED + PHASE2_FAILED + PHASE3_FAILED)) -gt 0 ]]; then
        overall_rc=2
    fi

    local p1_status p2_status p3_status p4_status
    [[ $PHASE1_FAILED -eq 0 ]] && p1_status="${GREEN}✓${NC}" || p1_status="${RED}✗${NC}"
    [[ $PHASE2_FAILED -eq 0 ]] && p2_status="${GREEN}✓${NC}" || p2_status="${RED}✗${NC}"
    [[ $PHASE3_FAILED -eq 0 ]] && p3_status="${GREEN}✓${NC}" || p3_status="${RED}✗${NC}"
    [[ $PHASE4_FAILED -eq 0 ]] && p4_status="${GREEN}✓${NC}" || p4_status="${RED}✗${NC}"

    echo ""
    echo -e "╔════════════════════════════════════════════╗"
    echo -e "║      kubecargo-ai  Download Summary        ║"
    echo -e "╠════════════════════════════════════════════╣"
    printf  "║ Phase 1 — Binaries   %b  %2d/%2d downloaded     ║\n" "$p1_status" "$((PHASE1_TOTAL - PHASE1_FAILED))" "$PHASE1_TOTAL"
    printf  "║ Phase 2 — Images     %b  %2d/%2d downloaded     ║\n" "$p2_status" "$((PHASE2_TOTAL - PHASE2_FAILED))" "$PHASE2_TOTAL"
    printf  "║ Phase 3 — Packages   %b  %2d/%2d downloaded     ║\n" "$p3_status" "$((PHASE3_TOTAL - PHASE3_FAILED))" "$PHASE3_TOTAL"
    printf  "║ Phase 4 — Other      %b  %2d/%2d downloaded     ║\n" "$p4_status" "$((PHASE4_TOTAL - PHASE4_FAILED))" "$PHASE4_TOTAL"
    echo -e "╠════════════════════════════════════════════╣"
    if [[ $overall_rc -eq 0 ]]; then
        echo -e "║ ${GREEN}Exit 0: All downloads successful${NC}            ║"
    elif [[ $overall_rc -eq 1 ]]; then
        echo -e "║ ${RED}Exit 1: CRITICAL — Phase 4 failures${NC}        ║"
    else
        echo -e "║ ${YELLOW}Exit 2: Partial failure (non-critical)${NC}     ║"
    fi
    echo -e "╚════════════════════════════════════════════╝"

    return $overall_rc
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    echo ""
    echo "============================================================"
    echo "  K8s Automation K8s Offline Downloader v${SCRIPT_VERSION}"
    echo "============================================================"
    echo ""

    parse_args "$@"

    # Create work directory
    WORK_DIR=$(mktemp -d /tmp/k8s_offline_XXXXXX)
    trap 'rm -rf "${WORK_DIR}"' EXIT

    log_info "K8s version: ${K8S_VERSION}"
    log_info "Output dir:  ${OUTPUT_DIR}"
    log_info "Work dir:    ${WORK_DIR}"
    echo ""

    # --- Prerequisite checks ---
    check_prerequisites

    # --- Detect host OS, resolve target OS, and set up RPM tables ---
    detect_host_os
    resolve_target_os
    setup_rpm_tables
    load_rpm_config
    auto_detect_existing_bundle

    # --- Version resolution ---
    resolve_versions_from_kubeadm
    resolve_calico_version

    # Apply --calico-version CLI override if specified (after auto-resolution)
    if [[ -n "$CALICO_VERSION_OVERRIDE" ]]; then
        log_info "Overriding Calico version with CLI: ${CALICO_VERSION_OVERRIDE}"
        CALICO_VERSION="${CALICO_VERSION_OVERRIDE#v}"  # Strip leading 'v' if present
    fi

    resolve_crictl_version
    finalize_versions
    print_version_summary

    if [[ $DRY_RUN -eq 1 ]]; then
        log_warn "=== DRY RUN MODE — No downloads will be performed ==="
        echo ""
    fi

    # --- Phase 1: Binaries ---
    PHASE1_RC=0; download_binaries    || PHASE1_RC=$?

    # --- Phase 2: Container Images ---
    PHASE2_RC=0; download_images      || PHASE2_RC=$?

    # --- Phase 3: RPM Packages ---
    PHASE3_RC=0; download_packages    || PHASE3_RC=$?

    # --- Phase 4: Other files ---
    PHASE4_RC=0; download_other_files || PHASE4_RC=$?

    # --- Phase 5: Update version constants ---
    update_version_constants

    # --- Write manifest ---
    write_manifest

    print_summary
    exit $?
}

main "$@"
