#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail() {
    printf 'maintainer-preflight failed: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf 'warning: %s\n' "$*" >&2
}

tmpdirs=()
cleanup() {
    if [ "${#tmpdirs[@]}" -gt 0 ]; then
        rm -rf "${tmpdirs[@]}"
    fi
}
trap cleanup EXIT

make_tmpdir() {
    local kind
    kind="$1"
    mktemp -d "$repo_root/maintainer-preflight.$kind.XXXXXX"
}

check_shell_syntax() {
    while IFS= read -r script; do
        bash -n "$script"
    done < <(find scripts tests builder-v2-template -type f -name '*.sh' | sort)
}

check_scheme_load() {
    if command -v guix >/dev/null 2>&1; then
        guix repl -L "$repo_root/native/modules" -- /dev/stdin <<EOF
(use-modules (qubes packages qubes-vm)
             (qubes services qubes-vm)
             (guix packages))
(load "$repo_root/native/qubes-guix.scm")

(define qubes-release-version
  (@@ (qubes packages qubes-vm) qubes-release-version))

(define (expect-package-version package component)
  (unless (string=? (package-version package)
                    (qubes-release-version component))
    (error "package version does not match pinned component"
           (package-name package)
           (package-version package)
           (qubes-release-version component))))

(expect-package-version qubes-libvchan-xen "qubes-core-vchan-xen")
(expect-package-version qubes-linux-utils-qrexec "qubes-linux-utils")
(expect-package-version qubes-vm-utils "qubes-linux-utils")
(expect-package-version qubesdb-vm "qubes-core-qubesdb")
(expect-package-version qubes-vm-qrexec "qubes-core-qrexec")
(expect-package-version qubes-vm-core "qubes-core-agent-linux")
(expect-package-version qubes-vm-gui-common "qubes-gui-common")
(expect-package-version qubes-vm-gui "qubes-gui-agent-linux")
EOF
    else
        warn "guix command not found; skipping Guix module load checks"
    fi
}

check_executable_scripts() {
    while IFS= read -r path; do
        [ -x "$path" ] || fail "expected executable script: $path"
    done < <(find scripts tests builder-v2-template -type f -name '*.sh' | sort)
}

check_no_tracked_artifacts() {
    if ! command -v git >/dev/null 2>&1 ||
        ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        return
    fi

    local tracked_artifacts
    tracked_artifacts="$(
        git ls-files dist .cache root.img root.img.* root-minimal.img \
            root-minimal.img.* work work.* work.builder-v2 \
            maintainer-preflight.* \
            mnt mnt.* inspect.* activation.* \
            2>/dev/null
    )"
    [ -z "$tracked_artifacts" ] ||
        fail "generated build artifacts must not be tracked: $tracked_artifacts"
}

check_release_config_yaml() {
    python3 - <<'PY'
from pathlib import Path
import sys

try:
    import yaml
except ModuleNotFoundError:
    print("warning: PyYAML not found; skipping release-config YAML parse", file=sys.stderr)
    raise SystemExit(0)

path = Path("config/qubes-os-r4.3-templates-community-guix.example.yml")
data = yaml.safe_load(path.read_text())
components = data.get("components") or []
templates = data.get("templates") or []

component_names = {
    next(iter(item)) for item in components if isinstance(item, dict) and item
}
template_items = {
    next(iter(item)): next(iter(item.values()))
    for item in templates
    if isinstance(item, dict) and item
}

def expect(condition, message):
    if not condition:
        raise SystemExit(message)

expect("builder-guix" in component_names, "missing builder-guix component")
expect(
    template_items.get("guix", {}).get("dist") == "guix",
    "guix template does not use dist: guix",
)
expect(
    template_items.get("guix-minimal", {}).get("dist") == "guix",
    "guix-minimal template does not use dist: guix",
)
expect(
    template_items.get("guix-minimal", {}).get("flavor") == "minimal",
    "guix-minimal template does not use flavor: minimal",
)
PY
}

check_example_patch_applies() {
    local source_repo="$1"
    local patch="$2"
    local label="$3"

    if [ ! -d "$source_repo/.git" ]; then
        warn "skipping $label patch check; missing checkout: $source_repo"
        return
    fi

    local work
    work="$(make_tmpdir patch)"
    tmpdirs+=("$work")
    git clone --quiet --shared "$source_repo" "$work/repo"
    git -C "$work/repo" apply --check "$repo_root/$patch"
}

check_shell_syntax
check_scheme_load
check_executable_scripts
check_no_tracked_artifacts
check_release_config_yaml
check_example_patch_applies /tmp/qubes-builderv2 \
    config/qubes-builderv2-guix.example.patch "Builder v2"
check_example_patch_applies /tmp/qubes-release-configs \
    config/qubes-release-configs-guix.example.patch "release-config"

printf 'maintainer preflight passed\n'
