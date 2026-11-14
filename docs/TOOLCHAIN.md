# Build, Flash & Extension Toolchain (`kairos-rock5b`)

---

## 1. Prerequisites

- **Container Engine**: `podman` *(recommended)* or `docker` with `buildx`. On an `x86_64` workstation, ensure `qemu-user-static` (`binfmt_misc` `linux/arm64` emulation) is enabled for running `/kairos-init` in the target stage; on native ARM64 hosts/runners, builds execute natively.
- **Host Utilities**: `bash`, `make`, `sfdisk` (from `util-linux`), `sha256sum`, `cmp`, `grep`. Inside the upstream `AuroraBoot` container, `auroraboot`, `xorriso`, `mkfs.vfat`, `mcopy`/`mtools`, and `sfdisk` are already bundled.
- **On Target Rock 5B (optional pre-install SSH flash)**: `mtd-utils` (`flashcp`).

---

## 2. Standard `Makefile` Targets

```bash
make lint               # Tier 1: bash -n syntax check + zero-exposure/anchor guard
make build              # Build default arm64 OCI image (Backports profile + U-Boot)
make build-lts          # Build Debian Stable LTS profile OCI image
make verify-image       # Tier 2: inspect kernel, initrd drivers, DTB, U-Boot, and release metadata
make build-installer    # Tier 3: build bootable kairos-rock5b-installer.raw via AuroraBoot
make clean              # Remove generated ./build artifacts directory
```

---

## 3. Build Parameter Reference (`versions.conf` & `Makefile`)

All image versions and optional kernel pins live centrally in [`versions.conf`](../versions.conf), while build selection flags can be overridden on the [`Makefile`](../Makefile) command line:

| Variable | Default / Source | Purpose |
| :--- | :--- | :--- |
| `CONTAINER_ENGINE` | `podman` | Container CLI used for builds, verification, and `AuroraBoot` (`podman` or `docker`) |
| `REGISTRY` / `IMAGE_NAME` | Configurable (see [`Makefile`](../Makefile)) / `kairos-rock5b` | Destination registry namespace and repository name |
| `BASE_IMAGE` | Pinned in [`versions.conf`](../versions.conf) | Base Debian slim OCI image fed to stage 3 of `Dockerfile` |
| `PROFILE` | `debian-trixie-bpo` | Selects `profiles/${PROFILE}.yaml` (`debian-trixie-bpo` for Backports, `debian-trixie` for Stable LTS) |
| `BPO_KERNEL_VERSION` / `LTS_KERNEL_VERSION` | Pinned in [`versions.conf`](../versions.conf) (empty = latest) | Optional per-profile Debian kernel ABI pin (e.g., `<x.y.z>+deb...`), mapped to `KERNEL_PACKAGE` |
| `KERNEL_VERSION` | Profile's `BPO_` / `LTS_KERNEL_VERSION` | Command-line override for the Debian kernel ABI or `linux-image-*` package specifier |
| `KERNEL_PACKAGE` | Derived (`linux-image-arm64` when unpinned) | Debian kernel package passed into `15-kernel.yaml` while skipping `kairos-init`'s built-in `installKernel` |
| `VARIANT` | `k3s` | Workload variant (`k3s`, `k0s`, or `core`) controlling external `KAIROS_INIT_ARGS` |
| `K3S_VERSION` | Pinned in [`versions.conf`](../versions.conf) | Orchestrator version passed via `--provider-k3s-version` when `VARIANT=k3s` |
| `KAIROS_INIT_VERSION` | Pinned in [`versions.conf`](../versions.conf) | Upstream `quay.io/kairos/kairos-init` tag |
| `AURORABOOT_VERSION` | Pinned in [`versions.conf`](../versions.conf) | Upstream `quay.io/kairos/auroraboot` tag |
| `UBOOT_VERSION` | Pinned in [`versions.conf`](../versions.conf) | Upstream `u-boot/u-boot` release tag compiled from source in `AS uboot` |
| `KAIROS_VERSION` | Pinned in [`versions.conf`](../versions.conf) | Base SemVer prefix stamped into `KAIROS_VERSION` / `KAIROS_RELEASE` (`<ver>-<profile>-<kver>`) |
| `CLOUD_CONFIG` | `./docs/examples/cloud-config.example.yaml` | Node `cloud-config.yaml` embedded into `/config.yaml` by `make build-installer` |
| `OUTPUT_DIR` | `./build` | Host directory receiving `kairos-rock5b-installer.raw`, `.sha256`, and extracted U-Boot binaries |

### Build Examples

```bash
# Build and verify default Backports + k3s profile:
make build verify-image

# Build and verify Debian Stable LTS profile:
make build-lts
make verify-image PROFILE=debian-trixie

# Inject a specific Debian kernel ABI on top of a profile without editing profiles/:
make build KERNEL_VERSION=<kernel-abi>

# Minimal core node (no Kubernetes distribution baked in):
make build VARIANT=core

# Override registry namespace:
make build REGISTRY=ghcr.io/<your-org>
```

---

## 4. Upstream Mainline U-Boot + `rkbin` Builder Stage

[`Dockerfile`](../Dockerfile) compiles U-Boot in an isolated `FROM --platform=${BUILDPLATFORM:-linux/arm64} ... AS uboot` stage so builds run at native host CPU speed (`gcc-aarch64-linux-gnu` cross-compilation on `x86_64`, cached across rootfs/profile edits):
- Pulls upstream `u-boot/u-boot` at `UBOOT_VERSION` together with pinned `rockchip-linux/rkbin` DRAM initialization TPL and TF-A BL31 binaries (`RKBIN_COMMIT`, `RKBIN_DDR`, `RKBIN_BL31`).
- Compiles `rock5b-rk3588_defconfig` to emit:
  - `/usr/share/rock5b-uboot/u-boot-rockchip-spi.bin` (SPI NOR image for `/dev/mtd0`)
  - `/usr/share/rock5b-uboot/u-boot-rockchip.bin` (block-device image embedded at sector 64 of the MicroSD installer)

To update U-Boot or `rkbin`, update `UBOOT_VERSION` and `RKBIN_*` in [`versions.conf`](../versions.conf).

---

## 5. Raw Disk Installer Layout & Multi-Node Provisioning

[`scripts/build-installer-img.sh`](../scripts/build-installer-img.sh) invokes `auroraboot build-iso` rootlessly and repacks the output into `kairos-rock5b-installer.raw`:

| Byte / Sector Offset | Contents |
| :--- | :--- |
| Sectors `0`–`33` | Protective + primary GPT header (`disklabel: gpt`) |
| Sector `64` (`32 KiB`) | Raw `u-boot-rockchip.bin` (RK3588 BootROM fallback entry point when `/dev/mtd0` is blank) |
| Sector `32768` (`16 MiB` onward) | `COS_LIVE` FAT32 EFI System Partition (`/EFI/BOOT/BOOTAA64.EFI`, `/boot/{kernel,initrd,grub2/grub.cfg}`, `/dtb/rockchip/rk3588-rock-5b.dtb`, `/rootfs.squashfs`, `/config.yaml`) |

### Reusing One Flashed MicroSD Card Across Multiple Nodes
Once `kairos-rock5b-installer.raw` is written to a MicroSD card, mount partition 1 (`COS_LIVE`) and overwrite `/config.yaml` before moving the card to the next Rock 5B node:

```bash
sudo mkdir -p /mnt/cos-live
sudo mount /dev/sdX1 /mnt/cos-live
sudo install -m 0600 ./node-02-cloud-config.yaml /mnt/cos-live/config.yaml
sudo sync
sudo umount /mnt/cos-live
```

---

## 6. Extending Hardware or Repo Support (`profiles/<name>.yaml`)

To layer optional hardware firmware (for example `firmware-misc-nonfree` for Mali-G610 `panthor` compute or Wi-Fi/BT firmware) without touching [`Dockerfile`](../Dockerfile):

1. Create `profiles/custom-example.yaml`:
   ```yaml
   name: "Custom Rock 5B Add-Ons"
   stages:
     install:
       - name: "Install optional firmware"
         packages:
           install:
             - firmware-misc-nonfree
           refresh: false
           upgrade: false
   ```
2. Pass it externally at build time:
   ```bash
   make build PROFILE=custom-example
   ```

---

## 7. Hardware Troubleshooting (SPI Flash & UART2 Serial Console)

- **Verify or Force-Flash `/dev/mtd0` over SSH (`flash-spi-uboot.sh`)**:
  ```bash
  # Skips writing if /dev/mtd0 already matches u-boot-rockchip-spi.bin:
  sudo ./scripts/flash-spi-uboot.sh /usr/share/rock5b-uboot/u-boot-rockchip-spi.bin

  # Unconditionally re-flash /dev/mtd0:
  sudo ./scripts/flash-spi-uboot.sh --force /usr/share/rock5b-uboot/u-boot-rockchip-spi.bin
  ```
- **UART2 Serial Console (`1500000 8N1`)**: Connect a 3.3V USB-UART adapter capable of `1.5 Mbps` baud (e.g., CP2102N / FT232H / CH340G) to Radxa Rock 5B 40-pin GPIO **Pin 6 (GND)**, **Pin 8 (TXD2)**, and **Pin 10 (RXD2)**:
  ```bash
  picocom -b 1500000 /dev/ttyUSB0
  ```
