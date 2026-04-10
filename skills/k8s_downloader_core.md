# K8s Downloader Core — AI Logic & Workflow Library

This document is the **Single Source of Truth** for all AI models (Claude, Gemini, Codex, OpenCode) performing Kubernetes offline bundle downloads for `kubecargo-ai`. It contains the "tribal knowledge," URLs, regexes, and troubleshooting steps required to execute a successful download.

---

## 1. Requirement Gathering & Normalization

The AI must collect and normalize these parameters:
- **K8s Version:** e.g., `v1.32.4`. Always prefix with `v`.
- **Target OS:** `el8` (RHEL 8 / Alma 8) or `el9` (RHEL 9 / Alma 9). Default is `el9`.
- **Architecture:** `amd64` (x86_64) or `arm64` (aarch64). Default is `amd64`.
- **Output Directory:** The target path for the `K8s_Automation_Ansible` project.

---

## 2. Environment Audit (CRITICAL)

The download script `scripts/k8s_offline_downloader.sh` **must** run on a Linux host with internet access.
- If the current environment is **Windows or macOS**, the AI **must** instruct the user to:
    1.  SSH into a Linux build server or VM.
    2.  OR use a Linux container context (optional).
- **Required Tools on Host:** `curl`, `tar`, `jq`.
- **Optional but Recommended:** `skopeo` (or `docker`) for images, `rpm2cpio` and `cpio` for RPM extraction fallbacks.
- **`ctr` Version Note:** Architecture-specific pulls via `ctr --platform` require containerd 1.5+. On older versions (common in `el8`), image pulls are restricted to the host's native architecture.

---

## 3. Version Resolution (The "Engine")

### 3.1 Kubeadm Constants
Fetch `constants.go` for the target `{{K8S_VERSION}}`:
- **URL:** `https://raw.githubusercontent.com/kubernetes/kubernetes/{{K8S_VERSION}}/cmd/kubeadm/app/constants/constants.go`
- **Regexes:**
    - CoreDNS: `CoreDNSVersion\s*=\s*"v?\K[^"]+`
    - Pause: `PauseVersion\s*=\s*"\K[^"]+`
    - Etcd: `DefaultEtcdVersion\s*=\s*"\K[^"]+`

### 3.2 Calico Compatibility
- **K8s 1.29:** 3.26.1
- **K8s 1.30:** 3.27.3 (Legacy mapping preserved for stability)
- **K8s 1.31:** 3.28.2
- **K8s 1.32/1.33:** 3.29.0
- **K8s 1.34:** 3.30.7
- **K8s 1.35+:** 3.31.4 (or check latest stable on GitHub)

---

## 4. RPM Research Workflow (AI-Driven)

Always research live RPMs to prevent 404s. Use these mirrors based on `{{ALMA_MAJOR}}` (8 or 9) and `{{ARCH_RPM}}` (x86_64 or aarch64):

- **AppStream:** `https://repo.almalinux.org/almalinux/{{ALMA_MAJOR}}/AppStream/{{ARCH_RPM}}/os/Packages/`
- **BaseOS:** `https://repo.almalinux.org/almalinux/{{ALMA_MAJOR}}/BaseOS/{{ARCH_RPM}}/os/Packages/`
- **Docker:** `https://download.docker.com/linux/centos/{{ALMA_MAJOR}}/{{ARCH_RPM}}/stable/Packages/`

### 4.1 Packages to Confirm (Full Table)
| Package | Repo | Suffix | Rule |
|---------|------|--------|------|
| `keepalived` | AppStream | `.el{{ALMA_MAJOR}}.{{ARCH_RPM}}.rpm` | |
| `socat` | AppStream | `.el{{ALMA_MAJOR}}.{{ARCH_RPM}}.rpm` | |
| `chrony` | BaseOS | `.el{{ALMA_MAJOR}}.{{ARCH_RPM}}.rpm` | |
| `containerd.io`| Docker | `.el{{ALMA_MAJOR}}.{{ARCH_RPM}}.rpm` | **el8 LIMIT:** Docker stopped el8 builds after 1.6.32 |
| `net-snmp-libs`| **VARIES** | `.el{{ALMA_MAJOR}}.{{ARCH_RPM}}.rpm` | **el8 = BaseOS**, **el9 = AppStream** (CRITICAL) |
| `net-snmp-agent-libs` | AppStream | `.el{{ALMA_MAJOR}}.{{ARCH_RPM}}.rpm` | |
| `lm_sensors-libs` | **VARIES** | `.el{{ALMA_MAJOR}}.{{ARCH_RPM}}.rpm` | **el8 = BaseOS**, **el9 = AppStream** (CRITICAL) |
| `mariadb-connector-c` | AppStream | `.el{{ALMA_MAJOR}}.{{ARCH_RPM}}.rpm` | |
| `mariadb-connector-c-config` | AppStream | `.noarch.rpm` | |
| `libnftnl` | BaseOS | `.el{{ALMA_MAJOR}}.{{ARCH_RPM}}.rpm` | |
| `perl-interpreter` | BaseOS | `.el{{ALMA_MAJOR}}.{{ARCH_RPM}}.rpm` | Hardcoded fallback exists; search for suffix verification |
| `perl-libs` | BaseOS | `.el{{ALMA_MAJOR}}.{{ARCH_RPM}}.rpm` | |
| `tar/unzip/zip`| BaseOS | `.el{{ALMA_MAJOR}}.{{ARCH_RPM}}.rpm` | |

**Perl Dependency Note:** If you cannot confidently enumerate all 55+ perl sub-packages from the mirror, do NOT include `perl_rpms` in the JSON. Let the script use its hardcoded defaults.

---

## 5. Script Execution & Artifacts

Run the script from the project root:
```bash
./scripts/k8s_offline_downloader.sh \
  --k8s-version {{VERSION}} \
  --target-os {{OS}} \
  --arch {{ARCH}} \
  --output-dir {{DIR}} \
  --rpm-config {{JSON_FILE}} \
  --verify-checksums
```

### 5.1 Artifact Verification
| Archive | Target Size | Critical Content |
|---------|-------------|------------------|
| `binaries.tar.gz` | ~115 MB | `kubeadm`, `kubectl`, `kubelet`, `etcd`, `helm` |
| `images.tar.gz` | ~400 MB | **Raw Tar** (not gzip) images for K8s + Calico |
| `packages.tar.gz` | ~60 MB | `containerd.io`, `chrony`, `keepalived` + deps |
| `other/` | varies | `cfssl`, `cfssljson`, `calico.yml`, system RPMs |

---

## 6. Known Ansible Bug Fixes (The "SME" Knowledge)

After downloading, the AI should advise the user to check these common K8s Automation_Ansible pitfalls:

1.  **Jinja2 Version:** Ensure `Jinja2 >= 2.10` on the Ansible control node.
2.  **cfssl Path:** Copy `other/cfssl` to `/usr/local/bin/` on the control node.
3.  **etcd role Bug:** Fix `become: true` indentation in `roles/etcd/tasks/main.yml`.
4.  **Hardening Bug:** Fix `product()` operator precedence in `roles/k8s_hardening/tasks/main.yml`.
5.  **ctr import Bug:** Add `umount` cleanup before `ctr import` in `roles/k8s_bundle_install/tasks/main.yml`.

---

## 7. Troubleshooting

- **404 Errors:** Re-run RPM research; point releases (e.g., `.alma.1`) often change filenames.
- **Checksum Fail:** Mirror might be out of sync. Retry without `--verify-checksums`. (Note: The script defaults to opt-in checksum verification).
- **Image Import Fail:** Verify `images.tar.gz` contains raw tarballs, not gzipped data.
