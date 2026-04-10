# K8s Offline Download Skill — OpenCode

## Purpose
Automated offline package downloader for air-gapped Kubernetes deployments using K8s Automation_Ansible.

## Single Source of Truth
This skill follows the centralized logic defined in:
`skills/k8s_downloader_core.md`

## Workflow Steps
1.  **Gather Inputs:** Get K8s version, Target OS (el8/el9), Architecture (amd64/arm64), and Output Directory.
2.  **Environment Audit:** Verify host is Linux with internet. If not, prompt for SSH or Docker execution host.
3.  **Research & Resolve:** 
    *   Fetch `constants.go` to extract CoreDNS/Pause/Etcd versions.
    *   Research live RPM versions from mirrors as specified in the core logic.
4.  **Execute:** Run `./scripts/k8s_offline_downloader.sh` with the generated `--rpm-config`.
5.  **Verify & Advise:** Perform archive verification and provide the "SME Knowledge" (Ansible bug fixes) from the core logic.

## Tools
- `bash`: Script execution and environment checks.
- `webfetch`: Live research for versions and RPMs.
- `read/write`: Config and manifest management.
