#!/usr/bin/env bash
set -euo pipefail

# Synchronizes Rock 5B Device Tree blobs to the FAT32 EFI System Partition (COS_GRUB)
# and idempotently flashes Mainline U-Boot EFI to /dev/mtd0 when changed.
# Safely reuses an already-mounted COS_GRUB target via findmnt to avoid dual RW VFAT mounts.

SYNC_DTB=false
SYNC_SPI=false
DTB_SRC="${DTB_SRC:-/boot/dtb/rockchip}"
MTD_DEV="${MTD_DEV:-/dev/mtd0}"
SPI_BIN="${SPI_BIN:-/usr/share/rock5b-uboot/u-boot-rockchip-spi.bin}"
ESP_MNT=""

cleanup_esp() {
  if [ -n "${ESP_MNT}" ]; then
    if mountpoint -q "${ESP_MNT}"; then
      umount "${ESP_MNT}" || true
    fi
    rmdir "${ESP_MNT}" 2>/dev/null || true
    ESP_MNT=""
  fi
}
trap cleanup_esp EXIT

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
  local esp_dev existing_mnt
  esp_dev="$(blkid -L COS_GRUB || true)"
  if [ -z "${esp_dev}" ] || [ ! -d "${DTB_SRC}" ]; then
    echo "WARNING: COS_GRUB partition or ${DTB_SRC} not found; skipping DTB sync" >&2
    return 0
  fi

  existing_mnt="$(findmnt -rn -S "${esp_dev}" -o TARGET 2>/dev/null | head -n 1 || true)"
  if [ -n "${existing_mnt}" ] && [ -d "${existing_mnt}" ]; then
    mkdir -p "${existing_mnt}/dtb/rockchip"
    cp -rfL "${DTB_SRC}"/* "${existing_mnt}/dtb/rockchip/"
    sync
    echo "Synced ${DTB_SRC} to existing mount ${existing_mnt}/dtb/rockchip"
    return 0
  fi

  ESP_MNT="$(mktemp -d)"
  trap cleanup_esp RETURN
  if mount "${esp_dev}" "${ESP_MNT}"; then
    mkdir -p "${ESP_MNT}/dtb/rockchip"
    cp -rfL "${DTB_SRC}"/* "${ESP_MNT}/dtb/rockchip/"
    sync
    umount "${ESP_MNT}"
    echo "Synced ${DTB_SRC} to ${esp_dev} (/dtb/rockchip)"
  else
    echo "WARNING: Failed to mount ${esp_dev} (COS_GRUB) to sync DTB" >&2
  fi
  cleanup_esp
  trap - RETURN
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
