#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fragment="$repo_root/config/qubes-os-r4.3-templates-community-guix.example.yml"

if ! command -v python3 >/dev/null 2>&1; then
    printf 'release-config fragment check missing required command: python3\n' >&2
    exit 1
fi

python3 - "$fragment" <<'PY'
from pathlib import Path
import sys

try:
    import yaml
except ImportError as exc:
    raise SystemExit("release-config fragment check missing Python module: yaml") from exc

path = Path(sys.argv[1])
data = yaml.safe_load(path.read_text())

def keyed_mapping(items):
    result = {}
    for item in items or []:
        if not isinstance(item, dict) or len(item) != 1:
            raise SystemExit(f"expected single-key mapping in {path}: {item!r}")
        key, value = next(iter(item.items()))
        result[key] = value
    return result

components = keyed_mapping(data.get("components"))
templates = keyed_mapping(data.get("templates"))

builder = components.get("builder-guix")
if not builder:
    raise SystemExit("missing builder-guix component")

expected_builder = {
    "packages": False,
    "fetch-versions-only": False,
    "branch": "main",
    "url": "https://github.com/<OWNER>/qubes-builder-guix",
    "maintainers": ["<MAINTAINER_GPG_FINGERPRINT>"],
}
if builder != expected_builder:
    raise SystemExit(f"unexpected builder-guix entry: {builder!r}")

expected_templates = {
    "guix": {"dist": "guix", "timeout": 21600},
    "guix-minimal": {"dist": "guix", "flavor": "minimal", "timeout": 21600},
}
for name, expected in expected_templates.items():
    actual = templates.get(name)
    if actual != expected:
        raise SystemExit(f"unexpected {name} template entry: {actual!r}")

print("release-config fragment contract check passed")
PY
