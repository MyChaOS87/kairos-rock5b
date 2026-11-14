CONTAINER_ENGINE ?= podman
REGISTRY         ?= ghcr.io/mychaos87
IMAGE_NAME       ?= kairos-rock5b

include versions.conf

PROFILE ?= debian-trixie-bpo
VARIANT ?= k3s

ifeq ($(PROFILE),debian-trixie-bpo)
KERNEL_VERSION ?= $(BPO_KERNEL_VERSION)
else ifeq ($(PROFILE),debian-trixie)
KERNEL_VERSION ?= $(LTS_KERNEL_VERSION)
else
KERNEL_VERSION ?=
endif

KV_STRIPPED := $(strip $(KERNEL_VERSION))
ifeq ($(KV_STRIPPED),)
KERNEL_PACKAGE ?= linux-image-arm64
else ifneq ($(filter linux-image-%,$(KV_STRIPPED)),)
KERNEL_PACKAGE ?= $(KV_STRIPPED)
else ifneq ($(findstring -arm64,$(KV_STRIPPED)),)
KERNEL_PACKAGE ?= linux-image-$(KV_STRIPPED)
else
KERNEL_PACKAGE ?= linux-image-$(KV_STRIPPED)-arm64
endif

ifeq ($(VARIANT),k3s)
KAIROS_INIT_ARGS ?= -p k3s --provider-k3s-version $(K3S_VERSION)
VARIANT_LABEL    ?= k3s $(K3S_VERSION)
ORCH_SUFFIX      ?= -$(subst +,-,$(K3S_VERSION))
else ifeq ($(VARIANT),k0s)
KAIROS_INIT_ARGS ?= -p k0s
VARIANT_LABEL    ?= k0s
ORCH_SUFFIX      ?=
else
KAIROS_INIT_ARGS ?=
VARIANT_LABEL    ?= $(VARIANT)
ORCH_SUFFIX      ?=
endif

ROLLING_TAG  := $(REGISTRY)/$(IMAGE_NAME):$(PROFILE)-$(VARIANT)
IMAGE        ?= $(ROLLING_TAG)
CLOUD_CONFIG ?= ./docs/examples/cloud-config.example.yaml
OUTPUT_DIR   ?= ./build

.PHONY: all lint check-syntax check-anonymity build build-lts verify-image build-installer clean

all: lint

lint: check-syntax check-anonymity

check-syntax:
	@echo ">>> Checking shell script syntax..."
	@bash -n scripts/rock5b-sync-boot.sh
	@bash -n scripts/verify-image.sh
	@bash -n scripts/build-installer-img.sh
	@bash -n scripts/flash-spi-uboot.sh
	@echo ">>> Shell syntax OK."

check-anonymity:
	@echo ">>> Checking repository for local paths, private LAN subnets, stale line anchors, or environment-specific leaks..."
	@! grep -rnE "(/home/[a-zA-Z0-9_-]+|file://|192\.168\.[0-9]+\.[0-9]+|10\.[0-9]+\.[0-9]+\.[0-9]+|172\.(1[6-9]|2[0-9]|3[0-1])\.[0-9]+\.[0-9]+)" Dockerfile versions.conf profiles/ system/ scripts/ docs/ README.md CONTEXT.md AGENTS.md .github/ || (echo "ERROR: Found local user path, file:// URL, or RFC 1918 private IP address in tracked files; use relative paths and RFC 5737 (192.0.2.x) instead." && exit 1)
	@! grep -rnE "#L[0-9]+" versions.conf docs/ README.md CONTEXT.md AGENTS.md || (echo "ERROR: Found #L<line> Markdown line anchor in documentation; link to file paths only." && exit 1)
	@echo ">>> Anonymity check PASSED."

build:
	$(CONTAINER_ENGINE) build --platform linux/arm64 \
		--build-arg KAIROS_INIT_VERSION="$(KAIROS_INIT_VERSION)" \
		--build-arg UBOOT_VERSION="$(UBOOT_VERSION)" \
		--build-arg RKBIN_COMMIT="$(RKBIN_COMMIT)" \
		--build-arg RKBIN_DDR="$(RKBIN_DDR)" \
		--build-arg RKBIN_BL31="$(RKBIN_BL31)" \
		--build-arg BASE_IMAGE="$(BASE_IMAGE)" \
		--build-arg PROFILE="$(PROFILE)" \
		--build-arg KERNEL_PACKAGE="$(KERNEL_PACKAGE)" \
		--build-arg KAIROS_VERSION="$(KAIROS_VERSION)" \
		--build-arg KAIROS_INIT_ARGS="$(KAIROS_INIT_ARGS)" \
		--build-arg VARIANT_LABEL="$(VARIANT_LABEL)" \
		-t "$(ROLLING_TAG)" \
		.
	@KVER=$$($(CONTAINER_ENGINE) run --rm --entrypoint /bin/cat "$(ROLLING_TAG)" /etc/rock5b-kernel-version); \
	PINNED_TAG="$(REGISTRY)/$(IMAGE_NAME):$(PROFILE)-$${KVER}-$(VARIANT)$(ORCH_SUFFIX)"; \
	$(CONTAINER_ENGINE) tag "$(ROLLING_TAG)" "$${PINNED_TAG}"; \
	echo ">>> Tagged: $(ROLLING_TAG)"; \
	echo ">>> Tagged: $${PINNED_TAG}"

build-lts:
	$(MAKE) build PROFILE=debian-trixie

verify-image:
	CONTAINER_ENGINE="$(CONTAINER_ENGINE)" ./scripts/verify-image.sh "$(IMAGE)"

build-installer:
	CONTAINER_ENGINE="$(CONTAINER_ENGINE)" \
	AURORABOOT_IMAGE="quay.io/kairos/auroraboot:$(AURORABOOT_VERSION)" \
	./scripts/build-installer-img.sh "$(IMAGE)" "$(CLOUD_CONFIG)" "$(OUTPUT_DIR)"

clean:
	rm -rf "$(OUTPUT_DIR)"
