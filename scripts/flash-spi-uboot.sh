#!/usr/bin/env bash
set -euo pipefail

# Universal helper to flash and verify Mainline U-Boot EFI (u-boot-rockchip-spi.bin)
# onto the Radxa Rock 5B onboard 16 MB SPI NOR flash (/dev/mtd0).

FORCE=false
SPI_BIN=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --force)
      FORCE=true
      ;;
    -h|--help)
      echo "Usage: $0 [--force] [path-to-u-boot-rockchip-spi.bin]" >&2
      exit 0
      ;;
    *)
      if [ -z "${SPI_BIN}" ]; then
        SPI_BIN="$1"
      else
        echo "Usage: $0 [--force] [path-to-u-boot-rockchip-spi.bin]" >&2
        exit 1
      fi
      ;;
  esac
  shift
done

MTD_DEV="${MTD_DEV:-/dev/mtd0}"
SPI_BIN="${SPI_BIN:-/usr/share/rock5b-uboot/u-boot-rockchip-spi.bin}"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run as root (sudo)." >&2
  exit 1
fi

if [ ! -c "${MTD_DEV}" ]; then
  echo "ERROR: SPI flash character device ${MTD_DEV} not found. Ensure spi_rockchip_sfc is loaded." >&2
  exit 1
fi

if [ ! -s "${SPI_BIN}" ]; then
  echo "ERROR: SPI U-Boot binary not found at ${SPI_BIN}" >&2
  exit 1
fi

if ! command -v flashcp >/dev/null 2>&1; then
  echo "ERROR: flashcp not found. Install mtd-utils (apt-get install -y mtd-utils)." >&2
  exit 1
fi

if [ "${FORCE}" != true ]; then
  SPI_SIZE="$(stat -c '%s' "${SPI_BIN}")"
  if head -c "${SPI_SIZE}" "${MTD_DEV}" | cmp -s - "${SPI_BIN}"; then
    echo ">>> SPI U-Boot on ${MTD_DEV} already matches ${SPI_BIN}; skipping flash (use --force to rewrite)."
    exit 0
  fi
fi

echo ">>> Flashing Mainline U-Boot EFI to ${MTD_DEV} from ${SPI_BIN}..."
flashcp -v "${SPI_BIN}" "${MTD_DEV}"
sync
echo ">>> Successfully flashed and verified Mainline U-Boot EFI on ${MTD_DEV}."
