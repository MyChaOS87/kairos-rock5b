# `kairos-rock5b` — Immutable Kairos Linux for Radxa Rock 5B (`RK3588`)

> [!WARNING]
> - **Experimental**: This project is experimental and under active development. Flashed bootloaders (`U-Boot` on `/dev/mtd0`) and full-disk NVMe installations modify hardware storage — always back up existing data before provisioning.
> - **AI Disclaimer**: This repository (Dockerfiles, profiles, scripts, and documentation) was mainly AI-generated, with human supervision.

Universal **Kairos** (`linux/arm64`) immutable OS container images built strictly from **100% official Debian (`deb.debian.org`)** packages and **upstream Denx Mainline U-Boot** for the **Radxa Rock 5B** SBC:
- **Zero third-party OS/kernel APT repos**: Uses declarative `kairos-init -x` stage-extension profiles (`profiles/debian-trixie-bpo.yaml` for newer mainline kernels via official `*-backports`, or `profiles/debian-trixie.yaml` for stock Debian stable LTS) and validates the finished image with `/kairos-init validate`.
- **Config over branching code**: Central [`versions.conf`](./versions.conf), external [`Makefile`](./Makefile) arguments, and declarative YAML profiles drive everything inside a branchless [`Dockerfile`](./Dockerfile).
- **Pure NVMe boot via SPI flash**: Compiles `rock5b-rk3588_defconfig` from upstream Denx U-Boot + pinned `rkbin` blobs in an isolated builder stage, bundles `/usr/share/rock5b-uboot/u-boot-rockchip{-spi,}.bin`, and runs `/usr/sbin/rock5b-sync-boot` on install/upgrade to sync `rk3588-rock-5b.dtb` onto `COS_GRUB` and idempotently flash `/dev/mtd0` only when bytes differ (`cmp -s`).
- **Cloud-native & storage ready**: Bundles `k3s` (or `k0s` / bare `core`), `open-iscsi` (`iscsid`), `cryptsetup`, `nfs-common`, `mtd-utils`, and `firmware-realtek` (`RTL8125B` 2.5GbE).

---

## 1. OCI Tags & Profile Compatibility Matrix

```text
# Immutable version-pinned tag:
<registry>/kairos-rock5b:<profile>-<kernel_ver>-<variant>[-<orchestrator_ver>]

# Rolling profile tag:
<registry>/kairos-rock5b:<profile>-<variant>
```

| Rolling Profile Tag | Kernel Source (`100% deb.debian.org`) | Notes |
| :--- | :--- | :--- |
| `<profile=debian-trixie-bpo>-<variant>` *(Default)* | Official Debian `*-backports` (`linux-image-arm64`) | Declares APT `*-backports` `Pin-Priority: 990` in `before-install` for mainline hardware/DTB updates |
| `<profile=debian-trixie>-<variant>` | Official Debian stable LTS (`linux-image-arm64`) | Stock Debian stable kernel with zero extra APT repos |

### Extensible Profile Architecture (`profiles/*.yaml`)

| `PROFILE` | Base Image | Kernel Track | Extensibility |
| :--- | :--- | :--- | :--- |
| **`debian-trixie-bpo`** | Debian slim (pinned in [`versions.conf`](./versions.conf)) | Debian Backports *(Default)* | Newer mainline Linux kernel & firmware via official backports |
| **`debian-trixie`** | Debian slim (pinned in [`versions.conf`](./versions.conf)) | Debian Stable LTS | Conservative LTS kernel baseline |

Adding a new kernel/repo profile or orchestrator flag requires only adding a `profiles/<name>.yaml` file and passing `PROFILE=<name>` + `KAIROS_INIT_ARGS="..."` to `make build`. Specific kernel ABI releases can be injected centrally in [`versions.conf`](./versions.conf) (`BPO_KERNEL_VERSION` / `LTS_KERNEL_VERSION`) or per invocation (`make build KERNEL_VERSION=<abi>`).

---

## 2. Hardware Support Scope

Out of the box, `kairos-rock5b` targets **headless Radxa Rock 5B (`RK3588`) NVMe + SPI flash operation**:
- **Core Hardware Supported**: PCIe 3.0 x4 M.2 NVMe (`/dev/nvme0n1`), 16 MB SPI NOR flash (`/dev/mtd0`), Realtek `RTL8125B` 2.5GbE LAN (`r8169` + `firmware-realtek`), MicroSD/eMMC, USB 2.0/3.0/Type-C, RK806/I2C PMIC + CPU DVFS, autonomous PWM heatsink fan + TSADC thermal control, UART2 serial console (`1500000 8N1`), hardware RNG/RTC/watchdog, and `open-iscsi`/`dm_crypt`/`nfs-common` storage primitives.
- **Optional Add-Ons / Non-Goals**: Mali-G610 (`panthor`) / Wi-Fi firmware can be layered cleanly via custom `profiles/<name>.yaml`; out-of-tree vendor BSP kernels and proprietary `rknpu2`/`mpp` blobs are explicit non-goals.

See [`docs/HARDWARE.md`](./docs/HARDWARE.md) for the full subsystem/driver matrix and early-boot dependency chain.

---

## 3. Quickstart: Setting Up a Node

### Step 1: Prepare `cloud-config.yaml` & Build the Installer Image

Build an OCI image (or pass an existing `<registry>/kairos-rock5b:<tag>` via `IMAGE=...`), copy [`docs/examples/cloud-config.example.yaml`](./docs/examples/cloud-config.example.yaml) to `cloud-config.yaml`, set your `hostname`, `ssh_authorized_keys`, networking, and optional orchestrator settings, then generate the `.raw` installer via `AuroraBoot`:

```bash
cp docs/examples/cloud-config.example.yaml cloud-config.yaml
$EDITOR cloud-config.yaml

make build
make build-installer CLOUD_CONFIG=./cloud-config.yaml OUTPUT_DIR=./build
```

Flash the generated installer image to a MicroSD card:

```bash
sudo dd if=./build/kairos-rock5b-installer.raw of=/dev/sdX bs=4M status=progress oflag=sync
```

*(Note: `make build-installer` extracts `./build/u-boot-rockchip-spi.bin` and `./build/u-boot-rockchip.bin`—compiled from upstream Denx U-Boot `rock5b-rk3588_defconfig`—and embeds `u-boot-rockchip.bin` at sector 64 of `kairos-rock5b-installer.raw` alongside a FAT32 `COS_LIVE` EFI System Partition starting at sector 32768.)*

> **Provisioning multiple nodes?** You do not need to re-run `AuroraBoot` or `dd` the entire image for each node. Mount the `COS_LIVE` FAT32 partition on the MicroSD card between installs and replace `/config.yaml` with the next node's `cloud-config.yaml`.

---

### Step 2: Ensure SPI NOR Flash (`/dev/mtd0`) Has Mainline U-Boot EFI

The RK3588 silicon boots from NVMe only when Mainline U-Boot EFI is flashed to the onboard 16 MB SPI NOR flash (`/dev/mtd0`):

- **Case A — Migrating a board that already runs Linux (SSH access)**:
  Copy `./build/u-boot-rockchip-spi.bin` to the running node and flash `/dev/mtd0` before rebooting into the installer SD card (`flash-spi-uboot.sh` checks `/dev/mtd0` via `cmp -s` and skips writing if already identical):
  ```bash
  scp ./build/u-boot-rockchip-spi.bin scripts/flash-spi-uboot.sh user@192.0.2.11:/tmp/
  ssh -t user@192.0.2.11 "sudo apt-get update && sudo apt-get install -y mtd-utils && sudo /tmp/flash-spi-uboot.sh /tmp/u-boot-rockchip-spi.bin"
  ```
- **Case B — Brand-new board from zero (empty NVMe & empty SPI flash)**:
  1. Because `kairos-rock5b-installer.raw` embeds `u-boot-rockchip.bin` at sector 64 (`32 KiB`) before the `COS_LIVE` partition at `16 MiB`, the RK3588 BootROM boots the MicroSD card directly without needing SPI flash pre-populated.
  2. During installation onto `/dev/nvme0n1`, [`system/oem/20_rock5b_hardware.yaml`](./system/oem/20_rock5b_hardware.yaml) invokes `/usr/sbin/rock5b-sync-boot` to **automatically flash `/dev/mtd0`** with `u-boot-rockchip-spi.bin` so subsequent boots run directly from NVMe.

---

### Step 3: Boot, Auto-Install & Log In

1. Power on the Rock 5B with the installer media attached.
2. Kairos formats `/dev/nvme0n1` (`COS_GRUB`, `COS_OEM`, `COS_RECOVERY`, `COS_STATE`, `COS_PERSISTENT`), installs the OS, syncs `rk3588-rock-5b.dtb` to `COS_GRUB`, verifies/updates `/dev/mtd0`, and powers off cleanly (`install.poweroff: true`).
   *(Hardware note: on PoE HAT or 5V-powered Rock 5B boards, the green 5V power rail LED stays lit after kernel `poweroff` halts the SoC—typically ~3 minutes after power-on—until power is physically cycled.)*
3. **Unplug the installer media and power on**. The board boots Kairos directly from NVMe; log in via SSH using the user and key from your `cloud-config.yaml`:
   ```bash
   ssh kairos@192.0.2.11
   ```

---

## 4. Day-2 Atomic Upgrades

- **Standalone Node**:
  ```bash
  sudo kairos-agent upgrade --source oci:<registry>/kairos-rock5b:<pinned-release-tag>
  ```
- **Kubernetes Cluster (`kairos-operator`)**:
  With [Kairos Operator](https://kairos.io/operator-docs/installation/) installed on the cluster, apply a **version-stamped `NodeOpUpgrade`** resource to roll out OS + Kernel + orchestrator updates atomically across nodes.

> [!IMPORTANT]
> `NodeOpUpgrade` is a single-run resource in `kairos-operator` (`metadata.name` is also copied onto the child `NodeOp` label `nodeopupgrade.kairos.io/name`). Keep `metadata.name` **`<= 63` characters** and always bump `metadata.name` whenever updating `spec.image`.

```yaml
apiVersion: operator.kairos.io/v1alpha1
kind: NodeOpUpgrade
metadata:
  name: rock5b-upgrade-<release-id>
  namespace: kairos-operator
spec:
  image: <registry>/kairos-rock5b:<profile>-<kernel_ver>-<variant>-<orchestrator_ver>
  concurrency: 1
  stopOnFailure: true
  upgradeActive: true
  upgradeRecovery: false
  nodeSelector:
    matchLabels:
      kairos.io/managed: "true"
```

---

## 5. Documentation & How the Repo Works

| Document | Contents |
| :--- | :--- |
| [`docs/HARDWARE.md`](./docs/HARDWARE.md) | Target RK3588 hardware scope, Debian kernel driver architecture, early-boot initrd graph, and Backports vs Stable LTS trade-offs |
| [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md) | Config-over-code build pipeline, division of labor with `kairos-init`, RK3588 boot sequence, Day-1/Day-2 sequence flows, and NVMe partition layout |
| [`docs/TOOLCHAIN.md`](./docs/TOOLCHAIN.md) | `Makefile` variables, U-Boot + `rkbin` cross-build, multi-node `COS_LIVE` usage, custom profiles, and SPI/UART2 debugging |
| [`docs/CONVENTIONS.md`](./docs/CONVENTIONS.md) | OCI tag grammar, `/etc/kairos-release` versioning, version-agnostic doc rules, declarative profile conventions, and Zero Environment Exposure rules |
| [`docs/TESTING.md`](./docs/TESTING.md) | 3-tier verification guide (`make lint`, `make verify-image`, `make build-installer`) |
| [`docs/examples/cloud-config.example.yaml`](./docs/examples/cloud-config.example.yaml) | Generic RFC 5737 / RFC 2606 starting configuration for Rock 5B nodes |

---

## 6. License

[MIT License](./LICENSE)
