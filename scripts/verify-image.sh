#!/usr/bin/env bash
set -euo pipefail

CONTAINER_ENGINE="${CONTAINER_ENGINE:-podman}"
IMAGE="${1:-}"

if [ -z "${IMAGE}" ]; then
  echo "Usage: $0 <image-tag>" >&2
  exit 1
fi

echo ">>> Verifying kairos-rock5b image structure: ${IMAGE}"

"${CONTAINER_ENGINE}" run --rm --entrypoint /bin/bash "${IMAGE}" -c '
  set -euo pipefail
  echo "1. Checking /etc/os-release:"
  grep -E "^(PRETTY_NAME|ID|VERSION_CODENAME)=" /etc/os-release

  echo "2. Checking kernel & initrd in /boot:"
  ls -lh /boot/vmlinuz* /boot/initrd*
  test -e /boot/vmlinuz
  test -s /boot/initrd

  echo "3. Checking Radxa Rock 5B Device Tree (/boot/dtb/rockchip/rk3588-rock-5b.dtb):"
  ls -lh /boot/dtb/rockchip/rk3588-rock-5b.dtb
  test -s /boot/dtb/rockchip/rk3588-rock-5b.dtb

  echo "4. Checking Mainline U-Boot EFI SPI & MMC binaries (/usr/share/rock5b-uboot):"
  ls -lh /usr/share/rock5b-uboot/u-boot-rockchip-spi.bin /usr/share/rock5b-uboot/u-boot-rockchip.bin
  test -s /usr/share/rock5b-uboot/u-boot-rockchip-spi.bin
  test -s /usr/share/rock5b-uboot/u-boot-rockchip.bin

  echo "5. Checking Kairos core binaries & release metadata:"
  test -x /usr/bin/kairos-agent
  test -x /usr/bin/immucore
  test ! -d /etc/kairos-init
  for key in KAIROS_VERSION KAIROS_RELEASE KAIROS_INIT_VERSION KAIROS_PROFILE KAIROS_KERNEL_VERSION; do
    grep -qE "^${key}=\"?[^\"]+" /etc/kairos-release
  done
  grep -E "^KAIROS_(VERSION|RELEASE|INIT_VERSION|PROFILE|KERNEL_VERSION|SOFTWARE_VERSION)=" /etc/kairos-release

  . /etc/kairos-release
  test "${KAIROS_VERSION}" = "${KAIROS_RELEASE}"

  if [ "${KAIROS_VARIANT:-}" = "core" ]; then
    echo "   Variant: core (no bundled orchestrator)"
  else
    echo "   Checking orchestrator & storage prerequisites (k3s, iscsid, iscsiadm, cryptsetup):"
    grep -qE "^KAIROS_SOFTWARE_VERSION=\"?[^\"]+" /etc/kairos-release
    command -v k3s >/dev/null
    command -v iscsid >/dev/null
    command -v iscsiadm >/dev/null
    command -v cryptsetup >/dev/null
  fi

  echo "6. Checking Rock 5B sync helper & OEM hardware hook:"
  test -x /usr/sbin/rock5b-sync-boot
  test -s /system/oem/20_rock5b_hardware.yaml
  test -s /etc/dracut.conf.d/50-rock5b.conf
  test -d /var/lib/iscsi
  test ! -e /etc/systemd/system/sysinit.target.wants/multipathd.service
  test "$(readlink /etc/systemd/system/multipathd.service)" = "/dev/null"
  test "$(readlink /etc/systemd/system/multipathd.socket)" = "/dev/null"

  echo "7. Checking RK3588 early-boot drivers in /boot/initrd or modules.builtin:"
  KVER_FULL="$(cat /etc/rock5b-kernel-release)"
  KVER_SHORT="$(cat /etc/rock5b-kernel-version)"
  echo "   Full release: ${KVER_FULL}"
  echo "   Short version: ${KVER_SHORT}"
  lsinitrd /boot/initrd > /tmp/initrd.list
  BUILTIN_FILE="/lib/modules/${KVER_FULL}/modules.builtin"
  for mod in \
    fixed gpio-regulator pwm-regulator pwm-rockchip rk808-regulator fan53555 \
    i2c-rk3x gpio-rockchip io-domain \
    phy-rockchip-naneng-combphy phy-rockchip-snps-pcie3 phy-rockchip-pcie \
    phy-rockchip-inno-usb2 phy-rockchip-usbdp phy-rockchip-emmc \
    nvme nvme-core dw_mmc-rockchip sdhci-of-dwcmshc r8169 spi-rockchip-sfc; do
    MOD_REGEX="$(printf '%s' "${mod}" | sed 's/[-_]/[-_]/g')"
    if ! grep -qE "/${MOD_REGEX}\.ko(\.[a-z0-9]+)?$" /tmp/initrd.list && \
       { [ ! -f "${BUILTIN_FILE}" ] || ! grep -qE "/${MOD_REGEX}\.ko$" "${BUILTIN_FILE}"; }; then
      echo "ERROR: Required RK3588 early-boot driver missing from initrd and modules.builtin: ${mod}" >&2
      rm -f /tmp/initrd.list
      exit 1
    fi
  done
  rm -f /tmp/initrd.list
  echo "   All required RK3588 early-boot drivers verified."
'

echo ">>> Image verification PASSED for ${IMAGE}"
