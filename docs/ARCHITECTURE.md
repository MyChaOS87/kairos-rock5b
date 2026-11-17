# Repository & Boot Architecture (`kairos-rock5b`)

This document explains how `kairos-rock5b` works end-to-end: how declarative configuration drives the branchless container build on top of upstream **Kairos**, how the Radxa Rock 5B boots from SPI NOR flash to NVMe, and how Day-1 installation (`AuroraBoot`) and Day-2 upgrades maintain Device Trees and U-Boot safely.

---

## 1. How the Repository Works: Config Over Branching Code

`kairos-rock5b` delegates OS initialization, dracut `initramfs` construction, Kubernetes/init provisioning, and image validation to upstream `kairos-init`, injecting Rock 5B hardware enablement cleanly through declarative `yip` **stage extensions** (`-x`) and an isolated multi-stage U-Boot builder. [`Dockerfile`](../Dockerfile) contains zero shell `if`/`elif`/`case` branches:

```mermaid
flowchart LR
    subgraph Inputs["External Config Inputs (versions.conf / Makefile / CI)"]
        Env["BASE_IMAGE, PROFILE, VARIANT,\nKERNEL_PACKAGE, KAIROS_INIT_ARGS,\nKAIROS_VERSION, KAIROS_INIT_VERSION, UBOOT_VERSION"]
    end

    subgraph Repo["Declarative Hardware and Boot Assets"]
        Common["profiles/common.yaml\nnon-free-firmware, Rock 5B packages,\n/etc/dracut.conf.d/50-rock5b.conf,\n/boot/dtb/rockchip staging"]
        Prof["profiles/PROFILE.yaml\nOptional APT repo and priority pin"]
        Sync["scripts/rock5b-sync-boot.sh\nInstalled to /usr/sbin/rock5b-sync-boot"]
        OEM["system/oem/20_rock5b_hardware.yaml\nafter-install / after-upgrade-chroot /\nafter-reset / rootfs / boot hooks"]
    end

    subgraph Build["Branchless Multi-Stage Dockerfile"]
        S1["Stage 1: AS kairos-init\nUpstream kairos-init binary"]
        S2["Stage 2: AS uboot on BUILDPLATFORM\nDenx Mainline U-Boot + pinned rkbin\n(sha256sum -c verified)\n-> u-boot-rockchip-spi.bin\n-> u-boot-rockchip.bin"]
        S3["Stage 3: Final Target Rootfs (linux/arm64)\nCopy U-Boot, Sync Script, OEM Hook and Profiles\nRun /kairos-init -s all -m generic -x\nStamp /etc/os-release and /etc/kairos-release\nGate on /kairos-init validate"]
    end

    Env --> S3
    S1 -.->|"bind-mounted /kairos-init"| S3
    S2 -->|"COPY /usr/share/rock5b-uboot/"| S3
    Common -->|"10-common.yaml"| S3
    Prof -->|"20-profile.yaml"| S3
    Sync --> S3
    OEM --> S3
```

### Division of Labor: Upstream `kairos-init` vs `kairos-rock5b`

| Layer | Provided by Upstream `kairos-init` | Added by `kairos-rock5b` |
| :--- | :--- | :--- |
| **Core Kairos Runtime** | `immucore`, `kairos-agent`, A/B boot & reset scaffolding, `/system/oem/00_rootfs.yaml` bind mounts | Hardware-specific [`20_rock5b_hardware.yaml`](../system/oem/20_rock5b_hardware.yaml) (`CUSTOM_BIND_MOUNTS: /var/lib/iscsi`) |
| **Kernel & Initramfs** | Installs Debian `linux-image-arm64`, runs `dracut` to generate `/boot/initrd` with `dm_snapshot`, creates `/boot/vmlinuz` | Configures optional `*-backports` pin, adds `/etc/dracut.conf.d/50-rock5b.conf`, stages `/boot/dtb/rockchip/` |
| **Orchestrator & Storage** | Installs `open-iscsi`, `cryptsetup`, `nfs-common`, `multipath-tools`, optional `k3s`/`k0s` binary + units | Adds `firmware-realtek`, `gdisk`, `mtd-utils`, `parted`, `u-boot-tools`, disables/masks `multipathd`, and configures NVMe/MMC multipath blacklist |
| **Bootloader** | Generic `GRUB2` EFI (`BOOTAA64.EFI`) for UEFI `arm64` systems | Compiles Denx Mainline U-Boot (`rock5b-rk3588_defconfig`) + `rock5b-sync-boot` for `COS_GRUB` DTBs & `/dev/mtd0` |
| **Validation & Metadata** | `/kairos-init validate` (kernel/initrd/systemd/getty/single-kernel gates) | Stamps profile + resolved numeric kernel version onto OCI tags, `/etc/os-release`, and `/etc/kairos-release` |

### Repository File & Lifecycle Execution Map

| File | Runs When | Responsibility |
| :--- | :--- | :--- |
| [`versions.conf`](../versions.conf), [`Makefile`](../Makefile) & [`.github/workflows/build.yaml`](../.github/workflows/build.yaml) | Build orchestration | Centralizes pinned tool/RKBIN/orchestrator versions + optional kernel ABI pins (`BPO_KERNEL_VERSION` / `LTS_KERNEL_VERSION`) and resolves `KERNEL_PACKAGE` + `KAIROS_INIT_ARGS` |
| [`profiles/common.yaml`](../profiles/common.yaml) & `profiles/<profile>.yaml` | Image build (`kairos-init -x`) | Declarative APT repos/pins (`before-install`), packages + dracut config (`install`), DTB staging (`after-install`) |
| [`Dockerfile`](../Dockerfile) | Image build (`podman` / `docker`) | Builds U-Boot, layers Rock 5B files + generated `15-kernel.yaml`, runs `/kairos-init -s all -x --skip-step installKernel`, stamps metadata, cleans `/etc/kairos-init`, validates |
| [`scripts/verify-image.sh`](../scripts/verify-image.sh) | Post-build CI / local verification | Verifies kernel, initrd RK3588 drivers, `rk3588-rock-5b.dtb`, U-Boot bins, `/etc/kairos-release`, tools, and OEM hooks |
| [`scripts/build-installer-img.sh`](../scripts/build-installer-img.sh) | Day-1 media creation | Extracts DTB + U-Boot bins, invokes `auroraboot build-iso`, packages GPT `COS_LIVE` + sector-64 `u-boot-rockchip.bin` |
| [`scripts/flash-spi-uboot.sh`](../scripts/flash-spi-uboot.sh) | Optional pre-install SSH prep | Idempotently flashes `u-boot-rockchip-spi.bin` to `/dev/mtd0` from an existing Linux install |
| [`system/oem/20_rock5b_hardware.yaml`](../system/oem/20_rock5b_hardware.yaml) | Runtime (`rootfs`, `initramfs`, `boot`, `after-*`) | Persists `/var/lib/iscsi`, ensures `multipathd` stays masked, runs `rock5b-sync-boot`, writes multipath blacklist, loads `iscsi_tcp`/`dm_crypt` |
| [`scripts/rock5b-sync-boot.sh`](../scripts/rock5b-sync-boot.sh) | Install, Upgrade, Reset | `findmnt`-safe copy of `/boot/dtb/rockchip/` to `COS_GRUB` + `cmp -s`-gated `/dev/mtd0` SPI flash |

---

## 2. Hardware Boot Sequence on Radxa Rock 5B (`RK3588`)

Unlike x86_64 servers with onboard ACPI/UEFI firmware capable of reading NVMe drives natively, the **Rockchip RK3588** silicon BootROM cannot initialize PCIe 3.0 directly. Instead, the RK3588 BootROM searches for a first-stage bootloader in fixed hardware order:

1. **Onboard 16 MB SPI NOR Flash (`/dev/mtd0`)**
2. **eMMC Module (`mmc0`)**
3. **MicroSD Card Slot (`mmc1` / `/dev/mmcblk1`)**

`kairos-rock5b` compiles **Mainline U-Boot (`rock5b-rk3588_defconfig`, EFI + PCIe NVMe enabled)** paired with pinned `rockchip-linux/rkbin` DRAM TPL and TF-A BL31 blobs into `/usr/share/rock5b-uboot/u-boot-rockchip-spi.bin` (for `/dev/mtd0`) and `u-boot-rockchip.bin` (embedded at sector 64 of the installer `.raw` image).

```mermaid
flowchart TD
    subgraph Board["Radxa Rock 5B Hardware"]
        ROM["1. RK3588 Silicon BootROM"]
        SPI["2. SPI NOR Flash /dev/mtd0\nMainline U-Boot EFI\nboot_targets: mmc1 -> nvme -> usb"]
    end

    subgraph NVMe["M.2 NVMe SSD /dev/nvme0n1"]
        GRUB["3. p1: COS_GRUB (FAT32 ESP)\n/EFI/BOOT/BOOTAA64.EFI\n/dtb/rockchip/rk3588-rock-5b.dtb"]
        STATE["4. p4: COS_STATE (ext4)\nactive.img (A) / passive.img (B)\nKernel + dracut/immucore + SquashFS"]
        PERSIST["5. p5: COS_PERSISTENT (ext4)\n/usr/local, /var/lib/kubelet,\n/var/lib/iscsi, /etc/iscsi, container data"]
    end

    ROM --> SPI --> GRUB --> STATE --> PERSIST
```

With Mainline U-Boot EFI in `/dev/mtd0`:
- **When the installer MicroSD card is inserted**: `boot_targets` hits `mmc1` first, loading `/dtb/rockchip/rk3588-rock-5b.dtb` and `/EFI/BOOT/BOOTAA64.EFI` from `COS_LIVE`. Even if `/dev/mtd0` is completely empty on a brand-new board, the RK3588 BootROM falls back to sector 64 (`32 KiB`) of the MicroSD installer (`u-boot-rockchip.bin`), and `after-install` flashes `/dev/mtd0` automatically.
- **Once the MicroSD card is removed**: U-Boot scans `nvme` and boots `/EFI/BOOT/BOOTAA64.EFI` (GRUB2) + `/dtb/rockchip/rk3588-rock-5b.dtb` from the NVMe `COS_GRUB` partition.

---

## 3. Day-1 Provisioning Pipeline (`AuroraBoot` -> Auto-Install)

[`scripts/build-installer-img.sh`](../scripts/build-installer-img.sh) avoids loop devices (`/dev/loop-control`) completely so users can assemble a bootable `.raw` MicroSD image rootlessly on any Linux workstation:

```mermaid
sequenceDiagram
    autonumber
    participant User as Workstation (podman / docker)
    participant Img as kairos-rock5b OCI Image
    participant AB as AuroraBoot (build-iso)
    participant Raw as kairos-rock5b-installer.raw
    participant Board as Radxa Rock 5B Hardware

    User->>Img: Extract <br/> u-boot-rockchip-spi.bin, <br/> u-boot-rockchip.bin, <br/> rk3588-rock-5b.dtb
    User->>Img: Save local OCI archive <br/> (if present locally)
    User->>AB: Run<br/>  auroraboot build-iso --arch arm64 --live-console ttyS2,1500000 --overlay-iso dtb<br/> 
    AB-->>User: Emit kairos-rock5b-live.iso <br/> (squashfs + kernel + initrd + GRUB EFI)
    User->>Raw: Extract ISO via xorriso, <br/> extract uefi.img via mcopy, <br/> build FAT32 COS_LIVE image
    User->>Raw: Write GPT partition (COS_LIVE at sector 32768) <br/> +<br/>  dd u-boot-rockchip.bin at sector 64<br/> 
    Note over User,Raw: Write .raw to MicroSD via dd#59; <br/> swap /config.yaml in COS_LIVE per node if desired
    User->>Board: Boot Rock 5B from MicroSD
    Board->>Board: kairos-agent installs <br/> /dev/nvme0n1 <br/> (5 COS_* partitions) <br/> and runs after-install<br/> 
    Board->>Board: /usr/sbin/rock5b-sync-boot <br/> copies DTBs to <br/> COS_GRUB and flashes <br/> /dev/mtd0 if changed<br/> 
    Board-->>User: Power off, unplug MicroSD, and power on -> pure NVMe Kairos boot
```

---

## 4. Day-2 Atomic A/B Upgrades

Upgrades run atomically—either via CLI (`sudo kairos-agent upgrade --source oci:<image>`) or via `kairos-operator` (`NodeOpUpgrade`)—by replacing `passive.img` on `COS_STATE` and flipping the GRUB boot target:

```mermaid
sequenceDiagram
    autonumber
    participant Ops as Admin / Cluster Operator
    participant Op as kairos-operator
    participant Agent as kairos-agent (Node Chroot)
    participant Sync as /usr/sbin/rock5b-sync-boot
    participant Flash as COS_GRUB ESP and SPI /dev/mtd0

    Ops->>Op: Trigger NodeOpUpgrade <br/> (or kairos-agent upgrade) <br/> with versioned image tag
    Op->>Agent: Preflight check: compare <br/> KAIROS_VERSION-KAIROS_SOFTWARE_VERSION <br/> vs <br/> spec.image
    Agent->>Agent: Unpack target OCI image into <br/> passive.img on COS_STATE<br/> 
    Agent->>Sync: Execute after-upgrade-chroot hook <br/> (--sync-dtb --sync-spi)
    Sync->>Flash: findmnt check on COS_GRUB <br/> -> mount temporarily, <br/> copy rk3588-rock-5b.dtb, <br/> umount
    Sync->>Flash: cmp -s head bytes of <br/> /dev/mtd0 vs u-boot-rockchip-spi.bin<br/>  -> flashcp only if changed
    Agent->>Agent: Run kairos refreshESPFromCtx <br/> and <br/> stage reboot to updated active.img<br/> 
```

### Why `rock5b-sync-boot` Checks `findmnt` and `cmp -s`
1. **No Dual VFAT RW Mount**: During `after-install` and `after-reset`, `kairos-agent` already holds `COS_GRUB` (`FAT32`) mounted read-write, whereas `after-upgrade-chroot` runs *before* `refreshESPFromCtx` mounts the ESP. Checking `findmnt -rn -S "${ESP_DEV}" -o TARGET` lets [`rock5b-sync-boot.sh`](../scripts/rock5b-sync-boot.sh) reuse an existing mount point when present and perform a clean temporary mount/unmount only during upgrades, backed by `EXIT` and `RETURN` cleanup traps so any copy or sync failure unmounts the temporary mount point before exit and prevents VFAT dual-write corruption.
2. **Zero Unnecessary SPI NOR Wear**: [`rock5b-sync-boot.sh`](../scripts/rock5b-sync-boot.sh) and [`flash-spi-uboot.sh`](../scripts/flash-spi-uboot.sh) compare `head -c "${SPI_SIZE}" /dev/mtd0` byte-for-byte (`cmp -s`) against `/usr/share/rock5b-uboot/u-boot-rockchip-spi.bin`, calling `flashcp -v` only when the U-Boot binary actually changes.

---

## 5. Kairos NVMe GPT Partition & Persistence Layout

On a clean full-disk installation (`install.device: /dev/nvme0n1`), Kairos formats five GPT partitions:

| Partition | Label | Filesystem | Purpose |
| :--- | :--- | :--- | :--- |
| `nvme0n1p1` | `COS_GRUB` | `vfat` (FAT32) | UEFI System Partition (`/EFI/BOOT/BOOTAA64.EFI` + `/dtb/rockchip/rk3588-rock-5b.dtb`) |
| `nvme0n1p2` | `COS_OEM` | `ext4` | Node-specific `/oem` cloud-config (`90_custom.yaml`) preserved across A/B upgrades |
| `nvme0n1p3` | `COS_RECOVERY` | `ext4` | Immutable fallback recovery SquashFS image (`recovery.img`) |
| `nvme0n1p4` | `COS_STATE` | `ext4` | A/B immutable SquashFS root images (`active.img` and `passive.img`) |
| `nvme0n1p5` | `COS_PERSISTENT` | `ext4` | Persistent writable storage bind-mounted over the immutable rootfs |

Upstream `kairos-init` (`00_rootfs.yaml`) persists standard system, Kubernetes, and storage directories on `COS_PERSISTENT`. [`system/oem/20_rock5b_hardware.yaml`](../system/oem/20_rock5b_hardware.yaml) adds `/var/lib/iscsi` via `CUSTOM_BIND_MOUNTS` so iSCSI initiator IQNs and session metadata persist cleanly across upgrades and resets for any CSI/block storage stack.
