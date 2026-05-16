# SPDX-License-Identifier: GPL-3.0-or-later
SHELL := /usr/bin/env bash

.PHONY: check builder-content-check builder-rpm-contract-check rpm-layout-check check-qubes-pins prepare build-rootimg build-rpm foreign-template test-foreign-template native-rootfs inspect-native-rootfs import-native-rootfs package-native-template-rpm test-native-template nested-dom0-status setup-openqa-guix-template-test openqa-template-rpm-normal openqa-template-rpm-minimal openqa-template-rpm-system-tests

check: builder-content-check builder-rpm-contract-check rpm-layout-check

builder-content-check:
	./tests/builder-content-check.sh

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

foreign-template:
	./scripts/create-foreign-guix-template-dom0.sh

test-foreign-template:
	./scripts/test-foreign-guix-template-dom0.sh "$${TEMPLATE_NAME:-guix-debian-13}"

native-rootfs:
	./scripts/build-native-rootfs.sh

inspect-native-rootfs:
	./scripts/inspect-native-rootfs.sh

import-native-rootfs:
	./scripts/import-native-rootfs-dom0.sh

package-native-template-rpm:
	./scripts/package-native-template-rpm.sh

test-native-template:
	./scripts/test-native-guix-template-dom0.sh "$${TEMPLATE_NAME:-guix-native-test}"

nested-dom0-status:
	./scripts/qubes-nested-dom0-host.sh status

setup-openqa-guix-template-test:
	./scripts/setup-openqa-guix-template-test.sh

openqa-template-rpm-normal:
	./scripts/run-openqa-template-rpm.sh --variant normal --watch

openqa-template-rpm-minimal:
	./scripts/run-openqa-template-rpm.sh --variant minimal --watch

openqa-template-rpm-system-tests:
	./scripts/run-openqa-template-rpm.sh --variant "$${VARIANT:-normal}" --run-system-tests --watch
