# K8s Offline Download Skill — Claude Code

## Purpose

This skill automates downloading ALL files needed for a K8s Automation_Ansible air-gapped Kubernetes deployment. Given only a **Kubernetes version**, Claude Code:

1. **Auto-resolves** all compatible component versions (etcd, CoreDNS, pause, Calico, Helm, containerd, crictl, cfssl, yq) using native WebFetch
2. **Researches** current RPM versions live from AlmaLinux mirrors via WebFetch
3. **Downloads** all binaries, container images, and RPM packages by running `scripts/k8s_offline_downloader.sh` via Bash
4. **Packages** them into `binaries.tar.gz`, `images.tar.gz`, `packages.tar.gz`
5. **Populates** the `other/` directory with system RPMs and CIS hardening tools
6. **Updates** `ansible/k8s_version_constants.json` with the resolved versions

---

## When to Use

- User asks to "download files for K8s offline deployment"
- User asks to "prepare K8s Automation_Ansible for a new K8s version"
- User asks to "generate the tar.gz bundles for K8s Automation"
- User mentions downloading binaries/images for air-gapped K8s
- User wants to run `k8s_offline_downloader.sh` and needs help building the command

---

## Prerequisites

The download script MUST run on a **Linux x86_64 machine with internet access**. Required tools:

| Tool | Required For | Required? |
|------|-------------|-----------|
| `curl` | All HTTP downloads | **Yes** |
| `tar` | Archive creation | **Yes** |
| `jq` | JSON processing | **Yes** |
| `docker` OR `skopeo` OR `ctr` | Container image pull/save | **Yes** (for images) |
| `yumdownloader` OR `dnf` | RPM downloads | Recommended |

If the user's current machine is Windows or macOS, the script must be run on a Linux VM or build server with internet access.

---

## Claude Code Native Tools Used

| Tool | Purpose |
|------|---------|
| `Bash` | Run the download script and environment checks |
| `WebFetch` | Fetch kubeadm constants.go, AlmaLinux mirror listings, Calico releases |
| `WebSearch` | Supplemental research for version compatibility |
| `Read` | Read existing project files (rpm-research.sh, script source) for context |

---

## Script Location

The download script lives in this project at:

```
scripts/k8s_offline_downloader.sh
```

Always reference it with a path relative to the project root, or use an absolute path. Do NOT assume `~/.config/opencode/` paths — the script is version-controlled in this repository.

---

## Workflow Steps

### Step 1 — Requirements Gathering

Ask the user for these four inputs if not already provided:

**1. Kubernetes version** — Accept formats like `v1.32.4`, `1.32.4`, `1.32`, etc. Always normalise to `v{major}.{minor}.{patch}` format.

**2. Target cluster OS** (`el8` or `el9`) — This determines which RPM packages are downloaded.
- `el8` = RHEL 8 / AlmaLinux 8 / Rocky Linux 8
- `el9` = RHEL 9 / AlmaLinux 9 / Rocky Linux 9 (default)

If the user does not know their cluster OS, give them this detection command to run on any cluster node:

```bash
cat /etc/os-release | grep -E 'NAME|VERSION_ID'
# or:
rpm -q redhat-release almalinux-release rocky-release 2>/dev/null
```

**IMPORTANT — el8 containerd limitation**: Docker stopped publishing containerd.io for el8 after version 1.6.32. The script handles this automatically, but be aware that el8 targets will use 1.6.32 regardless of the `--containerd-version` setting.

**3. Architecture** (`amd64` or `arm64`) — Default is `amd64`. Most deployments are amd64.

**4. Output directory** — The path where the K8s Automation_Ansible project directory lives. Common default: `/root/K8s_Automation_Ansible` or `/root/K8s Automation_Ansible`. Accept any path.

Confirm all four inputs before proceeding. Example prompt summary:

```
I'll prepare the download for:
- K8s version:    v1.32.4
- Target OS:      el9 (AlmaLinux 9 / RHEL 9)
- Architecture:   amd64
- Output dir:     /root/K8s_Automation_Ansible

Proceeding to verify environment...
```

---

### Step 2 — Environment Verification

Check that the machine is Linux x86_64 with internet access and has the required tools. Run via Bash:

```bash
# Platform check
uname -s && uname -m

# Internet connectivity
curl -sS --max-time 5 -o /dev/null -w "%{http_code}" https://dl.k8s.io && echo " — internet OK"

# Required tool availability
for tool in curl tar jq; do
  command -v "$tool" >/dev/null 2>&1 && echo "$tool: OK" || echo "$tool: MISSING"
done

# Container runtime check (need at least one)
for tool in docker skopeo ctr; do
  command -v "$tool" >/dev/null 2>&1 && echo "Container runtime: $tool found" && break
done

# RPM download tools (recommended)
command -v yumdownloader >/dev/null 2>&1 && echo "yumdownloader: OK" || echo "yumdownloader: not found (will fall back to dnf/mirror)"
command -v dnf >/dev/null 2>&1 && echo "dnf: OK" || echo "dnf: not found"

# Disk space check (~600MB needed for a full download)
df -h "${OUTPUT_DIR:-.}" | awk 'NR==2 {print "Disk available: " $4}'
```

**If not Linux x86_64**: The script cannot run on Windows, macOS, or ARM hosts. Advise the user to SSH to a Linux build server and run the commands there.

**If no container runtime is found**: Warn the user. The script will fail at the images phase without docker, skopeo, or ctr.

**If disk space is under 600MB**: Warn the user. Full download (binaries + images + packages + other) requires ~600MB minimum, more for larger K8s versions.

---

### Step 3 — Version Resolution

Fetch kubeadm constants.go to extract the CoreDNS, pause image, and etcd versions that are bundled with this K8s release. Use WebFetch natively — no curl subprocess needed.

**WebFetch URL:**
```
https://raw.githubusercontent.com/kubernetes/kubernetes/${K8S_VERSION}/cmd/kubeadm/app/constants/constants.go
```

Example for v1.32.4:
```
https://raw.githubusercontent.com/kubernetes/kubernetes/v1.32.4/cmd/kubeadm/app/constants/constants.go
```

From the fetched content, extract:
- **CoreDNSVersion** — search for `CoreDNSVersion = "` and extract the value
- **PauseVersion** — search for `PauseVersion = "` and extract the value
- **DefaultEtcdVersion** — search for `DefaultEtcdVersion = "` and extract the value (this is the kubeadm-bundled etcd, distinct from the external etcd)

Other component defaults (use these unless the user provides overrides):

| Component | Default | Notes |
|-----------|---------|-------|
| etcd (external) | `v3.5.21` | Different from kubeadm's bundled etcd — this is the external etcd cluster |
| Helm | `v3.17.3` | Latest stable |
| containerd (el9) | `1.7.27` | Latest 1.7.x LTS |
| containerd (el8) | `1.6.32` | Docker stopped el8 builds after this version |
| crictl | `v{K8s_minor}.0` | Matches K8s minor, e.g., `v1.32.0` for K8s `v1.32.x` |
| cfssl | `1.6.5` | Latest stable |
| yq | `v4.44.6` | Latest stable |
| Calico | auto-resolved | From K8s version mapping table (see below) |

**Calico version mapping** (from the script's `resolve_calico_version()` function):

| K8s Minor | Calico Version |
|-----------|---------------|
| 1.29 | 3.26.1 |
| 1.30 | 3.27.3 |
| 1.31 | 3.28.2 |
| 1.32 | 3.29.0 |
| 1.33 | 3.29.0 |
| 1.34 | 3.30.2 |
| 1.35+ | 3.31.4 (latest known) |

For K8s versions beyond the mapping table, use the latest known Calico and perform Step 5 (Calico Research) to verify a newer release exists.

**Present the resolved version summary to the user for confirmation** before any downloads begin:

```
Resolved component versions for K8s v1.32.4 / el9:
  CoreDNS:           v1.11.3  (from kubeadm constants.go)
  Pause image:       3.10     (from kubeadm constants.go)
  Etcd (kubeadm):    3.5.16   (from kubeadm constants.go)
  Etcd (external):   v3.5.21
  Calico:            3.29.0   (from K8s minor mapping)
  Helm:              v3.17.3
  containerd RPM:    1.7.27
  crictl:            v1.32.0
  cfssl:             1.6.5
  yq:                v4.44.6

Proceed with these versions? (or specify overrides)
```

---

### Step 4 — RPM Research (Recommended, Not Mandatory)

**Purpose**: The hardcoded RPM filenames in the script may become stale when AlmaLinux ships new point releases. Before running the script, use WebFetch to discover current RPM versions from AlmaLinux mirrors and generate an `rpm_versions.json` override file.

**When to perform this step:**
- Always for NEW K8s versions not in the known mapping table
- When the user reports 404 errors on RPM URLs from a previous run
- When the user explicitly asks for updated RPM versions
- Skip if the user is re-running a known-good configuration or in a hurry

**RPM research workflow:**

#### 4a. Determine mirror URLs from target OS

For **el9** targets, WebFetch these two pages:
```
https://repo.almalinux.org/almalinux/9/AppStream/x86_64/os/Packages/
https://repo.almalinux.org/almalinux/9/BaseOS/x86_64/os/Packages/
```

For **el8** targets, WebFetch these two pages:
```
https://repo.almalinux.org/almalinux/8/AppStream/x86_64/os/Packages/
https://repo.almalinux.org/almalinux/8/BaseOS/x86_64/os/Packages/
```

#### 4b. Search package listings for current RPM versions

Scan the fetched HTML for these packages:

| Package | el9 Repo | el8 Repo | Pattern to Find |
|---------|----------|----------|-----------------|
| keepalived | AppStream | AppStream | `keepalived-*.el{8,9}*.x86_64.rpm` |
| socat | AppStream | AppStream | `socat-*.el{8,9}*.x86_64.rpm` |
| chrony | BaseOS | BaseOS | `chrony-*.el{8,9}*.x86_64.rpm` |
| net-snmp-libs | AppStream (el9) | **BaseOS (el8)** | `net-snmp-libs-*.el{8,9}*.x86_64.rpm` |
| net-snmp-agent-libs | AppStream | AppStream | `net-snmp-agent-libs-*.el{8,9}*.x86_64.rpm` |
| lm_sensors-libs | AppStream (el9) | **BaseOS (el8)** | `lm_sensors-libs-*.el{8,9}*.x86_64.rpm` |
| mariadb-connector-c | AppStream | AppStream | `mariadb-connector-c-*.el{8,9}*.x86_64.rpm` |
| mariadb-connector-c-config | AppStream | AppStream | `mariadb-connector-c-config-*.el{8,9}*.noarch.rpm` |
| libnftnl | BaseOS | BaseOS | `libnftnl-*.el{8,9}*.x86_64.rpm` |
| tar | BaseOS | BaseOS | `tar-*.el{8,9}*.x86_64.rpm` |
| unzip | BaseOS | BaseOS | `unzip-*.el{8,9}*.x86_64.rpm` |
| zip | BaseOS | BaseOS | `zip-*.el{8,9}*.x86_64.rpm` |
| perl-interpreter | BaseOS | BaseOS | `perl-interpreter-*.el{8,9}*.x86_64.rpm` |
| perl-libs | BaseOS | BaseOS | `perl-libs-*.el{8,9}*.x86_64.rpm` |

**CRITICAL — el8 repo placement differs from el9**:
- On el8: `net-snmp-libs` is in **BaseOS** (NOT AppStream)
- On el8: `lm_sensors-libs` is in **BaseOS** (NOT AppStream)
- Getting the repo wrong means a 404 error at download time

#### 4c. WebFetch the Docker containerd repo

For **el9** targets:
```
https://download.docker.com/linux/centos/9/x86_64/stable/Packages/
```

For **el8** targets:
```
https://download.docker.com/linux/centos/8/x86_64/stable/Packages/
```

**IMPORTANT for el8**: Do NOT set `containerd.rpm` in the JSON for el8 targets. Docker stopped publishing el8 builds after 1.6.32. The script's hardcoded el8 default is correct and must not be overridden.

#### 4d. Perl dependencies note

keepalived depends on approximately 55 perl sub-packages. The perl major version differs:
- el8: perl 5.26.3
- el9: perl 5.32.1

**If you cannot confidently enumerate all 55+ perl RPM filenames from the mirror listing, do NOT include `perl_rpms` in the JSON.** Let the script use its hardcoded perl defaults. It is better to override the 5–10 packages you can confirm than to guess all 55+.

#### 4e. Generate rpm_versions.json

Write the file using Bash:

```bash
cat > /tmp/rpm_versions.json << 'RPMEOF'
{
  "target_os": "el9",
  "containerd": {
    "rpm": "containerd.io-1.7.28-3.1.el9.x86_64.rpm"
  },
  "socat": {
    "rpm_urls": [
      "https://repo.almalinux.org/almalinux/9/AppStream/x86_64/os/Packages/socat-1.7.4.1-9.el9.x86_64.rpm"
    ]
  },
  "keepalived": {
    "rpm_url": "https://repo.almalinux.org/almalinux/9/AppStream/x86_64/os/Packages/keepalived-2.2.8-7.el9.x86_64.rpm",
    "core_rpms": [
      "https://repo.almalinux.org/almalinux/9/AppStream/x86_64/os/Packages/keepalived-2.2.8-7.el9.x86_64.rpm",
      "https://repo.almalinux.org/almalinux/9/AppStream/x86_64/os/Packages/net-snmp-libs-5.9.1-18.el9.x86_64.rpm",
      "https://repo.almalinux.org/almalinux/9/AppStream/x86_64/os/Packages/net-snmp-agent-libs-5.9.1-18.el9.x86_64.rpm",
      "https://repo.almalinux.org/almalinux/9/AppStream/x86_64/os/Packages/lm_sensors-libs-3.6.0-11.el9.x86_64.rpm",
      "https://repo.almalinux.org/almalinux/9/AppStream/x86_64/os/Packages/mariadb-connector-c-3.2.6-1.el9_0.x86_64.rpm",
      "https://repo.almalinux.org/almalinux/9/AppStream/x86_64/os/Packages/mariadb-connector-c-config-3.2.6-1.el9_0.noarch.rpm"
    ]
  },
  "chrony": {
    "rpm_urls": [
      "https://repo.almalinux.org/almalinux/9/BaseOS/x86_64/os/Packages/chrony-4.6.1-3.el9.x86_64.rpm"
    ]
  },
  "libnftnl": {
    "rpm_url": "https://repo.almalinux.org/almalinux/9/BaseOS/x86_64/os/Packages/libnftnl-1.2.6-5.el9.x86_64.rpm"
  },
  "tar": {
    "rpm_urls": [
      "https://repo.almalinux.org/almalinux/9/BaseOS/x86_64/os/Packages/tar-1.34-8.el9.x86_64.rpm"
    ]
  },
  "unzip": {
    "rpm_urls": [
      "https://repo.almalinux.org/almalinux/9/BaseOS/x86_64/os/Packages/unzip-6.0-57.el9.x86_64.rpm"
    ]
  },
  "zip": {
    "rpm_urls": [
      "https://repo.almalinux.org/almalinux/9/BaseOS/x86_64/os/Packages/zip-3.0-36.el9.x86_64.rpm"
    ]
  }
}
RPMEOF
echo "rpm_versions.json written to /tmp/rpm_versions.json"
```

**NOTE**: The version numbers in this example are illustrative. Replace them with the actual versions discovered from the mirror listings in steps 4a–4c.

**Alternative**: The project also includes `tools/rpm-research.sh` which automates the mirror scraping. Run it on the Linux host if available:

```bash
# Check if the helper script exists
ls -la tools/rpm-research.sh 2>/dev/null && echo "rpm-research.sh found"

# Run it (if present) — outputs rpm_versions.json automatically
bash tools/rpm-research.sh --target-os el9 --output /tmp/rpm_versions.json
```

---

### Step 5 — Calico Research (for Unknown K8s Versions)

**When to perform this step:**
- When the target K8s version is NOT in the known version mapping table (Step 3)
- The script's `resolve_calico_version()` will fall back to the latest hardcoded version (currently 3.31.4), but a newer Calico release may be required for newer K8s versions
- When the user reports Calico compatibility issues

**Calico research workflow:**

#### 5a. Fetch the Calico releases page

Use WebFetch:
```
https://github.com/projectcalico/calico/releases
```

Find the latest stable release tag (not RC / alpha / beta). Note the version number, e.g., `v3.32.0`.

#### 5b. Verify K8s compatibility

WebFetch the compatibility requirements page:
```
https://docs.tigera.io/calico/latest/getting-started/kubernetes/requirements
```

Or check the specific release notes:
```
https://github.com/projectcalico/calico/releases/tag/v3.32.0
```

Confirm that the discovered Calico version supports the target K8s minor version.

#### 5c. Verify the manifest URL

WebFetch to confirm the manifest exists at the expected URL (substitute your version):
```
https://raw.githubusercontent.com/projectcalico/calico/v3.32.0/manifests/calico.yaml
```

If the manifest returns 200 OK and contains valid YAML content, the version is usable.

#### 5d. Pass the override to the script

Add `--calico-version 3.32.0` (without the `v` prefix) to the script invocation in Step 6.

---

### Step 6 — Script Invocation

#### 6a. Build the command

Assemble the full command based on collected inputs. Show it to the user for confirmation before running.

**Standard invocation** (el9, amd64, with RPM config and checksums):
```bash
./scripts/k8s_offline_downloader.sh \
  --k8s-version v1.32.4 \
  --target-os el9 \
  --arch amd64 \
  --rpm-config /tmp/rpm_versions.json \
  --output-dir /root/K8s_Automation_Ansible \
  --verify-checksums \
  --debug
```

**With Calico override** (for new/unknown K8s versions):
```bash
./scripts/k8s_offline_downloader.sh \
  --k8s-version v1.37.0 \
  --target-os el9 \
  --arch amd64 \
  --rpm-config /tmp/rpm_versions.json \
  --calico-version 3.32.0 \
  --output-dir /root/K8s_Automation_Ansible \
  --verify-checksums \
  --debug
```

**With existing bundle** (when host OS doesn't match target OS, or to reuse socat/keepalived from a previous run):
```bash
./scripts/k8s_offline_downloader.sh \
  --k8s-version v1.35.3 \
  --target-os el9 \
  --arch amd64 \
  --existing-bundle /root/without_k8s_automation/K8s_Automation_Ansible \
  --output-dir /root/K8s_Automation_Ansible \
  --debug
```

**Dry run** (show what would be downloaded without downloading):
```bash
./scripts/k8s_offline_downloader.sh \
  --k8s-version v1.32.4 \
  --target-os el9 \
  --dry-run
```

**Skip specific phases** (e.g., re-run only packages after a failure):
```bash
./scripts/k8s_offline_downloader.sh \
  --k8s-version v1.32.4 \
  --target-os el9 \
  --skip-binaries \
  --skip-images \
  --rpm-config /tmp/rpm_versions.json \
  --output-dir /root/K8s_Automation_Ansible \
  --debug
```

#### 6b. All available flags reference

| Flag | Description |
|------|-------------|
| `--k8s-version VERSION` | **(Required)** Kubernetes version, e.g., `v1.32.4` |
| `--target-os el8\|el9` | Target cluster OS (default: `el9`) |
| `--arch amd64\|arm64` | Binary architecture (default: `amd64`) |
| `--output-dir DIR` | Output directory (default: current directory) |
| `--verify-checksums` | Opt-in SHA256 verification after download |
| `--rpm-config FILE` | JSON override file for RPM URLs and versions |
| `--existing-bundle DIR` | Path to existing deployment for socat/keepalived/RPMs |
| `--skip-binaries` | Skip Phase 1 (kubeadm, kubectl, kubelet, etcd, helm...) |
| `--skip-images` | Skip Phase 2 (K8s core images, Calico images) |
| `--skip-packages` | Skip Phase 3 (containerd, chrony, keepalived RPMs) |
| `--skip-other` | Skip Phase 4 (tar/unzip/zip RPMs, yq, cfssl, Calico manifest) |
| `--dry-run` | Print what would run without executing downloads |
| `--debug` | Enable verbose debug output |
| `--proxy URL` | HTTP proxy for downloads, e.g., `http://proxy:8080` |
| `--etcd-version VERSION` | Override etcd version |
| `--helm-version VERSION` | Override Helm version |
| `--containerd-version V` | Override containerd version |
| `--crictl-version V` | Override crictl version |
| `--cfssl-version V` | Override cfssl version |
| `--yq-version V` | Override yq version |
| `--calico-version V` | Override Calico version (no `v` prefix, e.g., `3.32.0`) |

#### 6c. Confirm and execute

Present the final command to the user, wait for their go-ahead (unless they explicitly said to proceed), then run it via Bash. Monitor stdout/stderr for phase progress and error messages.

The script has 5 phases shown in its output:
1. **Phase 1 — Binaries**: kubeadm, kubectl, kubelet, etcd, helm, crictl, cfssl
2. **Phase 2 — Images**: K8s core images, Calico images (pulled and saved as raw tar)
3. **Phase 3 — Packages**: containerd RPM, chrony RPMs, keepalived RPMs, keepalivedbundle/
4. **Phase 4 — Other**: tar/unzip/zip RPMs, yq, cfssl to `other/`, Calico manifest to `other/calico/`
5. **Phase 5 — Config**: Updates `ansible/k8s_version_constants.json`

---

### Step 7 — Failure Handling

#### 7a. Script exit codes

| Exit Code | Meaning | Action |
|-----------|---------|--------|
| `0` | All phases succeeded | Proceed to output verification |
| `1` | Critical failure (Phase 4 / config phase) | Inspect stderr; check disk space, network, permissions |
| `2` | Partial failure (some downloads failed, others succeeded) | Review failure summary; targeted re-run or manual fix |

#### 7b. Common failures and remediation

**Container image download failures (Phase 2)**

The script tries docker, then skopeo, then ctr. If all three fail:
```bash
# Try pulling manually with docker
docker pull registry.k8s.io/kube-apiserver:v1.32.4
docker save -o /tmp/test.tar registry.k8s.io/kube-apiserver:v1.32.4

# Check if the image name is correct
docker images | grep kube-apiserver
```

**RPM 404 errors (Phase 3 or 4)**

This means the hardcoded RPM filenames in the script are stale. Go back to Step 4 and perform RPM research to generate a fresh `rpm_versions.json`, then re-run with `--rpm-config /tmp/rpm_versions.json`.

**socat / keepalived binary missing**

These cannot be downloaded as static binaries from upstream. The script extracts them from RPMs when it can. If that fails:
- Use `--existing-bundle` to copy them from a previous deployment
- Or compile from source on a matching OS system

**Disk space errors**

```bash
df -h /root
# If low, free space or choose a different --output-dir on a larger volume
```

**Proxy / network timeouts**

```bash
# Add proxy to the command:
./scripts/k8s_offline_downloader.sh \
  --k8s-version v1.32.4 \
  --proxy http://corporate-proxy:8080 \
  ...
```

**RPMs missing after run (Phase 4 output empty)**

If the host OS does not match the target OS (e.g., running on Ubuntu to download for el9), yumdownloader cannot produce the correct RPMs. Use `--existing-bundle` or supply `--rpm-config` with explicit AlmaLinux mirror URLs for all RPMs.

**Re-running with existing bundle** (most common recovery path for RPM failures):
```bash
./scripts/k8s_offline_downloader.sh \
  --k8s-version v1.32.4 \
  --target-os el9 \
  --output-dir /root/K8s_Automation_Ansible \
  --existing-bundle /root/previous_K8s_Automation_Ansible \
  --skip-binaries \
  --skip-images \
  --debug
```

#### 7c. Verify output after completion

Run these checks via Bash after the script exits:

```bash
OUTPUT_DIR="/root/K8s_Automation_Ansible"

# CRITICAL: Verify RPMs exist in other/ — ansible will fail without these
echo "=== other/ RPMs ==="
ls -la "${OUTPUT_DIR}/other/"*.rpm 2>/dev/null || echo "WARNING: No RPMs found in other/"

# Check main archives exist and are non-zero
echo "=== Archive sizes ==="
ls -lh "${OUTPUT_DIR}/binaries.tar.gz" \
        "${OUTPUT_DIR}/images.tar.gz" \
        "${OUTPUT_DIR}/packages.tar.gz" 2>/dev/null

# Spot-check archive contents
echo "=== binaries.tar.gz (first 10 entries) ==="
tar -tzf "${OUTPUT_DIR}/binaries.tar.gz" 2>/dev/null | head -10

echo "=== images.tar.gz (first 10 entries) ==="
tar -tzf "${OUTPUT_DIR}/images.tar.gz" 2>/dev/null | head -10

echo "=== packages.tar.gz (first 10 entries) ==="
tar -tzf "${OUTPUT_DIR}/packages.tar.gz" 2>/dev/null | head -10

# CRITICAL: cfssl and cfssljson in other/ (etcd role requires these)
echo "=== cfssl binaries in other/ ==="
file "${OUTPUT_DIR}/other/cfssl" "${OUTPUT_DIR}/other/cfssljson" 2>/dev/null

# Calico manifest
echo "=== Calico manifests ==="
ls -la "${OUTPUT_DIR}/other/calico/" 2>/dev/null || echo "WARNING: no other/calico/ directory"

# CIS hardening scripts
echo "=== CIS hardening ==="
ls -la "${OUTPUT_DIR}/other/cis_hardening_scripts/" 2>/dev/null

# Image format sanity check — MUST be raw tar, NOT gzip
echo "=== Image format check (must be POSIX tar, not gzip) ==="
FIRST_IMG=$(tar -tzf "${OUTPUT_DIR}/images.tar.gz" 2>/dev/null | head -1)
if [ -n "$FIRST_IMG" ]; then
  tar -xzf "${OUTPUT_DIR}/images.tar.gz" -O "$FIRST_IMG" 2>/dev/null | file - | grep -q "POSIX tar" && \
    echo "OK: image format is raw tar" || \
    echo "WARNING: image may be gzip-compressed — ctr import will fail"
fi

# k8s_version_constants.json updated
echo "=== k8s_version_constants.json ==="
cat "${OUTPUT_DIR}/ansible/k8s_version_constants.json" 2>/dev/null | python3 -m json.tool 2>/dev/null | head -20
```

#### 7d. Expected output structure and sizes

**binaries.tar.gz** (~100–120MB):
- `binaries/kubeadm`, `binaries/kubectl`, `binaries/kubelet`
- `binaries/etcd`, `binaries/etcdctl`, `binaries/etcdutl`
- `binaries/helm`, `binaries/crictl`
- `binaries/cfssl`, `binaries/cfssljson`
- (Optional: `binaries/socat`, `binaries/keepalived`)

**images.tar.gz** (~350–600MB):
- `images/registry.k8s.io_kube-apiserver_v{version}.tar.gz`
- `images/registry.k8s.io_kube-controller-manager_v{version}.tar.gz`
- `images/registry.k8s.io_kube-proxy_v{version}.tar.gz`
- `images/registry.k8s.io_kube-scheduler_v{version}.tar.gz`
- `images/registry.k8s.io_pause_{pause_version}.tar.gz`
- `images/registry.k8s.io_coredns_v{coredns_version}.tar.gz`
- `images/calico_node_v{calico_version}.tar.gz`
- `images/calico_cni_v{calico_version}.tar.gz`
- `images/calico_kube-controllers_v{calico_version}.tar.gz`

**CRITICAL — image format**: Despite the `.tar.gz` extension, these files MUST be raw POSIX tar archives, NOT gzip-compressed. The `ctr -n=k8s.io images import` command used by the ansible role does NOT support gzip decompression. Use `file images/*.tar.gz` to verify they report "POSIX tar archive" and NOT "gzip compressed data".

**packages.tar.gz** (~50–70MB):
- `packages/containerd.io-*.rpm`
- `packages/chrony-*.rpm` and dependencies
- `packages/keepalived-*.rpm` and perl dependencies (~90+ RPMs)
- `packages/keepalivedbundle/` (shared libraries)

**other/ directory** (critical files):
- `other/cfssl`, `other/cfssljson` — required by the etcd role
- `other/tar-*.rpm`, `other/unzip-*.rpm`, `other/zip-*.rpm` — required by base setup
- `other/calico/calico_v{calico_version}.yml` — applied by the kubernetes role
- `other/cis_hardening_scripts/yq_linux_amd64` — required by CIS hardening role

---

## Version Compatibility Reference

### How K8s Version Determines Other Versions

```
K8s Version
  ├── CoreDNS Version    ← from kubeadm constants.go (WebFetch in Step 3)
  ├── Pause Version      ← from kubeadm constants.go (WebFetch in Step 3)
  ├── Etcd (kubeadm)     ← from kubeadm constants.go (informational only)
  ├── Etcd (external)    ← hardcoded default: v3.5.21
  ├── Calico Version     ← from K8s minor mapping table
  ├── crictl Version     ← matches K8s minor (v1.32.0 for K8s 1.32.x)
  ├── Helm               ← latest stable (v3.17.3)
  ├── containerd         ← latest 1.7.x LTS (1.7.27) / el8 capped at 1.6.32
  ├── cfssl              ← latest stable (1.6.5)
  └── yq                 ← latest stable (v4.44.6)
```

### Known Verified Version Combinations

| K8s Version | CoreDNS | Pause | Calico | Etcd (ext) |
|-------------|---------|-------|--------|------------|
| v1.29.6 | v1.11.1 | 3.9 | 3.26.1 | v3.5.21 |
| v1.31.5 | v1.11.3 | 3.10 | 3.28.2 | v3.5.21 |
| v1.32.4 | v1.11.3 | 3.10 | 3.29.0 | v3.5.21 |
| v1.33.1 | v1.12.0 | 3.10 | 3.29.0 | v3.5.21 |
| v1.35.3 | v1.13.1 | 3.10.1 | 3.31.4 | v3.5.21 |

---

## Download URL Reference

| Component | URL Pattern |
|-----------|------------|
| K8s binaries | `https://dl.k8s.io/release/{version}/bin/linux/amd64/{binary}` |
| etcd | `https://github.com/etcd-io/etcd/releases/download/{version}/etcd-{version}-linux-amd64.tar.gz` |
| Helm | `https://get.helm.sh/helm-{version}-linux-amd64.tar.gz` |
| crictl | `https://github.com/kubernetes-sigs/cri-tools/releases/download/{version}/crictl-{version}-linux-amd64.tar.gz` |
| cfssl | `https://github.com/cloudflare/cfssl/releases/download/v{version}/cfssl_{version}_linux_amd64` |
| cfssljson | `https://github.com/cloudflare/cfssl/releases/download/v{version}/cfssljson_{version}_linux_amd64` |
| containerd RPM | `https://download.docker.com/linux/centos/{el_major}/x86_64/stable/Packages/containerd.io-{version}-3.1.{el}.x86_64.rpm` |
| yq | `https://github.com/mikefarah/yq/releases/download/{version}/yq_linux_amd64` |
| Container images | pulled with `docker pull {image}`, saved with `docker save -o {file} {image}` |
| kubeadm constants | `https://raw.githubusercontent.com/kubernetes/kubernetes/{version}/cmd/kubeadm/app/constants/constants.go` |

---

## RPM Config JSON Schema

The `--rpm-config` flag accepts a JSON file that overrides the script's hardcoded RPM lookup tables. This lets Claude Code discover current RPM versions via WebFetch and pass them to the script without modifying the script.

**All fields are optional.** Only specified fields override the hardcoded defaults. Unspecified fields retain their values from `setup_rpm_tables()`.

```json
{
  "target_os": "el9",
  "containerd": {
    "rpm": "containerd.io-1.7.28-3.1.el9.x86_64.rpm"
  },
  "socat": {
    "rpm_urls": [
      "https://repo.almalinux.org/almalinux/9/AppStream/x86_64/os/Packages/socat-1.7.4.1-9.el9.x86_64.rpm",
      "https://repo.almalinux.org/almalinux/9/AppStream/x86_64/os/Packages/socat-1.7.4.1-8.el9.x86_64.rpm"
    ]
  },
  "keepalived": {
    "rpm_url": "https://...full URL to keepalived RPM...",
    "core_rpms": [
      "https://...full URL to keepalived RPM...",
      "https://...full URL to net-snmp-libs RPM...",
      "https://...full URL to net-snmp-agent-libs RPM...",
      "https://...full URL to lm_sensors-libs RPM...",
      "https://...full URL to mariadb-connector-c RPM...",
      "https://...full URL to mariadb-connector-c-config RPM..."
    ],
    "perl_rpms": ["perl-interpreter-5.32.1-481.el9.x86_64.rpm", "..."],
    "perl_rpm_base": "https://repo.almalinux.org/almalinux/9/BaseOS/x86_64/os/Packages",
    "perl_rpm_appstream": "https://repo.almalinux.org/almalinux/9/AppStream/x86_64/os/Packages"
  },
  "chrony": {
    "rpm_urls": ["https://...full URL to chrony RPM..."]
  },
  "libnftnl": {
    "rpm_url": "https://...full URL to libnftnl RPM..."
  },
  "tar": {
    "rpm_urls": ["https://...full URL to tar RPM..."]
  },
  "unzip": {
    "rpm_urls": ["https://...full URL to unzip RPM..."]
  },
  "zip": {
    "rpm_urls": ["https://...full URL to zip RPM..."]
  }
}
```

**Field reference:**

| Field | Type | Description |
|-------|------|-------------|
| `target_os` | string | Informational — must match `--target-os`. Script warns if mismatched. |
| `containerd.rpm` | string | RPM **filename only** (no URL). Downloaded from Docker repo automatically. |
| `socat.rpm_urls` | string[] | Full URLs tried in order until one succeeds. |
| `keepalived.rpm_url` | string | Full URL for keepalived RPM (used for binary extraction). |
| `keepalived.core_rpms` | string[] | Full URLs for keepalived + its 5 direct dependency RPMs. |
| `keepalived.perl_rpms` | string[] | RPM **filenames only**. Downloaded from `perl_rpm_base` + `perl_rpm_appstream`. |
| `keepalived.perl_rpm_base` | string | Base URL prefix for perl RPMs in BaseOS. |
| `keepalived.perl_rpm_appstream` | string | Base URL prefix for perl RPMs in AppStream. |
| `chrony.rpm_urls` | string[] | Full URLs tried in order. |
| `libnftnl.rpm_url` | string | Full URL for libnftnl RPM. |
| `tar.rpm_urls` | string[] | Full URLs tried in order. |
| `unzip.rpm_urls` | string[] | Full URLs tried in order. |
| `zip.rpm_urls` | string[] | Full URLs tried in order. |

**Tip**: When you can only confirm a subset of RPM versions from the mirror (e.g., 6 packages), include only those in the JSON. The script uses its hardcoded defaults for the rest. Partial overrides are always better than guesses.

---

## Critical Constraints

- **NEVER SKIP VERSION RESOLUTION**: Always WebFetch kubeadm constants.go to get accurate CoreDNS/Pause versions for the exact K8s patch release
- **ALWAYS CONFIRM VERSIONS** with the user before starting any downloads
- **USE THE PROJECT SCRIPT**: Reference `scripts/k8s_offline_downloader.sh` — it is version-controlled in this repo and must not be confused with any other copy
- **IMAGE FORMAT**: Images inside `images.tar.gz` must be raw POSIX tar archives (not gzip). Verify with `file` after download
- **TARGET PLATFORM**: The download machine must be Linux x86_64. The archives target RHEL8/AlmaLinux8 (el8) or RHEL9/AlmaLinux9 (el9) — controlled by `--target-os`
- **AIR-GAP CONTEXT**: Output is for fully offline deployment — nothing can be downloaded on target nodes
- **DO NOT MODIFY ANSIBLE PLAYBOOKS**: Only update `k8s_version_constants.json` and generate the tar.gz archives

---

## Known Issues and Caveats

### Container Image Format: Raw Tar Required

**CRITICAL**: Container image files inside `images.tar.gz` MUST be raw POSIX tar archives, NOT gzip-compressed. The `ctr -n=k8s.io images import` command used by the `k8s_bundle_install` ansible role does NOT support gzip decompression and will fail with `invalid tar header`.

The files use a `.tar.gz` extension (matching the K8s Automation_Ansible convention), but their actual content is raw tar. Naming convention: underscores replace `/` and `:` in the image reference:
- `registry.k8s.io/kube-apiserver:v1.33.1` → `registry.k8s.io_kube-apiserver_v1.33.1.tar.gz`
- `docker.io/calico/node:v3.29.0` → `calico_node_v3.29.0.tar.gz`

Verify format after download:
```bash
file images/registry.k8s.io_kube-apiserver_v1.33.1.tar.gz
# Must output: POSIX tar archive
# NOT: gzip compressed data
```

### OS Version Mismatch (Host vs Target)

The download script may run on a different OS than the target cluster (e.g., Ubuntu host downloading for el9 targets). The `--target-os` flag controls which RPMs are downloaded:

- `yumdownloader` only works correctly when the host OS matches the target OS
- When host OS does not match, the script downloads RPMs directly from AlmaLinux mirrors
- Use `--existing-bundle` as a fallback when mirror downloads fail

Always specify `--target-os` explicitly. The script defaults to el9 if not specified.

### containerd.io el8 Limitation

Docker stopped publishing containerd.io builds for el8 after version 1.6.32. The script uses 1.6.32 automatically for el8 targets and ignores `--containerd-version` overrides for el8. Do NOT include `containerd.rpm` in `rpm_versions.json` for el8 targets.

### Pre-compiled Binaries (socat, keepalived)

Not available as static binaries from upstream. The script extracts them from RPMs automatically. If RPM extraction fails, use `--existing-bundle` to copy from a previous deployment, or compile from source on a matching OS.

### Ansible Prerequisites Before Deployment

After generating the bundles and copying them to the ansible control node, these must be in place before running the playbook:

**Jinja2 version** (critical on CentOS 7 ansible hosts):
```bash
pip install Jinja2==2.11.3 MarkupSafe==1.1.1
```
Do NOT upgrade to Jinja2 3.x on Python 2.7 systems.

**cfssl/cfssljson on the control node** (etcd role requires them at `/usr/local/bin/`):
```bash
cp /root/K8s_Automation_Ansible/other/cfssl /usr/local/bin/cfssl
cp /root/K8s_Automation_Ansible/other/cfssljson /usr/local/bin/cfssljson
chmod +x /usr/local/bin/cfssl /usr/local/bin/cfssljson
```

**sshpass** (for password-based SSH from the control node):
```bash
yum install -y sshpass
```

**Running the playbook** — always use the interactive wrapper, not `ansible-playbook` directly:
```bash
cd K8s_Automation_Ansible/ansible && bash ansible_execute.sh
```

### Proxy Configuration for Docker

If the host requires a proxy for internet access:
```bash
# Configure Docker daemon proxy
mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/proxy.conf << 'EOF'
[Service]
Environment="HTTP_PROXY=http://your-proxy:8080"
Environment="HTTPS_PROXY=http://your-proxy:8080"
Environment="NO_PROXY=localhost,127.0.0.1"
EOF
systemctl daemon-reload && systemctl restart docker
```

Then pass `--proxy http://your-proxy:8080` to the download script.

---

## Project Structure Reference

```
kubecargo-ai/
├── scripts/
│   └── k8s_offline_downloader.sh    ← The download script (run via Bash)
├── tools/
│   └── rpm-research.sh              ← Optional: automates AlmaLinux mirror scraping

K8s_Automation_Ansible/ (output directory — separate project)
├── binaries.tar.gz          ← Phase 1 output
├── images.tar.gz            ← Phase 2 output
├── packages.tar.gz          ← Phase 3 output
├── download_manifest.json   ← Generated manifest
├── other/
│   ├── cfssl                ← CRITICAL: etcd role needs this
│   ├── cfssljson            ← CRITICAL: etcd role needs this
│   ├── tar-*.rpm            ← CRITICAL: base setup needs this
│   ├── unzip-*.rpm
│   ├── zip-*.rpm
│   ├── calico/
│   │   └── calico_v{version}.yml    ← kubernetes role applies this
│   └── cis_hardening_scripts/
│       └── yq_linux_amd64
└── ansible/
    ├── k8s_version_constants.json   ← Updated by Phase 5
    ├── k8s_install.yaml
    ├── hosts
    └── roles/
        ├── k8s_bundle_install/      ← Consumes the tar.gz files
        ├── kubernetes/              ← Applies Calico manifest
        ├── etcd/                    ← Uses cfssl from other/
        └── keepalived/              ← Uses keepalivedbundle/
```
