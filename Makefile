# SPDX-License-Identifier: GPL-3.0-or-later
SHELL := /usr/bin/env bash

.PHONY: \
	build-rootimg \
	build-rpm \
	builder-rpm-contract-check \
	check \
	check-qubes-pins \
	inspect-native-rootfs \
	native-rootfs \
	package-native-template-rpm \
	prepare \
	render-config \
	rpm-layout-check \
	template-rpm-minimal \
	template-rpm-normal

check: builder-rpm-contract-check rpm-layout-check

builder-rpm-contract-check:
	./tests/builder-rpm-contract-check.sh

rpm-layout-check:
	./tests/rpm-layout-check.sh

check-qubes-pins:
	./scripts/check-qubes-pins.sh

prepare:
	@:

render-config:
	./scripts/render-config.sh \
		--variant "$${VARIANT:-normal}" \
		--output "$${OUTPUT:-config.$${VARIANT:-normal}.scm}"

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
