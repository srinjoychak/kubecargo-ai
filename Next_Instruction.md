# kubecargo-ai — Handoff & Next Instructions

## 1. What This Project Is

**kubecargo-ai** is an AI-powered offline Kubernetes bundle generator for air-gapped deployments.

You give it a Kubernetes version and a target OS. It automatically resolves all component versions
from authoritative sources and downloads everything into three ready-to-deploy tarballs:

| Output | Size | Contents |
|--------|------|----------|
| `binaries.tar.gz` | ~115 MB | kubeadm, kubelet, kubectl, etcd, helm, crictl, cfssl, socat, keepalived |
| `images.tar.gz` | ~380 MB | All required container images (kube-*, CoreDNS, pause, Calico) |
| `packages.tar.gz` | ~55 MB | RHEL/AlmaLinux RPMs (containerd.io, chrony, keepalived + deps) |
| `download_manifest.json` | — | Full version manifest |
| `other/` | — | cfssl, yq, Calico manifest, CIS scripts |

**Target audience:** Teams deploying Kubernetes in air-gapped environments — government/defense
(DoD IL4/IL5, DISA STIG), critical infrastructure, banking, healthcare, manufacturing.

**What makes it different from kubespray/RKE2/k3s/Zarf:** AI-driven co-resolution of ALL
component versions from authoritative sources in one pass. No manual version hunting. No other
tool does this.

---

## 2. Repository State (as of this handoff)

**Branch:** `master`
**Tracked files:**

```
.gitignore
CLAUDE.md
LICENSE
README.md
scripts/k8s_offline_downloader.sh   ← core engine (v2.4.0, 2181+ lines)
skills/claude-code.skill.md         ← AI workflow for Claude Code
skills/gemini.prompt.md             ← AI workflow for Gemini
tools/rpm-research.sh               ← auto-generates rpm_versions.json
```

### Work completed this session

| Commit | Change |
|--------|--------|
| `f5b04b7` | `--arch amd64\|arm64` flag — parameterizes all 9 binary URLs + 93 RPM arch refs |
| `93da166` | Per-phase exit codes + `print_summary()` box — exit 0/1/2 by severity |
| `38121f2` | `--verify-checksums` flag + `verify_checksum()` SHA256 helper |
| `22f29b1` | `tools/rpm-research.sh` — queries AlmaLinux/Docker mirrors live |
| `3f04719` | `skills/gemini.prompt.md` — single-shot Gemini prompt template |
| `9df3921` | `skills/claude-code.skill.md` — 900-line Claude Code conversational skill |
| `c1ba9a8` | Fix: grep pattern bug in rpm-research.sh |
| `13db345` | Fix: PLATFORM variable stale after --arch |

---

## 3. Git History Note — VN-Squad Commit

Commit `a9b9d87 feat: install VN-Squad v3 multi-agent orchestration layer` is still present
in git history. All VN-Squad files have been removed from the current working tree and
`.gitignore` prevents them from ever being re-committed, but the historical commit still
exists and is visible in `git log`.

**To fully purge it from history**, run:

```bash
# Install git-filter-repo (one-time)
pip install git-filter-repo

# Rewrite history to remove the commit's files
git filter-repo --invert-paths \
  --path AGENTS.md \
  --path agents.json \
  --path package.json \
  --path scripts/gemini-ask.js \
  --path scripts/vn3/ \
  --path .claude/ \
  --path .vn-squad/ \
  --force

# Force-push rewritten history (destructive — coordinate with all collaborators first)
git push origin master --force
```

**Do this only if:** you need a clean audit history or are concerned about secret/config
exposure in the old commit. If the repo is private and the VN-Squad files contain no secrets,
this is optional.

---

## 4. How to Test the New Code

### Prerequisites

On a Linux x86_64 machine with internet access:

```bash
# Required
docker   # or skopeo or containerd (ctr)
curl
tar
jq

# Optional but recommended for RPM downloads
yum-utils   # provides yumdownloader
# OR
dnf
```

---

### Test A — Basic dry-run (no downloads, safe to run anywhere)

```bash
cd /path/to/kubecargo-ai

./scripts/k8s_offline_downloader.sh \
  --k8s-version v1.32.4 \
  --target-os el9 \
  --dry-run
```

**Expected:** Version summary printed, phase-by-phase DRY-RUN lines, summary box at the end
showing `✓ X/X downloaded` for all phases, `Exit 0: All downloads successful`.

---

### Test B — arm64 architecture flag

```bash
./scripts/k8s_offline_downloader.sh \
  --k8s-version v1.32.4 \
  --arch arm64 \
  --dry-run
```

**Expected:** All binary URLs show `arm64` (e.g., `bin/linux/arm64/kubectl`), RPM URLs show
`aarch64` (e.g., `keepalived-2.2.8-6.el9.aarch64.rpm`). Summary box appears.

---

### Test C — Invalid arch rejection

```bash
./scripts/k8s_offline_downloader.sh \
  --k8s-version v1.32.4 \
  --arch s390x \
  --dry-run
echo "Exit: $?"
```

**Expected:** `[ERROR] Invalid --arch 's390x'. Must be 'amd64' or 'arm64'`, exit code 1.

---

### Test D — rpm-research.sh (requires internet, ~60s)

```bash
./tools/rpm-research.sh --target-os el9 --output /tmp/rpm_versions.json
jq 'keys' /tmp/rpm_versions.json
jq '.keepalived.core_rpms | length' /tmp/rpm_versions.json   # expect 6
jq '.keepalived.perl_rpms' /tmp/rpm_versions.json             # expect [] (soft skip)
```

**Expected:** 13/14 packages found (`perl-interpreter` is a known soft-skip — its index
entry is not in the AlmaLinux top-level HTML listing; the main script falls back to its
hardcoded table). Valid JSON written, exit 0.

---

### Test E — Full real download (needs ~600 MB disk, internet, docker)

```bash
./scripts/k8s_offline_downloader.sh \
  --k8s-version v1.32.4 \
  --target-os el9 \
  --arch amd64 \
  --rpm-config /tmp/rpm_versions.json \
  --output-dir /tmp/k8s-bundle \
  --verify-checksums \
  --debug
```

**Expected outputs:**
```
/tmp/k8s-bundle/
  binaries.tar.gz        (~115 MB)
  images.tar.gz          (~380 MB)
  packages.tar.gz        (~55 MB)
  download_manifest.json
  other/
    cfssl
    cfssljson
    yq_linux_amd64
    calico/calico_v3.29.0.yml
    cis_hardening_scripts/
```

---

## 5. How to Verify After Testing

### Exit codes

| Code | Meaning | Action |
|------|---------|--------|
| 0 | All downloads successful | Proceed to deployment |
| 1 | **CRITICAL** — Phase 4 (other/) failures | RPMs Ansible needs are missing — must fix before deploy |
| 2 | Partial failure (Phase 1/2/3) | Bundle is usable but incomplete — check which phase failed |

### Verify tarball contents

```bash
# Binaries — must include kubeadm, kubectl, kubelet, etcd, helm, crictl, cfssl
tar -tzf /tmp/k8s-bundle/binaries.tar.gz | sort

# Images — must include kube-apiserver, kube-controller-manager, kube-proxy,
#           kube-scheduler, coredns, pause, calico/*
tar -tzf /tmp/k8s-bundle/images.tar.gz | sort

# Packages — must include containerd.io, chrony, keepalived RPMs
tar -tzf /tmp/k8s-bundle/packages.tar.gz | sort

# Manifest — check all versions are resolved (no nulls)
jq . /tmp/k8s-bundle/download_manifest.json

# Other/ — Ansible fatal if any of these are missing
ls -la /tmp/k8s-bundle/other/
ls -la /tmp/k8s-bundle/other/cis_hardening_scripts/
```

### Verify checksums (if --verify-checksums was used)

Look for `SHA256 OK:` lines in the output for kubeadm, kubectl, kubelet, and helm.
Any `SHA256 MISMATCH` line is a corrupted download — delete and re-run.

### Verify image files are valid tar (not gzip)

```bash
# Images are stored as raw POSIX tar (NOT gzip) — this is intentional for ctr import
file /tmp/k8s-bundle/other/../images/*.tar.gz   # should say "POSIX tar archive"
```

---

## 6. How to Handle Failures

### Phase 1 — Binary download failures

```
Symptom: [ERROR] Failed to download kubeadm
Cause:   GitHub/dl.k8s.io rate limit or network timeout
Fix:     Re-run with --skip-images --skip-packages --skip-other to retry only binaries
         Add --proxy http://your-proxy:port if behind a proxy
```

### Phase 2 — Image pull failures

```
Symptom: [ERROR] Failed to pull registry.k8s.io/kube-apiserver:v1.32.4
Cause:   Docker not running, or image registry unreachable
Fix:     systemctl start docker
         Re-run with --skip-binaries --skip-packages --skip-other
         Try: docker pull registry.k8s.io/pause:3.10 manually to test
```

### Phase 3 — RPM package failures (containerd, chrony, keepalived)

```
Symptom: [WARN] All download strategies failed for containerd.io
Cause:   Mirror URL stale (AlmaLinux updates packages regularly)
Fix:     Run tools/rpm-research.sh to get current URLs:
           ./tools/rpm-research.sh --target-os el9 --output /tmp/rpm_versions.json
         Re-run with --rpm-config /tmp/rpm_versions.json
```

### Phase 4 — other/ RPM failures (exit code 1 — CRITICAL)

```
Symptom: Exit code 1, missing tar/unzip/zip RPMs in other/
Cause:   Same as Phase 3 — stale mirror URLs
Fix:     Run tools/rpm-research.sh, then re-run with --rpm-config
         OR: use --existing-bundle /path/to/previous/K8s_bundle to copy from a
             working bundle:
           ./scripts/k8s_offline_downloader.sh \
             --k8s-version v1.32.4 \
             --existing-bundle /old/bundle \
             --skip-binaries --skip-images --skip-packages
```

### socat / keepalived binary not found

```
Symptom: [WARN] socat binary not found after all strategies
Cause:   RPM extraction failed and no system socat available
Fix:     The binary will be skipped in binaries.tar.gz but is included
         as an RPM in packages.tar.gz — Ansible installs it from there.
         Acceptable unless you need the standalone binary.
```

### SHA256 mismatch

```
Symptom: [ERROR] SHA256 MISMATCH: kubectl
Cause:   Corrupted download (partial transfer, mitm, disk error)
Fix:     Delete the output dir and re-run. If it recurs, check disk health.
```

---

## 7. Next Development Steps

### Priority 1 — Validate arm64 bundles end-to-end

The `--arch arm64` flag parameterizes all URLs but has only been tested in dry-run.
A real arm64 download test is needed on an arm64 Linux host (or with cross-download
acceptance on x86_64):

```bash
# On x86_64, download arm64 binaries (they are static, so cross-download works)
./scripts/k8s_offline_downloader.sh \
  --k8s-version v1.32.4 \
  --arch arm64 \
  --skip-images \   # images need arm64 host to pull correctly
  --target-os el9 \
  --output-dir /tmp/k8s-arm64-bundle
```

Known gap: AlmaLinux `aarch64` RPM availability on Docker mirrors needs live verification.

### Priority 2 — Fix perl-interpreter discovery in rpm-research.sh

The AlmaLinux BaseOS HTML index does not list `perl-interpreter` in its top-level
directory listing (possibly due to pagination or indexing). The script correctly falls
back to the hardcoded version in the main script, but ideally `rpm-research.sh` should
resolve it. Options:
- Try fetching the repodata XML directly: `BaseOS/x86_64/os/repodata/primary.xml.gz`
- Parse the RPM metadata rather than the HTML listing

### Priority 3 — Purge VN-Squad commit from git history

See Section 3 above. Use `git filter-repo` if audit-clean history is required.

### Priority 4 — Add multi-arch image pull support

Currently, container images are pulled by the host's native docker/skopeo (which
auto-selects arch). For cross-arch image bundling (pull arm64 images on x86_64 host),
add `--platform linux/arm64` to docker pull and skopeo copy calls:

```bash
# In download_images(), when ARCH=arm64:
docker pull --platform linux/arm64 ${image}
# OR
skopeo copy --override-arch arm64 docker://${image} docker-archive:${tarfile}
```

### Priority 5 — Automate RPM version updates via CI

`tools/rpm-research.sh` currently runs manually. A GitHub Actions workflow could:
1. Run `rpm-research.sh` on a schedule (weekly)
2. Commit updated `rpm_versions.json` to the repo as a reference file
3. Alert on any packages that go missing from mirrors

### Priority 6 — Extend to other stacks (kubecargo generalization)

The pattern (version + OS → resolve → download → package) is proven. Highest-value
extension targets identified in research:
- **Monitoring stack** (Prometheus + Grafana + Loki) — Helm charts + images
- **Database operators** (CloudNativePG, MongoDB Operator) — explicit air-gap demand
- **Istio** — charts + images + CRDs

Each would be a new `download_<stack>.sh` script + corresponding skill file, driven by
the same AI orchestration pattern.
