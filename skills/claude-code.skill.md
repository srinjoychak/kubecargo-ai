# K8s Offline Download Skill — Claude Code

## Purpose
This skill automates downloading ALL files needed for a `kubecargo-ai` air-gapped Kubernetes deployment.

## Workflow
You MUST follow the centralized logic defined in:
`skills/k8s_downloader_core.md`

## Instructions
1.  **Read Core Logic:** Immediately read `skills/k8s_downloader_core.md` to understand URLs, regexes, and the RPM research workflow.
2.  **Environment Check:** Use `Bash` to check if the current host is Linux x86_64 with internet access. If not, ask the user for SSH access to a suitable build server.
3.  **Gather Inputs:** Get K8s version, Target OS (el8/el9), Architecture (amd64/arm64), and Output Directory.
4.  **Research & Resolve:**
    *   Use `WebFetch` to get `constants.go` and extract versions.
    *   Use `WebFetch` to research current RPM filenames from AlmaLinux/Docker mirrors.
5.  **Execute:** Generate `rpm_versions.json` and run `./scripts/k8s_offline_downloader.sh`.
6.  **Verify:** Check archives and directory contents as specified in the core logic.
7.  **Advise:** Report results and provide the "SME Knowledge" (Ansible bug fixes) from the core logic.

## Tools
- `Bash`: Execution and environment checks.
- `WebFetch`: Live version and RPM research.
- `Read`: Load core logic and script source.
