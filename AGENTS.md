# kairos-rock5b Agent Guide

## 1. Executive Summary
**`kairos-rock5b`** is a universal, open-source container image builder and hardware bootstrap toolkit that produces immutable **Kairos Linux** (`linux/arm64`) operating system images for the **Radxa Rock 5B** (Rockchip RK3588) single-board computer using pure **official Debian (`deb.debian.org`)** packages and **upstream Denx Mainline U-Boot**.

**Core Principles:**
- **Strict Universality & Zero Environment Exposure**: This repository is a 100% public, universal open-source project for any Radxa Rock 5B user. Never commit user-specific, cluster-specific, or environment-specific hostnames, domain names, LAN IP subnets, SSH keys, credentials, or cluster-specific storage/ingress choices anywhere in code, Dockerfiles, profiles, scripts, examples, tests, or documentation (including inside `AGENTS.md`, `CONTEXT.md`, and `docs/`). Always use standard RFC 5737 (`192.0.2.0/24`) and RFC 2606 (`example.com`, `rock5b-node-01`) placeholders.
- **Version- & Kernel-Agnostic Documentation**: Never hardcode ephemeral component, kernel, or orchestrator versions inside `README.md`, `AGENTS.md`, `CONTEXT.md`, or `docs/*.md`. Keep pinned component versions and optional kernel ABI pins centrally in [`versions.conf`](./versions.conf) (included by [`Makefile`](./Makefile) and sourced by CI/scripts), and describe Debian kernel tracks generically (`*-backports` vs stable LTS).
- **Config Over Branching Code (`PROFILE` x External `KAIROS_INIT_ARGS`)**: Keep [`Dockerfile`](./Dockerfile) completely free of `if/else` or `case` logic. Pass `PROFILE`, `BASE_IMAGE`, `KERNEL_PACKAGE`, `KAIROS_INIT_ARGS`, and pinned tool versions from [`versions.conf`](./versions.conf) / [`Makefile`](./Makefile), letting declarative `kairos-init -x` stage extensions (`15-kernel.yaml`, `profiles/common.yaml`, and `profiles/${PROFILE}.yaml`) drive kernel selection, APT repositories, pins, Rock 5B packages, and `/etc/dracut.conf.d/50-rock5b.conf`.
- **Self-Describing OCI Tags & Node Metadata**: Every built image dynamically resolves the installed kernel version from `/lib/modules` and stamps its OCI tags (`<profile>-<kernel_ver>-<variant>[-<orchestrator_ver>]`), `/etc/os-release` (`PRETTY_NAME`), and `/etc/kairos-release` (`KAIROS_VERSION`, `KAIROS_RELEASE`, `KAIROS_PROFILE`, `KAIROS_KERNEL_VERSION`), validated via `/kairos-init validate`.
- **SPI NOR Flash + NVMe Boot First**: Compiles upstream Denx U-Boot (`rock5b-rk3588_defconfig` + pinned `rkbin` blobs) in an isolated multi-stage builder (`u-boot-rockchip-spi.bin` + `u-boot-rockchip.bin`), and pairs it with `/usr/sbin/rock5b-sync-boot` (`findmnt`-safe DTB sync to `COS_GRUB` + `cmp`-gated `/dev/mtd0` SPI flashing) for pure NVMe A/B atomic boots.
- **Solo Maintainer Linear-`main` Workflow**: Commit directly to `main` (or merge feature branches via `git merge --ff-only`). Never push to remote (`git push`) without explicit user confirmation.

---

## 2. Knowledgebase Routing Table

Read the relevant reference document before performing any task:

| Document | Path | When to Read |
|----------|------|--------------|
| **Domain Context & Glossary** | [`CONTEXT.md`](./CONTEXT.md) | Understanding the pure-Debian profile architecture, hardware components (`RK3588`, `RTL8125B`, SPI NOR `/dev/mtd0`, NVMe), and repository layout. |
| **Hardware & Driver Support** | [`docs/HARDWARE.md`](./docs/HARDWARE.md) | Checking target Radxa Rock 5B hardware scope, Debian `linux-image-arm64` driver architecture, early-boot initrd dependency graph, and Backports vs Stable LTS trade-offs. |
| **Repo & Boot Architecture** | [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md) | Understanding how `profiles/` + external config drive `kairos-init`, the RK3588 boot chain (SPI U-Boot EFI -> NVMe GRUB -> SquashFS), Day-1/Day-2 flows, and `findmnt`-safe DTB sync. |
| **Conventions & Tagging Rules** | [`docs/CONVENTIONS.md`](./docs/CONVENTIONS.md) | Checking OCI tag grammar, `/etc/os-release` & `/etc/kairos-release` formatting, version-agnostic doc rules, or Zero Environment Exposure rules. |
| **Verification & Testing** | [`docs/TESTING.md`](./docs/TESTING.md) | Running static non-exposure checks, shell syntax checks, `/kairos-init validate`, container image structure verification, or `AuroraBoot` image smoke tests. |
| **Build & Flash Toolchain** | [`docs/TOOLCHAIN.md`](./docs/TOOLCHAIN.md) | Building ARM64 OCI images with `podman`/`docker buildx`, upstream U-Boot cross-compilation, `AuroraBoot` raw installers, or SPI flash (`flashcp`). |

---

## 3. Sandbox Execution Matrix

| Command Category | Sandbox Mode | Notes |
|------------------|--------------|-------|
| File reads, edits, `git status`, `git diff`, `git log`, `make lint` | **Standard Sandbox** (`BypassSandbox: false`) | Always run inside the sandbox. |
| `podman build`, `docker buildx build`, `verify-image`, `AuroraBoot` runs | **Unsandboxed** (`BypassSandbox: true`) | Requires host user namespace / container runtime socket and network access to pull base/kernel/U-Boot sources. |
| `git push`, `podman push` | **FORBIDDEN without confirmation** | Always ask the user for explicit confirmation before pushing commits or OCI images to remotes. |

---

## 4. Agent Hazards (Read Before Acting)

1. **Never Leak Environment-Specific Data**:
   - Before committing any change, verify that no real LAN IPs, private hostnames, domains, `#L<line>` anchors, or keys appear in any tracked file (`make check-anonymity`).
2. **RK3588 Early-Boot Kernel Modules in `initramfs`**:
   - Generic Debian `linux-image-arm64` kernels leave Rockchip buses, regulators, PHYs, and storage/NIC drivers modular (`=m`). Ensure `profiles/common.yaml` lists canonical Debian `.ko` basenames in `/etc/dracut.conf.d/50-rock5b.conf` before `kairos-init` builds `/boot/initrd`, and verify both `lsinitrd` and `modules.builtin` via `scripts/verify-image.sh`.
3. **Avoid Dual RW VFAT Mounts on `COS_GRUB`**:
   - During `kairos-agent install` and `reset`, `COS_GRUB` (`FAT32`) is already mounted read-write on the host when `after-install` / `after-reset` hooks fire. Always route ESP DTB synchronization through `/usr/sbin/rock5b-sync-boot`, which checks `findmnt -rn -S "${ESP_DEV}" -o TARGET` and reuses an existing mount rather than mounting a second time.
4. **Keep `KAIROS_INIT_VERSION` Intact & `/etc/kairos-release` SemVer Consistent**:
   - `kairos-agent` enforces a `KAIROS_INIT_VERSION` downgrade check during upgrades, and `kairos-operator` compares `${KAIROS_VERSION}-${KAIROS_SOFTWARE_VERSION_PREFIX}${KAIROS_SOFTWARE_VERSION}` between host and target images. Stamp both `KAIROS_VERSION` and `KAIROS_RELEASE` identically and never remove `KAIROS_INIT_VERSION`.
5. **Check Local Link Paths Carefully**:
   - Note that inside `AGENTS.md` (at repo root), links to `Makefile` and `Dockerfile` must use `./Makefile` and `./Dockerfile`. Keep all Markdown links relative to their containing file.
