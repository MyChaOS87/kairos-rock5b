ARG BUILDPLATFORM
ARG KAIROS_INIT_VERSION=v4.5.0
ARG BASE_IMAGE=debian:trixie-slim
ARG UBOOT_VERSION=v2026.10
ARG RKBIN_COMMIT=3e288fe814e059dd06833495f845cab04ac20a5c
ARG RKBIN_DDR=bin/rk35/rk3588_ddr_lp4_2112MHz_lp5_2400MHz_v1.24.bin
ARG RKBIN_BL31=bin/rk35/rk3588_bl31_v1.56.elf

FROM quay.io/kairos/kairos-init:${KAIROS_INIT_VERSION} AS kairos-init

FROM --platform=${BUILDPLATFORM:-linux/arm64} debian:trixie-slim AS uboot
ARG UBOOT_VERSION
ARG RKBIN_COMMIT
ARG RKBIN_DDR
ARG RKBIN_BL31
RUN set -eu; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update -qq; \
    apt-get install -y --no-install-recommends \
      bc bison build-essential ca-certificates curl device-tree-compiler \
      flex gcc-aarch64-linux-gnu libgnutls28-dev libncurses-dev libssl-dev \
      openssl pkg-config python3 python3-dev python3-pyelftools \
      python3-setuptools swig uuid-dev; \
    mkdir -p /src/rkbin /src/uboot /out; \
    curl -fsSL "https://raw.githubusercontent.com/rockchip-linux/rkbin/${RKBIN_COMMIT}/${RKBIN_DDR}" -o /src/rkbin/ddr.bin; \
    curl -fsSL "https://raw.githubusercontent.com/rockchip-linux/rkbin/${RKBIN_COMMIT}/${RKBIN_BL31}" -o /src/rkbin/bl31.elf; \
    curl -fsSL "https://github.com/u-boot/u-boot/archive/refs/tags/${UBOOT_VERSION}.tar.gz" | tar -xz --strip-components=1 -C /src/uboot; \
    make -C /src/uboot rock5b-rk3588_defconfig; \
    BL31=/src/rkbin/bl31.elf ROCKCHIP_TPL=/src/rkbin/ddr.bin CROSS_COMPILE=aarch64-linux-gnu- \
      make -C /src/uboot -j"$(nproc)"; \
    cp -f /src/uboot/u-boot-rockchip-spi.bin /src/uboot/u-boot-rockchip.bin /out/

FROM ${BASE_IMAGE}
ARG PROFILE=debian-trixie-bpo
ARG KERNEL_PACKAGE=linux-image-arm64
ARG KAIROS_VERSION=v1.0.0
ARG KAIROS_INIT_ARGS="-p k3s --provider-k3s-version v1.37.2+k3s1"
ARG VARIANT_LABEL="k3s v1.37.2+k3s1"

COPY --from=uboot /out/ /usr/share/rock5b-uboot/
COPY --chmod=0755 scripts/rock5b-sync-boot.sh /usr/sbin/rock5b-sync-boot
COPY system/oem/20_rock5b_hardware.yaml /system/oem/20_rock5b_hardware.yaml
COPY profiles/common.yaml /etc/kairos-init/stage-extensions/10-common.yaml
COPY profiles/${PROFILE}.yaml /etc/kairos-init/stage-extensions/20-profile.yaml

RUN --mount=type=bind,from=kairos-init,src=/kairos-init,dst=/kairos-init \
    set -eu; \
    printf 'name: "Install Debian kernel packages"\nstages:\n  install:\n    - name: "Install configured Debian kernel and firmware packages"\n      packages:\n        install:\n          - %s\n          - firmware-linux-free\n        refresh: true\n        upgrade: true\n' "${KERNEL_PACKAGE}" > /etc/kairos-init/stage-extensions/15-kernel.yaml; \
    /kairos-init -l info -s all -m generic -x --skip-step installKernel -v "${KAIROS_VERSION}" ${KAIROS_INIT_ARGS}; \
    rm -rf /etc/kairos-init /var/lib/apt/lists/*; \
    KVER_FULL="$(ls -1 /lib/modules | sort -V | tail -n 1)"; \
    KVER_SHORT="$(echo "${KVER_FULL}" | sed -E 's/^([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/')"; \
    echo "${KVER_FULL}" > /etc/rock5b-kernel-release; \
    echo "${KVER_SHORT}" > /etc/rock5b-kernel-version; \
    FULL_KAIROS_VER="${KAIROS_VERSION}-${PROFILE}-${KVER_SHORT}"; \
    PRETTY="Kairos (${PROFILE} ${KVER_SHORT} / ${VARIANT_LABEL})"; \
    sed -i --follow-symlinks "s|^PRETTY_NAME=.*|PRETTY_NAME=\"${PRETTY}\"|" /etc/os-release; \
    sed -i "s|^KAIROS_VERSION=.*|KAIROS_VERSION=\"${FULL_KAIROS_VER}\"|" /etc/kairos-release; \
    sed -i "s|^KAIROS_RELEASE=.*|KAIROS_RELEASE=\"${FULL_KAIROS_VER}\"|" /etc/kairos-release; \
    echo "KAIROS_PROFILE=\"${PROFILE}\"" >> /etc/kairos-release; \
    echo "KAIROS_KERNEL_VERSION=\"${KVER_SHORT}\"" >> /etc/kairos-release; \
    /kairos-init validate
