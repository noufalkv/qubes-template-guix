#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$repo_root/native/modules/qubes/files/qvm-template-repo-query-guix"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/qvm-template-repo-query-guix.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/repo/repodata" "$tmp/repo/rpm"
printf 'fake rpm payload\n' >"$tmp/repo/rpm/qubes-template-test-4.3.0-202605250001.noarch.rpm"
cat >"$tmp/repo/repodata/primary.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<metadata xmlns="http://linux.duke.edu/metadata/common"
          xmlns:rpm="http://linux.duke.edu/metadata/rpm"
          packages="1">
<package type="rpm">
  <name>qubes-template-test</name>
  <arch>noarch</arch>
  <version epoch="0" ver="4.3.0" rel="202605250001"/>
  <checksum type="sha256" pkgid="YES">fake</checksum>
  <summary>Qubes OS template for test</summary>
  <description>Qubes OS template for test.</description>
  <packager></packager>
  <url>https://www.qubes-os.org</url>
  <time file="1779660001" build="1779660000"/>
  <size package="17" installed="17" archive="17"/>
  <location href="rpm/qubes-template-test-4.3.0-202605250001.noarch.rpm"/>
  <format>
    <rpm:license>GPLv3+</rpm:license>
  </format>
</package>
</metadata>
XML
cat >"$tmp/repo/repodata/repomd.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<repomd xmlns="http://linux.duke.edu/metadata/repo">
  <data type="primary">
    <location href="repodata/primary.xml"/>
  </data>
</repomd>
XML
repo_url="file://$tmp/repo"
cat >"$tmp/payload-query" <<EOF
--repoid=qubes-templates-itl-testing
--releasever=4.3
qubes-template-test
---
[qubes-templates-itl-testing]
baseurl = $repo_url
enabled = 1
EOF

query_output="$(python3 "$helper" query <"$tmp/payload-query")"
expected='qubes-template-test|0|4.3.0|202605250001|qubes-templates-itl-testing|17|1779660000|GPLv3+|https://www.qubes-os.org|Qubes OS template for test|Qubes OS template for test.|'
if [ "$query_output" != "$expected" ]; then
    printf 'unexpected qvm-template Guix query output:\n%s\n' "$query_output" >&2
    exit 1
fi

sed 's/qubes-template-test$/qubes-template-test-4.3.0-202605250001/' \
    "$tmp/payload-query" >"$tmp/payload-download"
python3 "$helper" download <"$tmp/payload-download" >"$tmp/downloaded.rpm"
cmp "$tmp/repo/rpm/qubes-template-test-4.3.0-202605250001.noarch.rpm" \
    "$tmp/downloaded.rpm"

printf 'qvm-template Guix repo query fallback check passed\n'
