# Verification & Testing Guide (`kairos-rock5b`)

`kairos-rock5b` uses a 3-tier verification model to validate static scripts/YAML, built OCI container images, and generated boot media across any Debian kernel track.

---

## Tier 1: Static & Non-Exposure Verification (`make lint`)

Runs offline inside the standard sandbox (`BypassSandbox: false`):
1. **Shell Script Syntax Check (`bash -n`)**: Validates all scripts under [`scripts/`](../scripts/) for syntax errors.
2. **Anonymity & Hygiene Guard (`make check-anonymity`)**: Scans `Dockerfile`, `profiles/`, `system/`, `scripts/`, `docs/`, `README.md`, `CONTEXT.md`, `AGENTS.md`, and `.github/` to ensure zero local home paths, file-scheme URLs, private RFC 1918 LAN addresses, or `#L<line>` anchors exist in tracked files.

```bash
make lint
```

---

## Tier 2: Build-Time `/kairos-init validate` & Image Structure Check (`make verify-image`)

1. **Build-Time Gate (`/kairos-init validate`)**: Runs at the end of [`Dockerfile`](../Dockerfile) via bind-mounted `/kairos-init` to confirm `/boot/vmlinuz` symlink resolution, `/boot/initrd` (`immucore` + `dm_snapshot`), all required `/etc/kairos-release` fields, zero SSH host keys, `getty.target`, and single-kernel validity.
2. **Runtime Structure Verification (`make verify-image`)**: [`scripts/verify-image.sh`](../scripts/verify-image.sh) runs a non-privileged container inspection against the built image to verify:
   - **Kernel & Initramfs**: `/boot/vmlinuz` symlink resolves and `/boot/initrd` is non-empty.
   - **RK3588 Early-Boot Drivers**: Dynamically verifies via `lsinitrd /boot/initrd` (with fallback to `/lib/modules/<kver>/modules.builtin`) that all required Rock 5B PMIC, regulator, I2C, GPIO, IO-domain, PCIe/ComboPHY/USB/eMMC PHY, NVMe, MMC, `r8169`, and SPI NOR drivers are available before rootfs switch regardless of Debian kernel version.
   - **Device Tree Blob**: `/boot/dtb/rockchip/rk3588-rock-5b.dtb` exists and is non-empty.
   - **Mainline U-Boot EFI Binaries**: `/usr/share/rock5b-uboot/u-boot-rockchip-spi.bin` and `/usr/share/rock5b-uboot/u-boot-rockchip.bin` exist and are non-empty.
   - **Boot Sync & OEM Hook**: `/usr/sbin/rock5b-sync-boot` is executable, `/system/oem/20_rock5b_hardware.yaml` and `/etc/dracut.conf.d/50-rock5b.conf` exist, `/var/lib/iscsi` exists, and `/etc/kairos-init` was cleaned up.
   - **Kairos Metadata**: `KAIROS_VERSION` equals `KAIROS_RELEASE`, `KAIROS_INIT_VERSION`, `KAIROS_PROFILE`, and `KAIROS_KERNEL_VERSION` are populated, and workload/storage tools (`k3s`, `iscsid`, `iscsiadm`, `cryptsetup`) are present when applicable.

```bash
make verify-image
make verify-image PROFILE=debian-trixie
```

---

## Tier 3: `AuroraBoot` Installer Generation Smoke Test (`make build-installer`)

Verifies that upstream `auroraboot build-iso` converts the built OCI image and [`docs/examples/cloud-config.example.yaml`](./examples/cloud-config.example.yaml) into a bootable GPT + FAT32 raw disk image (`kairos-rock5b-installer.raw`) with `u-boot-rockchip.bin` at sector 64 (`32 KiB`) and a `COS_LIVE` EFI System Partition starting at sector 32768 (`16 MiB`, containing `BOOTAA64.EFI`, `/dtb/rockchip/rk3588-rock-5b.dtb`, `/config.yaml`, and `/boot/grub2/grub.cfg` with `console=ttyS2,1500000 console=tty1`).

```bash
make build-installer
(cd build && sha256sum -c kairos-rock5b-installer.raw.sha256)
sfdisk -l build/kairos-rock5b-installer.raw
```
