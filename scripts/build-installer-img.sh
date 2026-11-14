#!/usr/bin/env bash
set -euo pipefail

# Universal AuroraBoot wrapper that converts a kairos-rock5b OCI image + user cloud-config.yaml
# into a bootable ARM64 GPT + FAT32 raw disk installer image (kairos-rock5b-installer.raw)
# in 100% rootless userspace (no /dev/loop-control required) and extracts the Rock 5B U-Boot binaries.

CONTAINER_ENGINE="${CONTAINER_ENGINE:-podman}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${AURORABOOT_IMAGE:-}" ]; then
  if [ -f "${SCRIPT_DIR}/../versions.conf" ]; then
    # shellcheck source=../versions.conf
    . "${SCRIPT_DIR}/../versions.conf"
  fi
  if [ -z "${AURORABOOT_VERSION:-}" ]; then
    echo "ERROR: Set AURORABOOT_IMAGE or provide AURORABOOT_VERSION in versions.conf" >&2
    exit 1
  fi
  AURORABOOT_IMAGE="quay.io/kairos/auroraboot:${AURORABOOT_VERSION}"
fi

OCI_IMAGE="${1:-}"
CLOUD_CONFIG="${2:-}"
OUTPUT_DIR="${3:-./build}"

if [ -z "${OCI_IMAGE}" ] || [ -z "${CLOUD_CONFIG}" ]; then
  echo "Usage: $0 <oci-image> <path-to-cloud-config.yaml> [output-dir]" >&2
  echo "Example: $0 <registry>/kairos-rock5b:debian-trixie-bpo-k3s ./docs/examples/cloud-config.example.yaml ./build" >&2
  exit 1
fi

if [ ! -f "${CLOUD_CONFIG}" ]; then
  echo "ERROR: Cloud-config file not found: ${CLOUD_CONFIG}" >&2
  exit 1
fi

mkdir -p "${OUTPUT_DIR}"
ABS_CLOUD_CONFIG="$(cd "$(dirname "${CLOUD_CONFIG}")" && pwd)/$(basename "${CLOUD_CONFIG}")"
ABS_OUTPUT_DIR="$(cd "${OUTPUT_DIR}" && pwd)"

echo ">>> Extracting Radxa Rock 5B U-Boot binaries & Device Tree into ${ABS_OUTPUT_DIR}..."
"${CONTAINER_ENGINE}" run --rm --entrypoint /bin/sh "${OCI_IMAGE}" -c \
  'cat /usr/share/rock5b-uboot/u-boot-rockchip-spi.bin' > "${ABS_OUTPUT_DIR}/u-boot-rockchip-spi.bin"
"${CONTAINER_ENGINE}" run --rm --entrypoint /bin/sh "${OCI_IMAGE}" -c \
  'cat /usr/share/rock5b-uboot/u-boot-rockchip.bin' > "${ABS_OUTPUT_DIR}/u-boot-rockchip.bin"

WORK_HOST_DIR="${ABS_OUTPUT_DIR}/.installer-work"
rm -rf "${WORK_HOST_DIR}"
mkdir -p "${WORK_HOST_DIR}/overlay/dtb/rockchip" "${WORK_HOST_DIR}/state"
chmod 0700 "${WORK_HOST_DIR}"

"${CONTAINER_ENGINE}" run --rm --entrypoint /bin/sh "${OCI_IMAGE}" -c \
  'cat /boot/dtb/rockchip/rk3588-rock-5b.dtb' > "${WORK_HOST_DIR}/overlay/dtb/rockchip/rk3588-rock-5b.dtb"

TEMP_TAR=""
cleanup() {
  if [ -n "${TEMP_TAR}" ] && [ -f "${TEMP_TAR}" ]; then
    rm -f "${TEMP_TAR}"
  fi
  rm -rf "${WORK_HOST_DIR}"
}
trap cleanup EXIT

if "${CONTAINER_ENGINE}" image inspect "${OCI_IMAGE}" >/dev/null 2>&1; then
  echo ">>> Exporting local image ${OCI_IMAGE} to temporary archive for AuroraBoot..."
  TEMP_TAR="${WORK_HOST_DIR}/kairos-rock5b-source.tar"
  rm -f "${TEMP_TAR}"
  "${CONTAINER_ENGINE}" save -o "${TEMP_TAR}" "${OCI_IMAGE}"
  CONTAINER_SOURCE="ocifile:/output/.installer-work/kairos-rock5b-source.tar"
else
  CONTAINER_SOURCE="oci:${OCI_IMAGE}"
fi

echo ">>> Generating bootable ARM64 GPT raw disk installer via AuroraBoot (${AURORABOOT_IMAGE})"
echo "    Source OCI Image : ${OCI_IMAGE} (${CONTAINER_SOURCE})"
echo "    Cloud-Config     : ${ABS_CLOUD_CONFIG}"
echo "    Output Directory : ${ABS_OUTPUT_DIR}"

"${CONTAINER_ENGINE}" run --rm \
  -v "${ABS_CLOUD_CONFIG}:/config.yaml:ro,Z" \
  -v "${ABS_OUTPUT_DIR}:/output:rw,Z" \
  --entrypoint /bin/bash \
  "${AURORABOOT_IMAGE}" -c '
    set -euo pipefail

    WORK_DIR="/output/.installer-work"
    STATE_DIR="${WORK_DIR}/state"
    ISO_EXTRACT="${WORK_DIR}/iso"
    mkdir -p "${ISO_EXTRACT}"

    /usr/bin/auroraboot build-iso \
      --arch arm64 \
      --cloud-config /config.yaml \
      --override-name kairos-rock5b-live \
      --overlay-iso "${WORK_DIR}/overlay" \
      --live-console "console=ttyS2,1500000 console=tty1" \
      --output "${STATE_DIR}" \
      "'"${CONTAINER_SOURCE}"'"

    echo ">>> Assembling userspace GPT + FAT32 Live Installer raw disk image (kairos-rock5b-installer.raw)..."
    xorriso -osirrox on -indev "${STATE_DIR}/kairos-rock5b-live.iso" -extract / "${ISO_EXTRACT}" >/dev/null 2>&1
    chmod -R u+w "${ISO_EXTRACT}"

    mcopy -s -o -i "${ISO_EXTRACT}/boot/uefi.img" ::EFI "${ISO_EXTRACT}/"
    rm -f "${ISO_EXTRACT}/boot/uefi.img" \
          "${ISO_EXTRACT}/boot/eltorito.img" \
          "${ISO_EXTRACT}/boot/boot_hybrid.img" \
          "${ISO_EXTRACT}/boot/boot.catalog"

    TREE_MB="$(du -sm "${ISO_EXTRACT}" | cut -f1)"
    FAT_MB=$(( ((TREE_MB + 64 + 3) / 4) * 4 ))
    FAT_IMG="${WORK_DIR}/cos_live.fat"
    truncate -s "${FAT_MB}M" "${FAT_IMG}"
    mkfs.vfat -F 32 -n COS_LIVE "${FAT_IMG}" >/dev/null

    for item in "${ISO_EXTRACT}"/*; do
      mcopy -s -i "${FAT_IMG}" "${item}" ::
    done

    RAW_IMG="/output/kairos-rock5b-installer.raw"
    RAW_MB=$(( 16 + FAT_MB + 1 ))
    rm -f "${RAW_IMG}"
    truncate -s "${RAW_MB}M" "${RAW_IMG}"
    chmod 0600 "${RAW_IMG}"

    sfdisk --quiet "${RAW_IMG}" <<EOF
label: gpt
start=32768, size=$((FAT_MB * 2048)), type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="COS_LIVE"
EOF

    dd if="${FAT_IMG}" of="${RAW_IMG}" bs=1M seek=16 conv=notrunc status=none
    dd if="/output/u-boot-rockchip.bin" of="${RAW_IMG}" bs=512 seek=64 conv=notrunc status=none

    (cd /output && sha256sum kairos-rock5b-installer.raw > kairos-rock5b-installer.raw.sha256)
  '

echo ">>> Installer build complete. Artifacts in ${ABS_OUTPUT_DIR}:"
ls -lh "${ABS_OUTPUT_DIR}"
