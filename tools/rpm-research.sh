#!/usr/bin/env bash
# tools/rpm-research.sh
# Queries AlmaLinux and Docker mirrors to find current RPM filenames,
# then writes an rpm_versions.json compatible with --rpm-config in
# scripts/k8s_offline_downloader.sh.
#
# Usage:
#   tools/rpm-research.sh [--target-os el8|el9] [--output FILE]
#
# Requirements: bash, curl, grep, sort  (jq optional — used only for validation)
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
TARGET_OS="el9"
OUTPUT_FILE="rpm_versions.json"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Query AlmaLinux and Docker mirrors and write rpm_versions.json.

Options:
  --target-os el8|el9   Target OS version (default: el9)
  --output FILE         Output JSON file path (default: rpm_versions.json)
  --help                Show this help message

EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target-os)
            TARGET_OS="${2:?--target-os requires a value (el8 or el9)}"
            shift 2
            ;;
        --output)
            OUTPUT_FILE="${2:?--output requires a value}"
            shift 2
            ;;
        --help|-h)
            usage
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            usage
            ;;
    esac
done

if [[ "$TARGET_OS" != "el8" && "$TARGET_OS" != "el9" ]]; then
    echo "ERROR: --target-os must be 'el8' or 'el9', got: ${TARGET_OS}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Mirror base URLs (differ between el8 and el9)
# ---------------------------------------------------------------------------
ALMA_VER="${TARGET_OS#el}"   # strips "el" → "8" or "9"
ALMA_BASE="https://repo.almalinux.org/almalinux/${ALMA_VER}"
APPSTREAM="${ALMA_BASE}/AppStream/x86_64/os/Packages"
BASEOS="${ALMA_BASE}/BaseOS/x86_64/os/Packages"
DOCKER_BASE="https://download.docker.com/linux/centos/${ALMA_VER}/x86_64/stable/Packages"

# Package → repo location mapping
# el9: net-snmp-libs, net-snmp-agent-libs, lm_sensors-libs in AppStream
# el8: the same packages live in BaseOS
if [[ "$TARGET_OS" == "el9" ]]; then
    NET_SNMP_REPO="$APPSTREAM"
    LM_SENSORS_REPO="$APPSTREAM"
else
    NET_SNMP_REPO="$BASEOS"
    LM_SENSORS_REPO="$BASEOS"
fi

# ---------------------------------------------------------------------------
# Counters for summary
# ---------------------------------------------------------------------------
FOUND=0
TOTAL=0

# ---------------------------------------------------------------------------
# Helper: fetch RPM listing, grep for a package prefix, pick latest version
# Returns the plain filename (e.g. keepalived-2.2.8-6.el9.x86_64.rpm)
# Sets global LAST_RPM_FILENAME and LAST_RPM_URL on success.
# ---------------------------------------------------------------------------
LAST_RPM_FILENAME=""
LAST_RPM_URL=""

find_rpm() {
    local base_url="$1"   # directory URL (no trailing slash)
    local pkg_prefix="$2" # grep anchor, e.g. "^keepalived-"
    local label="$3"      # human-readable name for warnings

    LAST_RPM_FILENAME=""
    LAST_RPM_URL=""
    TOTAL=$(( TOTAL + 1 ))

    local listing
    if ! listing=$(curl -sS --max-time 30 "${base_url}/"); then
        echo "  WARN: curl failed for ${base_url} (${label})" >&2
        return 1
    fi

    # Extract href="...something.rpm" → bare filename
    # Use lookahead (?=") so the trailing quote is not included in the match
    local filename
    filename=$(
        printf '%s\n' "$listing" \
        | grep -oP 'href="\K[^"]+\.rpm(?=")' \
        | grep -P "$pkg_prefix" \
        | sort -V \
        | tail -1
    )

    if [[ -z "$filename" ]]; then
        echo "  WARN: no RPM found for '${label}' at ${base_url}" >&2
        return 1
    fi

    LAST_RPM_FILENAME="$filename"
    LAST_RPM_URL="${base_url}/${filename}"
    FOUND=$(( FOUND + 1 ))
    echo "  OK  ${label}: ${filename}"
    return 0
}

# ---------------------------------------------------------------------------
# Collect each package
# ---------------------------------------------------------------------------
echo "==> rpm-research.sh: target-os=${TARGET_OS}"
echo "==> AppStream : ${APPSTREAM}"
echo "==> BaseOS    : ${BASEOS}"
echo "==> Docker    : ${DOCKER_BASE}"
echo ""

# --- containerd.io (Docker repo) ---
echo "[containerd.io]"
containerd_rpm=""
if find_rpm "$DOCKER_BASE" "^containerd\.io-" "containerd.io"; then
    containerd_rpm="$LAST_RPM_FILENAME"
fi

# --- socat (AppStream both el8 and el9) ---
echo "[socat]"
socat_url=""
if find_rpm "$APPSTREAM" "^socat-" "socat"; then
    socat_url="$LAST_RPM_URL"
fi

# --- keepalived (AppStream both el8 and el9) ---
echo "[keepalived]"
keepalived_url=""
if find_rpm "$APPSTREAM" "^keepalived-" "keepalived"; then
    keepalived_url="$LAST_RPM_URL"
fi

# --- keepalived core deps ---
echo "[net-snmp-libs]"
net_snmp_libs_url=""
if find_rpm "$NET_SNMP_REPO" "^net-snmp-libs-" "net-snmp-libs"; then
    net_snmp_libs_url="$LAST_RPM_URL"
fi

echo "[net-snmp-agent-libs]"
net_snmp_agent_libs_url=""
if find_rpm "$NET_SNMP_REPO" "^net-snmp-agent-libs-" "net-snmp-agent-libs"; then
    net_snmp_agent_libs_url="$LAST_RPM_URL"
fi

echo "[lm_sensors-libs]"
lm_sensors_libs_url=""
if find_rpm "$LM_SENSORS_REPO" "^lm_sensors-libs-" "lm_sensors-libs"; then
    lm_sensors_libs_url="$LAST_RPM_URL"
fi

echo "[mariadb-connector-c]"
mariadb_url=""
if find_rpm "$APPSTREAM" "^mariadb-connector-c-[0-9]" "mariadb-connector-c"; then
    mariadb_url="$LAST_RPM_URL"
fi

echo "[mariadb-connector-c-config]"
mariadb_config_url=""
if find_rpm "$APPSTREAM" "^mariadb-connector-c-config-" "mariadb-connector-c-config"; then
    mariadb_config_url="$LAST_RPM_URL"
fi

# --- perl-interpreter (BaseOS both el8 and el9) ---
echo "[perl-interpreter]"
perl_rpm=""
if find_rpm "$BASEOS" "^perl-interpreter-" "perl-interpreter"; then
    perl_rpm="$LAST_RPM_FILENAME"
fi

# --- chrony (BaseOS both el8 and el9) ---
echo "[chrony]"
chrony_url=""
if find_rpm "$BASEOS" "^chrony-" "chrony"; then
    chrony_url="$LAST_RPM_URL"
fi

# --- libnftnl (BaseOS both el8 and el9) ---
echo "[libnftnl]"
libnftnl_url=""
if find_rpm "$BASEOS" "^libnftnl-" "libnftnl"; then
    libnftnl_url="$LAST_RPM_URL"
fi

# --- tar (BaseOS both el8 and el9) ---
echo "[tar]"
tar_url=""
if find_rpm "$BASEOS" "^tar-" "tar"; then
    tar_url="$LAST_RPM_URL"
fi

# --- unzip (BaseOS both el8 and el9) ---
echo "[unzip]"
unzip_url=""
if find_rpm "$BASEOS" "^unzip-" "unzip"; then
    unzip_url="$LAST_RPM_URL"
fi

# --- zip (BaseOS both el8 and el9) ---
echo "[zip]"
zip_url=""
if find_rpm "$BASEOS" "^zip-" "zip"; then
    zip_url="$LAST_RPM_URL"
fi

# ---------------------------------------------------------------------------
# Build keepalived core_rpms array (only include non-empty URLs)
# ---------------------------------------------------------------------------
build_core_rpms_json() {
    local urls=()
    [[ -n "$keepalived_url" ]]        && urls+=("$keepalived_url")
    [[ -n "$net_snmp_libs_url" ]]     && urls+=("$net_snmp_libs_url")
    [[ -n "$net_snmp_agent_libs_url" ]] && urls+=("$net_snmp_agent_libs_url")
    [[ -n "$lm_sensors_libs_url" ]]   && urls+=("$lm_sensors_libs_url")
    [[ -n "$mariadb_url" ]]           && urls+=("$mariadb_url")
    [[ -n "$mariadb_config_url" ]]    && urls+=("$mariadb_config_url")

    local first=1
    local out="["
    for u in "${urls[@]+"${urls[@]}"}"; do
        [[ $first -eq 0 ]] && out+=","
        out+=$'\n'"      \"$u\""
        first=0
    done
    out+=$'\n    ]'
    printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# Helper: emit a JSON string value or empty string
# ---------------------------------------------------------------------------
jv() { printf '"%s"' "${1:-}"; }

# ---------------------------------------------------------------------------
# Assemble JSON
# ---------------------------------------------------------------------------
echo ""
echo "==> Writing JSON to: ${OUTPUT_FILE}"

core_rpms_json=$(build_core_rpms_json)
perl_rpm_val="${perl_rpm:-}"
# emit [] if perl-interpreter not found (main script falls back to hardcoded values)
[[ -n "$perl_rpm_val" ]] && perl_rpms_json="[\"$perl_rpm_val\"]" || perl_rpms_json="[]"

cat > "$OUTPUT_FILE" <<ENDJSON
{
  "target_os": "${TARGET_OS}",
  "containerd": {
    "rpm": $(jv "$containerd_rpm")
  },
  "socat": {
    "rpm_urls": [
      $(jv "$socat_url")
    ]
  },
  "keepalived": {
    "rpm_url": $(jv "$keepalived_url"),
    "core_rpms": ${core_rpms_json},
    "perl_rpms": ${perl_rpms_json},
    "perl_rpm_base": $(jv "$BASEOS"),
    "perl_rpm_appstream": $(jv "$APPSTREAM")
  },
  "chrony": {
    "rpm_urls": [
      $(jv "$chrony_url")
    ]
  },
  "libnftnl": {
    "rpm_url": $(jv "$libnftnl_url")
  },
  "tar": {
    "rpm_urls": [
      $(jv "$tar_url")
    ]
  },
  "unzip": {
    "rpm_urls": [
      $(jv "$unzip_url")
    ]
  },
  "zip": {
    "rpm_urls": [
      $(jv "$zip_url")
    ]
  }
}
ENDJSON

# ---------------------------------------------------------------------------
# Optional: validate JSON with jq if available
# ---------------------------------------------------------------------------
if command -v jq &>/dev/null; then
    if jq empty "$OUTPUT_FILE" 2>/dev/null; then
        echo "==> JSON validation passed (jq)"
    else
        echo "ERROR: Generated JSON is invalid — check ${OUTPUT_FILE}" >&2
        exit 1
    fi
else
    echo "==> (jq not found — skipping JSON validation)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "==> Done. Found ${FOUND}/${TOTAL} packages."
echo "==> Output written to: ${OUTPUT_FILE}"

if [[ "$FOUND" -lt "$TOTAL" ]]; then
    echo "WARN: Some packages were not found. Edit ${OUTPUT_FILE} to fill in missing entries." >&2
fi
