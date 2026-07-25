# SPDX-License-Identifier: GPL-3.0-or-later
SHELL := /usr/bin/env bash
GUIX ?= guix
PYTHON ?= python3
RUFF ?= ruff
SHELLCHECK ?= shellcheck

SHELL_SOURCES := $(wildcard scripts/*.sh tests/*.sh builder-v2-template/*.sh)
PYTHON_SOURCES := $(wildcard modules/qubes/files/*.py scripts/*.py tests/*.py)

.PHONY: \
	artifact-check \
	bootstrap-guix-secure-check \
	build-rootimg \
	build-rpm \
	builder-v2-content-contract-check \
	builder-rpm-contract-check \
	channel-source-copy-check \
	check \
	check-qubes-pins \
	guix-check \
	inspect-native-rootfs \
	lint \
	native-rootfs \
	network-uplink-sysctl-source-check \
	package-metadata-validation-check \
	package-native-template-rpm \
	prepare \
	python-unit-check \
	qubes-pin-writer-check \
	rpm-layout-check \
	shell-syntax-check \
	source-check \
	substitute-cache-failure-check \
	template-rpm-minimal \
	template-rpm-normal \
	update-check-behavior-check \
	update-check-contract-check

check: source-check artifact-check

# Release-capable hosts must exercise the Guix-backed behavior test rather
# than accepting its non-Guix SKIP path.
guix-check: REQUIRE_GUIX := 1
guix-check: check

source-check: \
	shell-syntax-check \
	python-unit-check \
	bootstrap-guix-secure-check \
	builder-v2-content-contract-check \
	channel-source-copy-check \
	network-uplink-sysctl-source-check \
	package-metadata-validation-check \
	qubes-pin-writer-check \
	substitute-cache-failure-check \
	update-check-behavior-check \
	update-check-contract-check

artifact-check: builder-rpm-contract-check rpm-layout-check

shell-syntax-check:
	bash -n $(SHELL_SOURCES)

python-unit-check:
	PYTHONDONTWRITEBYTECODE=1 \
		$(PYTHON) -m unittest discover -s tests -p 'test_*.py'

lint:
	$(SHELLCHECK) -x $(SHELL_SOURCES)
	$(RUFF) check $(PYTHON_SOURCES)

bootstrap-guix-secure-check:
	./tests/bootstrap-guix-secure-check.sh

builder-v2-content-contract-check:
	./tests/builder-v2-content-contract-check.sh

channel-source-copy-check:
	bash ./tests/channel-source-copy-check.sh

network-uplink-sysctl-source-check:
	./tests/network-uplink-sysctl-source-check.sh

package-metadata-validation-check:
	./tests/package-metadata-validation-check.sh

qubes-pin-writer-check:
	bash ./tests/check-qubes-pins-write-check.sh

substitute-cache-failure-check:
	./tests/substitute-cache-failure-check.sh

update-check-behavior-check:
	REQUIRE_GUIX="$(REQUIRE_GUIX)" GUIX="$(GUIX)" \
		./tests/update-check-behavior-check.sh

update-check-contract-check:
	./tests/update-check-contract-check.sh

builder-rpm-contract-check:
	./tests/builder-rpm-contract-check.sh

rpm-layout-check:
	./tests/rpm-layout-check.sh

check-qubes-pins:
	./scripts/check-qubes-pins.sh

prepare:
	@:


build-rootimg:
	./scripts/builder-v2-template-adapter.sh build-rootimg

build-rpm:
	./scripts/builder-v2-template-adapter.sh build-rpm

native-rootfs:
	./scripts/build-native-rootfs.sh

inspect-native-rootfs:
	./scripts/inspect-native-rootfs.sh

package-native-template-rpm:
	./scripts/package-native-template-rpm.sh

template-rpm-normal:
	./scripts/build-template-rpm.sh \
		--variant normal \
		--version "$${VERSION:-4.3.0}" \
		--release "$${RELEASE:-$$(date -u +%Y%m%d%H%M)}"

template-rpm-minimal:
	./scripts/build-template-rpm.sh \
		--variant minimal \
		--version "$${VERSION:-4.3.0}" \
		--release "$${RELEASE:-$$(date -u +%Y%m%d%H%M)}"
