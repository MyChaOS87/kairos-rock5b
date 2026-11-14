#!/usr/bin/env bash
set -euo pipefail

# Synchronizes Rock 5B Device Tree blobs to the FAT32 EFI System Partition (COS_GRUB)
# and idempotently flashes Mainline U-Boot EFI to /dev/mtd0 when changed.
# Safely reuses an already-mounted COS_GRUB target via findmnt to avoid dual RW VFAT mounts.

SYNC_DTB=false
SYNC_SPI=false
MTD_DEV="${MTD_DEV:-/dev/mtd0}"
SPI_BIN="${SPI_BIN:-/usr/share/rock5b-uboot/u-boot-rockchip-spi.bin}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --sync-dtb)
      SYNC_DTB=true
      ;;
    --sync-spi)
      SYNC_SPI=true
      ;;
    *)
      echo "Usage: $0 [--sync-dtb] [--sync-spi]" >&2
      exit 1
      ;;
  esac
  shift
done

sync_dtb() {
  local esp_dev existing_mnt esp_mnt
  esp_dev="$(blkid -L COS_GRUB || true)"
  if [ -z "${esp_dev}" ] || [ ! -d /boot/dtb/rockchip ]; then
    echo "WARNING: COS_GRUB partition or /boot/dtb/rockchip not found; skipping DTB sync" >&2
    return 0
  fi

  existing_mnt="$(findmnt -rn -S "${esp_dev}" -o TARGET 2>/dev/null | head -n 1 || true)"
  if [ -n "${existing_mnt}" ] && [ -d "${existing_mnt}" ]; then
    mkdir -p "${existing_mnt}/dtb/rockchip"
    cp -rfL /boot/dtb/rockchip/* "${existing_mnt}/dtb/rockchip/"
    sync
    echo "Synced /boot/dtb/rockchip to existing mount ${existing_mnt}/dtb/rockchip"
    return 0
  fi

  esp_mnt="$(mktemp -d)"
  if mount "${esp_dev}" "${esp_mnt}"; then
    mkdir -p "${esp_mnt}/dtb/rockchip"
    cp -rfL /boot/dtb/rockchip/* "${esp_mnt}/dtb/rockchip/"
    sync
    umount "${esp_mnt}"
    echo "Synced /boot/dtb/rockchip to ${esp_dev} (/dtb/rockchip)"
  else
    echo "WARNING: Failed to mount ${esp_dev} (COS_GRUB) to sync DTB" >&2
  fi
  rmdir "${esp_mnt}" || true
}

sync_spi() {
  local spi_size
  if [ ! -c "${MTD_DEV}" ] || [ ! -s "${SPI_BIN}" ] || ! command -v flashcp >/dev/null 2>&1; then
    return 0
  fi

  spi_size="$(stat -c '%s' "${SPI_BIN}")"
  if head -c "${spi_size}" "${MTD_DEV}" | cmp -s - "${SPI_BIN}"; then
    echo "SPI U-Boot on ${MTD_DEV} already matches ${SPI_BIN}; skipping flash."
    return 0
  fi

  echo "Flashing Mainline U-Boot EFI to ${MTD_DEV} from ${SPI_BIN}..."
  flashcp -v "${SPI_BIN}" "${MTD_DEV}"
  sync
}

if [ "${SYNC_DTB}" = true ]; then
  sync_dtb
fi

if [ "${SYNC_SPI}" = true ]; then
  sync_spi
fi
