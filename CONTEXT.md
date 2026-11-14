# kairos-rock5b Context & Domain Glossary

## 1. Purpose
`kairos-rock5b` provides a reproducible, universal build pipeline for running **Kairos** (an immutable cloud-native A/B Linux distribution) on the **Radxa Rock 5B** (`RK3588` `arm64` SBC) using pure **official Debian (`deb.debian.org`)** packages and **upstream Denx Mainline U-Boot**.

Standard upstream Kairos images target generic x86_64/ARM64 ACPI servers or Raspberry Pi boards and lack the Rockchip RK3588 Device Tree (`rk3588-rock-5b.dtb`), PCIe 3.0 PHY / regulator initramfs modules, Realtek RTL8125B 2.5GbE firmware (`firmware-realtek`), and SPI NOR flash U-Boot EFI tooling needed for headless NVMe operation on the Radxa Rock 5B. `kairos-rock5b` bridges that gap cleanly using declarative `kairos-init -x` stage extensions (`profiles/*.yaml`) and an isolated multi-stage U-Boot builder.

---

## 2. Domain Glossary

| Term | Definition |
|------|------------|
| **Radxa Rock 5B (`RK3588`)** | 8-core ARM64 single-board computer (4x Cortex-A76 + 4x Cortex-A55) with M.2 PCIe 3.0 x4 NVMe, onboard 16 MB SPI NOR flash (`/dev/mtd0`), MicroSD slot, and Realtek RTL8125B 2.5GbE NIC (`r8169`). |
| **`PROFILE`** | Declarative `kairos-init -x` stage-extension profile (`debian-trixie-bpo` for `*-backports`, or `debian-trixie` for stable LTS) fed into the branchless `Dockerfile` from outside. |
| **`KAIROS_INIT_ARGS`** | External CLI arguments passed straight to `/kairos-init` from [`Makefile`](./Makefile)/CI (e.g., orchestrator provider flags for `k3s`/`k0s`, or empty for `core`) instead of branching shell code inside [`Dockerfile`](./Dockerfile). |
| **`kairos-init`** | Upstream Kairos container initializer bind-mounted at build time to install Kairos (`immucore`, `kairos-agent`), kernel, dracut initrd, and validate the resulting rootfs (`/kairos-init validate`). |
| **`AuroraBoot`** | Upstream Kairos Day-1 provisioning tool used to assemble a GPT + `FAT32` (`COS_LIVE`) bootable raw disk installer (`.raw`) alongside sector-64 `u-boot-rockchip.bin`. |
| **Upstream Mainline U-Boot** | Built from `u-boot/u-boot` (`rock5b-rk3588_defconfig`) + pinned `rockchip-linux/rkbin` DDR TPL/BL31 blobs in an isolated `AS uboot` builder stage, emitting `u-boot-rockchip-spi.bin` and `u-boot-rockchip.bin`. |
| **SPI NOR Flash (`/dev/mtd0`)** | 16 MB flash chip soldered onto the Rock 5B. Flashing Mainline U-Boot EFI (`u-boot-rockchip-spi.bin`) to `/dev/mtd0` enables pure NVMe GRUB (`BOOTAA64.EFI`) booting without a permanent MicroSD card. |

---

## 3. Repository Structure

```text
kairos-rock5b/
├── AGENTS.md                        # AI Agent guide, hazards & routing table
├── CONTEXT.md                       # Project overview, glossary & directory map
├── LICENSE                          # MIT License
├── Makefile                         # Build orchestration (includes versions.conf; lint/build/verify/installer targets)
├── versions.conf                    # Single source of truth for pinned versions & optional kernel ABI pins
├── README.md                        # Public quickstart, compatibility matrix, & Day-2 upgrade guide
├── Dockerfile                       # Branchless multi-stage build (upstream U-Boot + bind-mounted kairos-init)
├── .github/workflows/
│   └── build.yaml                   # Automated CI build & OCI publish across shipped profiles
├── profiles/
│   ├── common.yaml                  # Shared Rock 5B yip stage-extension (non-free-firmware, packages, dracut drivers, DTB staging)
│   ├── debian-trixie-bpo.yaml       # Declarative *-backports repo + kernel/firmware pin (Pin-Priority: 990)
│   └── debian-trixie.yaml           # Minimal profile selecting the stock Debian stable LTS kernel
├── docs/
│   ├── HARDWARE.md                  # Target RK3588 hardware scope, Debian kernel driver architecture & track comparison
│   ├── ARCHITECTURE.md              # Config-driven build pipeline, RK3588 boot chain, Day-1/Day-2 flows & NVMe layout
│   ├── CONVENTIONS.md               # OCI tag grammar, release metadata, version-agnostic doc & non-exposure rules
│   ├── TESTING.md                   # Verification tiers (static lint, /kairos-init validate, verify-image, AuroraBoot)
│   ├── TOOLCHAIN.md                 # Podman/Docker ARM64, U-Boot cross-build, AuroraBoot & SPI flash reference
│   └── examples/
│       └── cloud-config.example.yaml # Generic RFC 5737 / RFC 2606 starting configuration for Rock 5B nodes
├── scripts/
│   ├── rock5b-sync-boot.sh          # Installed to /usr/sbin/rock5b-sync-boot (findmnt-safe COS_GRUB DTB sync + cmp-gated SPI)
│   ├── verify-image.sh              # Container structure, metadata & initrd RK3588 driver verification
│   ├── build-installer-img.sh       # Rootless AuroraBoot -> GPT FAT32 COS_LIVE + sector-64 U-Boot .raw image
│   └── flash-spi-uboot.sh           # Standalone SSH helper with cmp -s wear guard
└── system/oem/
    └── 20_rock5b_hardware.yaml      # OEM runtime hooks for /var/lib/iscsi persistence, rock5b-sync-boot & iSCSI/multipath
```
