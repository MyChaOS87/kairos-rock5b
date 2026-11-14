# Conventions & Tagging Standards (`kairos-rock5b`)

## 1. Strict Universality & Zero Environment Exposure Rule

> [!IMPORTANT]
> **`kairos-rock5b` is a 100% universal, public open-source project.**
> Never commit user-specific, cluster-specific, or environment-specific hostnames, domain names, LAN IP subnets, MAC addresses, SSH keys, private registry namespaces, or cluster-specific opinions anywhere in documentation, examples, profiles, or OEM configs (`Dockerfile`, `profiles/`, `system/`, `scripts/`, `docs/`, `README.md`, `CONTEXT.md`, `AGENTS.md`).

Always use standard documentation placeholders in examples and tests:
- **IPv4 Addresses & Subnets (RFC 5737)**: `192.0.2.0/24` (e.g., gateway `192.0.2.1`, VIP `192.0.2.10`, nodes `192.0.2.11`–`192.0.2.13`)
- **Domain Names (RFC 2606)**: `example.com`, `k8s.example.com`
- **Hostnames**: `rock5b-node-01`, `rock5b-node-02`, `rock5b-node-03`
- **SSH Keys**: `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExamplePublicKeyPlaceholderOnly user@example.com`
- **OCI Registry**: `<registry>/kairos-rock5b`

---

## 2. Version- & Setup-Agnostic Documentation Rule

- **Single source of truth for pinned versions**: Store concrete component tags, `RKBIN_*` refs, and optional kernel ABI pins (`BASE_IMAGE`, `BPO_KERNEL_VERSION`, `LTS_KERNEL_VERSION`, `K3S_VERSION`, `KAIROS_INIT_VERSION`, `AURORABOOT_VERSION`, `UBOOT_VERSION`, `KAIROS_VERSION`, `RKBIN_*`) centrally in [`versions.conf`](../versions.conf) (included by [`Makefile`](../Makefile) and sourced by CI/installer scripts, with standalone fallbacks in [`Dockerfile`](../Dockerfile)).
- **No hardcoded versions in prose or diagrams**: General documentation (`README.md`, `AGENTS.md`, `CONTEXT.md`, `docs/*.md`) describes kernel tracks and toolchains generically across official Debian releases without hardcoding ephemeral kernel, U-Boot, `kairos-init`, or orchestrator version numbers. Use symbolic placeholders such as `<profile>`, `<kernel_ver>`, `<variant>`, and `<orchestrator_ver>` when illustrating tag or release formats.
- **No stale line anchors**: Link to Markdown files by path only (`./docs/ARCHITECTURE.md`), never `#L<line>` anchors.

---

## 3. Config Over Branching Code

- **`Dockerfile` must remain branchless**: Never add shell `if`/`elif`/`case` branches inside [`Dockerfile`](../Dockerfile) to pick packages, repos, or providers.
- **Declarative Stage Extensions (`profiles/*.yaml`)**: Express repository additions, APT pins, package deltas, directories, and dracut drop-ins in `yip` YAML under [`profiles/`](../profiles/).
- **External Build Arguments**: Pass `PROFILE`, `BASE_IMAGE`, `KERNEL_PACKAGE` (resolved from `versions.conf` / `KERNEL_VERSION`), `KAIROS_INIT_ARGS`, and `VARIANT_LABEL` from [`Makefile`](../Makefile) or CI workflows.

---

## 4. OCI Tag Grammar

Every built OCI image is tagged using the external profile, dynamically detected kernel version from `/lib/modules`, and workload variant:

```text
# Immutable Pinned Tag:
<registry>/kairos-rock5b:<profile>-<kernel_ver>-<variant>[-<orchestrator_ver>]

# Rolling Profile Tag:
<registry>/kairos-rock5b:<profile>-<variant>
```

### Component Sanitization Rules
- `<profile>`: Lowercase declarative profile name (e.g., `debian-trixie-bpo`, `debian-trixie`).
- `<kernel_ver>`: Upstream numeric `major.minor.patch` version extracted from `/lib/modules/<kver>` with Debian ABI/architecture suffixes stripped (e.g., `<x.y.z>+deb...-arm64` -> `<x.y.z>`).
- `<variant>`: `k3s`, `k0s`, or `core`.
- `<orchestrator_ver>`: Orchestrator version with `+` replaced by `-` for OCI tag validity. Omitted when `<variant>` is `core`.

---

## 5. `/etc/os-release` & `/etc/kairos-release` Metadata

To ensure `kubectl get nodes -o wide`, `kairos-agent` upgrades, and `kairos-operator` preflight checks agree accurately:
- Stamp `/etc/os-release` `PRETTY_NAME`:
  ```ini
  PRETTY_NAME="Kairos (<profile> <kernel_ver> / <variant_label>)"
  ```
- Stamp `/etc/kairos-release` with identical SemVer `KAIROS_VERSION` and `KAIROS_RELEASE` (`<base_semver>-<profile>-<kernel_ver>`), alongside `KAIROS_PROFILE` and `KAIROS_KERNEL_VERSION`, while preserving `KAIROS_INIT_VERSION` (used by `kairos-agent` to guard against downgrades).

---

## 6. Commit Message Format

All commits follow the workspace convention:
```text
feat[(<topic>)]: <description>
chore[(<topic>)]: <description>
bugfix[(<topic>)]: <description>
```
- Active present tense, one heading only
- Use `*` for bullet points
