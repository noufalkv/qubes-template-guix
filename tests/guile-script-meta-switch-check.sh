#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
shebang='#!/run/current-system/profile/bin/guile -s'
missing=0

cd "$repo_root"

while IFS=: read -r file line _match; do
    context="$(sed -n "${line},$((line + 4))p" "$file")"
    if ! printf '%s\n' "$context" | grep -Fq '!#'; then
        printf '%s:%s: generated guile -s script is missing !# terminator\n' \
            "$file" "$line" >&2
        missing=1
    fi
done < <(grep -RFn -- "$shebang" native/modules)

[ "$missing" -eq 0 ] || exit 1

wait_for_session_source="native/modules/qubes/packages/qubes-vm.scm"
wait_for_session_start="$(
    grep -nF '"/etc/qubes-rpc/qubes.WaitForSession")' \
        "$wait_for_session_source" | head -n1 | cut -d: -f1
)"
[ -n "$wait_for_session_start" ] || {
    printf '%s: generated qubes.WaitForSession source not found\n' \
        "$wait_for_session_source" >&2
    exit 1
}
wait_for_session_block="$(
    sed -n "${wait_for_session_start},$((wait_for_session_start + 120))p" \
        "$wait_for_session_source"
)"
printf '%s\n' "$wait_for_session_block" |
    grep -Fq '/var/run/qubes/qrexec-server.' || {
        printf '%s:%s: qubes.WaitForSession does not wait for qrexec fork-server socket\n' \
            "$wait_for_session_source" "$wait_for_session_start" >&2
        exit 1
    }
if printf '%s\n' "$wait_for_session_block" | grep -Fq 'qrexec-client'; then
    printf '%s:%s: qubes.WaitForSession must not return just because qrexec-client exists\n' \
        "$wait_for_session_source" "$wait_for_session_start" >&2
    exit 1
fi
if printf '%s\n' "$wait_for_session_block" | grep -Fq -- '--default=True'; then
    printf '%s:%s: qubes.WaitForSession must not use invalid qubesdb-read --default form\n' \
        "$wait_for_session_source" "$wait_for_session_start" >&2
    exit 1
fi

if command -v guile >/dev/null 2>&1; then
    tmp="$(mktemp "${TMPDIR:-/tmp}/qubes-guix-guile-meta.XXXXXX")"
    trap 'rm -f "$tmp"' EXIT
    printf '#!/usr/bin/guile -s\n!#\n(display "ok")\n' >"$tmp"
    guile -s "$tmp" >/dev/null
fi

printf 'guile script meta-switch check passed\n'
