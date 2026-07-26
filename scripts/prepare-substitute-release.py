#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Prepare sharded GitHub Release assets and a retained Guix cache index.

The input is a fresh static cache produced by ``build-substitute-cache.sh``.
NAR payloads are stored as immutable GitHub Release assets while GitHub Pages
contains only ``nix-cache-info`` and the retained ``*.narinfo`` index.  Each
narinfo URL is changed from a local ``nar/...`` path to the absolute URL of the
corresponding Release asset; every other byte, including every ``Signature:``
line, is preserved.

Generation metadata uses schema version 2.  A metadata ZIP contains exactly::

    substitute-cache-v2/manifest.json
    substitute-cache-v2/nix-cache-info
    substitute-cache-v2/narinfo/<store-hash>.narinfo

The manifest records the SHA-256 and size of every member, the immutable shard
that owns every referenced NAR asset, and which NAR assets were first
published with that generation.  Generation metadata uses the deterministic
tag ``substitute-cache-v2-<qubes-commit>-<guix-commit>`` and is kept separate
from NAR shards.  A shard holds at most 900 assets and uses the content-bound
tag ``substitute-cache-nars-v2-<qubes-commit>-<guix-commit>-NNNN-<sha256>``,
where ``sha256`` identifies its canonical asset set.  ZIPs without the
version-2 manifest member are pre-epoch input and are ignored.

Existing NAR references are accepted only after a release inventory confirms
that the published shard contains a completely uploaded canonical asset with
its recorded size and SHA-256.  The compact inventory format is::

    {
      "repository": "OWNER/REPOSITORY",
      "releases": [
        {
          "release_tag": "TAG",
          "published_at": "YYYY-MM-DDTHH:MM:SSZ",
          "assets": [{
            "name": "ASSET",
            "size": 123,
            "digest": "sha256:<64 lowercase hex characters>",
            "state": "uploaded"
          }]
        }
      ]
    }

Output layout::

    release-assets/substitute-cache-v2-manifest.json
    release-assets/substitute-cache-v2-metadata.zip
    release-assets/nar-shards/<shard-tag>/nar-v2-sha256-<digest>
                                                (new objects only)
    pages/nix-cache-info
    pages/<store-hash>.narinfo
    release-plan.json

The ``recover`` subcommand writes only ``pages/`` and ``release-plan.json``
from prior version-2 metadata.  It is the idempotent recovery path when the
deterministic Release exists but a later Pages deployment did not complete.

``release-plan.json`` lists retained, Pages-expired, grace-protected, and
deletable releases.  A newly expired generation first requests the empty
marker Release ``substitute-cache-gc-v2-<qubes-commit>-<guix-commit>``.  Its
actual post-deployment publication time starts the GC grace interval.  A NAR
shard is deletable only when no retained or marker-protected generation
references it.  Markers invalidated by re-retention are listed separately for
revocation before the new Pages state is deployed.  The default policy keeps
generations from the last 180 days and at least the eight newest generations,
then requires a one-day marker grace interval before destructive garbage
collection.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import stat
import sys
import tempfile
import zipfile
from dataclasses import dataclass, field, replace
from pathlib import Path, PurePosixPath
from typing import Any, Iterable, NoReturn


SCHEMA = "org.qubes-os.qubes-template-guix.substitute-cache-generation"
PLAN_SCHEMA = "org.qubes-os.qubes-template-guix.substitute-cache-release-plan"
SCHEMA_VERSION = 2
ARCHIVE_ROOT = "substitute-cache-v2"
MANIFEST_MEMBER = f"{ARCHIVE_ROOT}/manifest.json"
NIX_CACHE_MEMBER = f"{ARCHIVE_ROOT}/nix-cache-info"
METADATA_ASSET = "substitute-cache-v2-metadata.zip"
MANIFEST_ASSET = "substitute-cache-v2-manifest.json"
TAG_PREFIX = "substitute-cache-v2-"
NAR_SHARD_TAG_PREFIX = "substitute-cache-nars-v2-"
GC_MARKER_TAG_PREFIX = "substitute-cache-gc-v2-"
MAX_NAR_ASSETS_PER_SHARD = 900
DEFAULT_RETENTION_DAYS = 180
DEFAULT_MINIMUM_GENERATIONS = 8
DEFAULT_GC_GRACE_DAYS = 1
MAX_RETENTION_DAYS = 36_500
MAX_MINIMUM_GENERATIONS = 50_000
MAX_GC_GRACE_DAYS = 36_500
MAX_NARINFO_SIZE = 2 * 1024 * 1024
MAX_NIX_CACHE_INFO_SIZE = 64 * 1024
MAX_MANIFEST_SIZE = 64 * 1024 * 1024
MAX_INVENTORY_SIZE = 64 * 1024 * 1024
MAX_ARCHIVE_MEMBERS = 50_002
MAX_ARCHIVE_EXPANDED_SIZE = 128 * 1024 * 1024
MAX_METADATA_ARCHIVE_SIZE = 160 * 1024 * 1024
MAX_FILE_SIZE = (1 << 63) - 1

STORE_HASH_RE = re.compile(r"[0-9abcdfghijklmnpqrsvwxyz]{32}")
NARINFO_NAME_RE = re.compile(STORE_HASH_RE.pattern + r"\.narinfo")
SAFE_NAR_SEGMENT_RE = re.compile(r"[A-Za-z0-9._+-]+")
SAFE_TAG_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,254}")
SAFE_REPOSITORY_PART_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,99}")
SHA256_RE = re.compile(r"[0-9a-f]{64}")
GITHUB_SHA256_RE = re.compile(r"sha256:([0-9a-f]{64})")
COMMIT_RE = re.compile(r"[0-9a-f]{40}")
TIMESTAMP_RE = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z")
GENERATION_TAG_RE = re.compile(re.escape(TAG_PREFIX) + r"([0-9a-f]{40})-([0-9a-f]{40})")
NAR_SHARD_TAG_RE = re.compile(
    re.escape(NAR_SHARD_TAG_PREFIX)
    + r"([0-9a-f]{40})-([0-9a-f]{40})-([0-9]{4})-([0-9a-f]{64})"
)
GC_MARKER_TAG_RE = re.compile(
    re.escape(GC_MARKER_TAG_PREFIX) + r"([0-9a-f]{40})-([0-9a-f]{40})"
)


class StateError(ValueError):
    """Raised when cache input or immutable generation metadata is unsafe."""


@dataclass(frozen=True)
class Asset:
    """An immutable NAR asset and the release that owns it."""

    sha256: str
    size: int
    name: str
    url: str
    owner_repository: str
    owner_release_tag: str


@dataclass(frozen=True)
class Narinfo:
    """A narinfo member and the NAR object it references."""

    path: str
    content: bytes
    nar_sha256: str


@dataclass(frozen=True)
class NarinfoContentIdentity:
    """Stable signed fields that identify one store item's contents."""

    store_path: bytes
    nar_hash: bytes
    nar_size: bytes
    references: bytes


@dataclass(frozen=True)
class Generation:
    """One validated immutable cache generation."""

    repository: str
    release_tag: str
    qubes_commit: str
    guix_commit: str
    generated_at: dt.datetime
    generated_at_text: str
    nix_cache_info: bytes
    narinfos: tuple[Narinfo, ...]
    objects: tuple[Asset, ...]
    published_sha256: tuple[str, ...]
    metadata_sha256: str | None = field(default=None, compare=False)
    metadata_size: int | None = field(default=None, compare=False)
    manifest_sha256: str | None = field(default=None, compare=False)
    manifest_size: int | None = field(default=None, compare=False)

    @property
    def release_id(self) -> tuple[str, str]:
        return (self.repository, self.release_tag)

    @property
    def object_map(self) -> dict[str, Asset]:
        return {asset.sha256: asset for asset in self.objects}


@dataclass(frozen=True)
class ReleaseInventory:
    """Published GitHub Releases and their API-reported assets."""

    repository: str
    releases: dict[str, "InventoryRelease"]


@dataclass(frozen=True)
class InventoryRelease:
    """One public GitHub Release observed through the API."""

    published_at: dt.datetime
    assets: dict[str, "InventoryAsset"]


@dataclass(frozen=True)
class InventoryAsset:
    """One completely uploaded GitHub Release asset."""

    size: int
    sha256: str


@dataclass(frozen=True)
class LocalNarinfo:
    """A validated narinfo from the fresh local static cache."""

    path: str
    content: bytes
    nar_relative_url: str
    nar_path: Path
    nar_size: int


@dataclass(frozen=True)
class ExpiredGeneration:
    """A Pages-expired generation and its durable GC-marker state."""

    generation: Generation
    dropped_at: dt.datetime
    marker_release_tag: str
    marker_published_at: dt.datetime | None
    delete_after: dt.datetime | None


@dataclass(frozen=True)
class GenerationRetention:
    """Pages and garbage-collection classification for all generations."""

    retained: tuple[Generation, ...]
    gc_protected_expired: tuple[ExpiredGeneration, ...]
    deletable_expired: tuple[ExpiredGeneration, ...]

    @property
    def expired(self) -> tuple[ExpiredGeneration, ...]:
        return tuple(
            sorted(
                self.gc_protected_expired + self.deletable_expired,
                key=lambda state: (
                    state.generation.generated_at,
                    state.generation.release_tag,
                ),
                reverse=True,
            )
        )


def fail(message: str) -> NoReturn:
    raise StateError(message)


def canonical_json(value: Any) -> bytes:
    """Return the one accepted JSON representation for version-2 metadata."""

    return (
        json.dumps(
            value,
            ensure_ascii=True,
            sort_keys=True,
            separators=(",", ":"),
        )
        + "\n"
    ).encode("ascii")


def sha256_bytes(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def hash_file(path: Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    size = 0
    try:
        with path.open("rb") as source:
            while chunk := source.read(1024 * 1024):
                digest.update(chunk)
                size += len(chunk)
                if size > MAX_FILE_SIZE:
                    fail(f"file is too large: {path}")
    except OSError as error:
        fail(f"cannot read {path}: {error}")
    return digest.hexdigest(), size


def validate_repository(value: str, field: str = "repository") -> str:
    if not isinstance(value, str):
        fail(f"{field} must be a string")
    parts = value.split("/")
    if (
        len(parts) != 2
        or any(not SAFE_REPOSITORY_PART_RE.fullmatch(part) for part in parts)
        or any(part in {".", ".."} or ".." in part for part in parts)
    ):
        fail(f"invalid GitHub {field}: {value!r}")
    return value


def validate_github_tag(value: str, field: str = "release tag") -> str:
    if not isinstance(value, str) or not SAFE_TAG_RE.fullmatch(value):
        fail(f"invalid GitHub {field}: {value!r}")
    return value


def validate_generation_tag(value: str, field: str = "release tag") -> str:
    value = validate_github_tag(value, field)
    if not GENERATION_TAG_RE.fullmatch(value):
        fail(f"invalid generation {field}: {value!r}")
    return value


def parse_nar_shard_tag(
    value: str, field: str = "NAR shard release tag"
) -> tuple[str, str, int, str]:
    value = validate_github_tag(value, field)
    match = NAR_SHARD_TAG_RE.fullmatch(value)
    if match is None or match.group(3) == "0000":
        fail(f"invalid {field}: {value!r}")
    return match.group(1), match.group(2), int(match.group(3)), match.group(4)


def parse_timestamp(value: Any, field: str) -> dt.datetime:
    if not isinstance(value, str) or not TIMESTAMP_RE.fullmatch(value):
        fail(f"{field} must use canonical UTC form YYYY-MM-DDTHH:MM:SSZ")
    try:
        parsed = dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError as error:
        fail(f"invalid {field}: {error}")
    return parsed.replace(tzinfo=dt.timezone.utc)


def require_exact_keys(value: Any, expected: set[str], field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"{field} must be an object")
    actual = set(value)
    if actual != expected:
        missing = sorted(expected - actual)
        unexpected = sorted(actual - expected)
        fail(
            f"{field} has invalid fields "
            f"(missing={missing!r}, unexpected={unexpected!r})"
        )
    return value


def require_string(value: Any, field: str) -> str:
    if not isinstance(value, str):
        fail(f"{field} must be a string")
    return value


def require_size(value: Any, field: str, *, allow_zero: bool = False) -> int:
    minimum = 0 if allow_zero else 1
    if (
        isinstance(value, bool)
        or not isinstance(value, int)
        or value < minimum
        or value > MAX_FILE_SIZE
    ):
        fail(f"{field} must be an integer from {minimum} to {MAX_FILE_SIZE}")
    return value


def require_sha256(value: Any, field: str) -> str:
    if not isinstance(value, str) or not SHA256_RE.fullmatch(value):
        fail(f"{field} must be a lowercase SHA-256 digest")
    return value


def require_commit(value: Any, field: str) -> str:
    if not isinstance(value, str) or not COMMIT_RE.fullmatch(value):
        fail(f"{field} must be an exact lowercase 40-hex Git commit")
    return value


def release_tag_for_commits(qubes_commit: str, guix_commit: str) -> str:
    """Return the collision-free generation tag for resolved source inputs."""

    return f"{TAG_PREFIX}{qubes_commit}-{guix_commit}"


def nar_shard_tag_for_commits(
    qubes_commit: str,
    guix_commit: str,
    shard_number: int,
    shard_asset_set_sha256: str,
) -> str:
    """Return the content-bound NAR shard tag for a generation."""

    if not 1 <= shard_number <= 9999:
        fail("NAR shard number must be from 1 to 9999")
    shard_asset_set_sha256 = require_sha256(
        shard_asset_set_sha256, "NAR shard asset-set SHA-256"
    )
    return (
        f"{NAR_SHARD_TAG_PREFIX}{qubes_commit}-{guix_commit}-"
        f"{shard_number:04d}-{shard_asset_set_sha256}"
    )


def gc_marker_tag_for_commits(qubes_commit: str, guix_commit: str) -> str:
    """Return the durable post-deployment GC marker tag for a generation."""

    return f"{GC_MARKER_TAG_PREFIX}{qubes_commit}-{guix_commit}"


def generation_tag_for_gc_marker(marker_tag: str) -> str:
    """Return the generation tag named by a validated GC marker tag."""

    marker_tag = validate_github_tag(marker_tag, "GC marker release tag")
    match = GC_MARKER_TAG_RE.fullmatch(marker_tag)
    if match is None:
        fail(f"invalid GC marker release tag: {marker_tag!r}")
    return release_tag_for_commits(match.group(1), match.group(2))


def validate_revision_tag(
    release_tag: str,
    qubes_commit: str,
    guix_commit: str,
    field: str = "release tag",
) -> None:
    expected = release_tag_for_commits(qubes_commit, guix_commit)
    if release_tag != expected:
        fail(
            f"{field} does not match the exact Qubes and Guix commits; "
            f"expected {expected!r}"
        )


def asset_name(digest: str) -> str:
    return f"nar-v2-sha256-{digest}"


def nar_shard_asset_set_digest(assets: Iterable[tuple[str, int]]) -> str:
    """Hash the canonical names, digests, and sizes uploaded to one shard."""

    canonical_assets: list[dict[str, Any]] = []
    seen: set[str] = set()
    for index, (raw_digest, raw_size) in enumerate(assets):
        digest = require_sha256(raw_digest, f"NAR shard asset[{index}].sha256")
        size = require_size(raw_size, f"NAR shard asset[{index}].size")
        if digest in seen:
            fail(f"NAR shard asset set contains duplicate SHA-256: {digest}")
        seen.add(digest)
        canonical_assets.append(
            {"name": asset_name(digest), "sha256": digest, "size": size}
        )
    if not 1 <= len(canonical_assets) <= MAX_NAR_ASSETS_PER_SHARD:
        fail(
            "NAR shard asset set must contain from 1 to "
            f"{MAX_NAR_ASSETS_PER_SHARD} assets"
        )
    canonical_assets.sort(key=lambda item: item["sha256"])
    return sha256_bytes(canonical_json(canonical_assets))


def validate_published_shards(generation: Generation) -> None:
    """Prove that newly published objects use content-bound bounded shards."""

    published = generation.published_sha256
    object_map = generation.object_map
    if list(published) != sorted(set(published)):
        fail("manifest.published_nar_sha256 must be uniquely sorted")
    expected_published = sorted(
        asset.sha256
        for asset in generation.objects
        if parse_nar_shard_tag(asset.owner_release_tag)[:2]
        == (generation.qubes_commit, generation.guix_commit)
    )
    if list(published) != expected_published:
        fail(
            "published_nar_sha256 does not match objects in this generation's "
            "NAR shards"
        )
    published_assets: list[Asset] = []
    for digest in published:
        asset = object_map.get(digest)
        if asset is None:
            fail(f"published NAR is absent from nar_objects: {digest}")
        published_assets.append(asset)
    for offset in range(0, len(published_assets), MAX_NAR_ASSETS_PER_SHARD):
        shard_assets = published_assets[offset : offset + MAX_NAR_ASSETS_PER_SHARD]
        shard_number = offset // MAX_NAR_ASSETS_PER_SHARD + 1
        shard_digest = nar_shard_asset_set_digest(
            (asset.sha256, asset.size) for asset in shard_assets
        )
        expected_tag = nar_shard_tag_for_commits(
            generation.qubes_commit,
            generation.guix_commit,
            shard_number,
            shard_digest,
        )
        for asset in shard_assets:
            if (
                asset.owner_repository != generation.repository
                or asset.owner_release_tag != expected_tag
            ):
                fail(f"published NAR has a non-canonical shard owner: {asset.sha256}")


def asset_url(repository: str, release_tag: str, name: str) -> str:
    return f"https://github.com/{repository}/releases/download/{release_tag}/{name}"


def validate_nar_relative_url(value: bytes, context: str) -> str:
    try:
        text = value.decode("ascii")
    except UnicodeDecodeError:
        fail(f"{context} URL is not ASCII")
    if any(character in text for character in "\\?#%"):
        fail(f"{context} has an unsafe URL: {text!r}")
    path = PurePosixPath(text)
    if (
        path.is_absolute()
        or len(path.parts) < 2
        or path.parts[0] != "nar"
        or any(
            part in {"", ".", ".."} or not SAFE_NAR_SEGMENT_RE.fullmatch(part)
            for part in path.parts
        )
    ):
        fail(f"{context} has an unsafe relative NAR URL: {text!r}")
    return text


def narinfo_fields(
    content: bytes, path: str, *, allow_absolute_url: bool
) -> tuple[list[bytes], int | None, bytes]:
    """Validate a narinfo and return URL lines, FileSize, and URL value."""

    if not content or len(content) > MAX_NARINFO_SIZE or b"\0" in content:
        fail(f"invalid narinfo size or NUL byte: {path}")
    try:
        content.decode("utf-8")
    except UnicodeDecodeError:
        fail(f"narinfo is not valid UTF-8: {path}")

    lines = content.splitlines(keepends=True)
    if b"".join(lines) != content or any(
        b"\r" in line.removesuffix(b"\r\n") for line in lines
    ):
        fail(f"narinfo has invalid line endings: {path}")

    url_lines: list[tuple[int, bytes]] = []
    file_sizes: list[tuple[int, bytes]] = []
    compressions: list[tuple[int, bytes]] = []
    store_paths: list[tuple[int, bytes]] = []
    signatures: list[tuple[int, bytes]] = []
    for index, line in enumerate(lines):
        body = line
        if body.endswith(b"\n"):
            body = body[:-1]
        if body.endswith(b"\r"):
            body = body[:-1]
        if body.startswith(b"URL: "):
            url_lines.append((index, line))
        elif body.startswith(b"FileSize: "):
            file_sizes.append((index, body[len(b"FileSize: ") :]))
        elif body.startswith(b"Compression: "):
            compressions.append((index, body[len(b"Compression: ") :]))
        elif body.startswith(b"StorePath: "):
            store_paths.append((index, body[len(b"StorePath: ") :]))
        elif body.startswith(b"Signature: "):
            signatures.append((index, line))

    if len(url_lines) != 1:
        fail(f"narinfo must contain exactly one URL field: {path}")
    if len(file_sizes) > 1:
        fail(f"narinfo must contain at most one FileSize field: {path}")
    if len(compressions) != 1:
        fail(f"narinfo must contain exactly one Compression field: {path}")
    if len(store_paths) != 1:
        fail(f"narinfo must contain exactly one StorePath field: {path}")
    if len(signatures) != 1:
        fail(f"narinfo must contain exactly one Signature field: {path}")

    signature_index = signatures[0][0]
    if store_paths[0][0] >= signature_index:
        fail(f"narinfo StorePath is outside its normative signed fields: {path}")
    transport_indices = [url_lines[0][0], compressions[0][0]] + [
        index for index, _ in file_sizes
    ]
    if any(index <= signature_index for index in transport_indices):
        fail(f"narinfo transport fields must follow Signature: {path}")

    signature_body = signatures[0][1].rstrip(b"\r\n")[len(b"Signature: ") :]
    if not signature_body:
        fail(f"narinfo has an empty Signature field: {path}")
    compression = compressions[0][1]
    try:
        compression_text = compression.decode("ascii")
    except UnicodeDecodeError:
        fail(f"narinfo Compression is not ASCII: {path}")
    if not compression_text or not SAFE_NAR_SEGMENT_RE.fullmatch(compression_text):
        fail(f"narinfo has an invalid Compression field: {path}")

    file_size = None
    if file_sizes:
        file_size_raw = file_sizes[0][1]
        if not file_size_raw or not file_size_raw.isdigit():
            fail(f"narinfo has an invalid FileSize: {path}")
        if len(file_size_raw) > 1 and file_size_raw.startswith(b"0"):
            fail(f"narinfo FileSize is not canonical: {path}")
        file_size = int(file_size_raw)
        require_size(file_size, f"narinfo FileSize in {path}")

    expected_hash = path.removesuffix(".narinfo")
    store_path = store_paths[0][1]
    expected_prefix = f"/gnu/store/{expected_hash}-".encode("ascii")
    if not store_path.startswith(expected_prefix) or len(store_path) == len(
        expected_prefix
    ):
        fail(f"narinfo StorePath does not match its filename: {path}")

    url_line = url_lines[0][1]
    url_body = url_line.rstrip(b"\r\n")[len(b"URL: ") :]
    if allow_absolute_url:
        try:
            url_text = url_body.decode("ascii")
        except UnicodeDecodeError:
            fail(f"narinfo URL is not ASCII: {path}")
        if not url_text.startswith("https://github.com/"):
            fail(f"prior narinfo URL is not a GitHub Release URL: {path}")
    else:
        validate_nar_relative_url(url_body, f"narinfo {path}")
    return [line for _, line in url_lines], file_size, url_body


def rewrite_narinfo_url(content: bytes, path: str, new_url: str) -> bytes:
    """Replace only URL field bytes, preserving the signature verbatim."""

    url_lines, _, _ = narinfo_fields(content, path, allow_absolute_url=False)
    old_line = url_lines[0]
    ending = b""
    if old_line.endswith(b"\r\n"):
        ending = b"\r\n"
    elif old_line.endswith(b"\n"):
        ending = b"\n"
    replacement = b"URL: " + new_url.encode("ascii") + ending
    rewritten = content.replace(old_line, replacement, 1)

    # This assertion expresses the Guix signing invariant directly: URL is a
    # transport hint, and absolutely no other (normative) narinfo byte changes.
    if content.replace(old_line, b"", 1) != rewritten.replace(replacement, b"", 1):
        fail(f"rewriting URL changed normative narinfo bytes: {path}")
    old_signatures = [
        line
        for line in content.splitlines(keepends=True)
        if line.rstrip(b"\r\n").startswith(b"Signature: ")
    ]
    new_signatures = [
        line
        for line in rewritten.splitlines(keepends=True)
        if line.rstrip(b"\r\n").startswith(b"Signature: ")
    ]
    if old_signatures != new_signatures:
        fail(f"rewriting URL changed narinfo signatures: {path}")
    return rewritten


def narinfo_content_identity(content: bytes, path: str) -> NarinfoContentIdentity:
    """Return the stable signed fields that identify a narinfo's contents.

    ``guix publish`` also signs metadata such as ``Deriver``.  That metadata,
    the publisher signature, and transport fields may legitimately change for
    one store path across generations.  StorePath, NarHash, NarSize, and
    References are the stable content identity that retained generations must
    agree on.
    """

    narinfo_fields(content, path, allow_absolute_url=True)
    lines = content.splitlines(keepends=True)
    signature_index = next(
        (
            index
            for index, line in enumerate(lines)
            if line.rstrip(b"\r\n").startswith(b"Signature: ")
        ),
        None,
    )
    if signature_index is None:  # Defensive; narinfo_fields rejects this.
        fail(f"narinfo has no Signature field: {path}")

    values: dict[bytes, list[tuple[int, bytes]]] = {
        b"StorePath": [],
        b"NarHash": [],
        b"NarSize": [],
        b"References": [],
    }
    for index, line in enumerate(lines):
        body = line.rstrip(b"\r\n")
        for field_name in values:
            prefix = field_name + b": "
            if body.startswith(prefix):
                values[field_name].append((index, body[len(prefix) :]))

    identity: dict[bytes, bytes] = {}
    for field_name, occurrences in values.items():
        display_name = field_name.decode("ascii")
        if len(occurrences) != 1:
            fail(
                f"narinfo must contain exactly one {display_name} field: {path}"
            )
        index, value = occurrences[0]
        if index >= signature_index:
            fail(
                f"narinfo {display_name} is outside its normative signed fields: "
                f"{path}"
            )
        identity[field_name] = value

    return NarinfoContentIdentity(
        store_path=identity[b"StorePath"],
        nar_hash=identity[b"NarHash"],
        nar_size=identity[b"NarSize"],
        references=identity[b"References"],
    )


def validate_nix_cache_info(content: bytes, context: str) -> None:
    if not content or len(content) > MAX_NIX_CACHE_INFO_SIZE or b"\0" in content:
        fail(f"invalid nix-cache-info in {context}")
    try:
        text = content.decode("ascii")
    except UnicodeDecodeError:
        fail(f"nix-cache-info is not ASCII in {context}")
    store_dirs = [line for line in text.splitlines() if line.startswith("StoreDir: ")]
    if store_dirs != ["StoreDir: /gnu/store"]:
        fail(f"nix-cache-info must declare StoreDir: /gnu/store in {context}")


def ensure_regular_file(path: Path, context: str) -> None:
    try:
        mode = path.lstat().st_mode
    except OSError as error:
        fail(f"cannot inspect {context}: {error}")
    if not stat.S_ISREG(mode):
        fail(f"{context} is not a regular file")


def walk_regular_files(root: Path) -> set[str]:
    """Return relative POSIX paths, rejecting symlinks and special files."""

    relative_files: set[str] = set()
    for directory, directory_names, file_names in os.walk(root):
        directory_path = Path(directory)
        for name in directory_names:
            child = directory_path / name
            try:
                mode = child.lstat().st_mode
            except OSError as error:
                fail(f"cannot inspect cache directory {child}: {error}")
            if not stat.S_ISDIR(mode):
                fail(f"cache contains a non-directory or symlink: {child}")
        for name in file_names:
            child = directory_path / name
            ensure_regular_file(child, f"cache file {child}")
            relative_files.add(child.relative_to(root).as_posix())
    return relative_files


def load_local_cache(cache_dir: Path) -> tuple[bytes, tuple[LocalNarinfo, ...]]:
    try:
        cache_mode = cache_dir.lstat().st_mode
    except OSError as error:
        fail(f"cannot inspect cache directory {cache_dir}: {error}")
    if not stat.S_ISDIR(cache_mode):
        fail(f"cache path is not a real directory: {cache_dir}")

    try:
        root_entries = list(cache_dir.iterdir())
    except OSError as error:
        fail(f"cannot list cache directory {cache_dir}: {error}")
    root_directories: set[str] = set()
    for entry in root_entries:
        try:
            mode = entry.lstat().st_mode
        except OSError as error:
            fail(f"cannot inspect cache entry {entry}: {error}")
        if stat.S_ISDIR(mode):
            root_directories.add(entry.name)
    if root_directories != {"nar"}:
        fail(
            "cache root must contain exactly one directory named 'nar'; "
            f"found {sorted(root_directories)!r}"
        )

    files = walk_regular_files(cache_dir)
    allowed_root = {"nix-cache-info", ".qubes-template-guix-cache"}
    narinfo_paths = sorted(path for path in files if NARINFO_NAME_RE.fullmatch(path))
    unexpected = sorted(
        path
        for path in files
        if path not in allowed_root
        and path not in narinfo_paths
        and not path.startswith("nar/")
    )
    if unexpected:
        fail(f"cache contains unexpected files: {unexpected!r}")
    if "nix-cache-info" not in files:
        fail("cache has no nix-cache-info")
    if not narinfo_paths:
        fail("cache has no root narinfo files")

    try:
        nix_cache_info = (cache_dir / "nix-cache-info").read_bytes()
    except OSError as error:
        fail(f"cannot read nix-cache-info: {error}")
    validate_nix_cache_info(nix_cache_info, str(cache_dir))

    referenced_nars: set[str] = set()
    local_narinfos: list[LocalNarinfo] = []
    for path in narinfo_paths:
        narinfo_path = cache_dir / path
        try:
            content = narinfo_path.read_bytes()
        except OSError as error:
            fail(f"cannot read narinfo {path}: {error}")
        _, file_size, raw_url = narinfo_fields(content, path, allow_absolute_url=False)
        relative_url = validate_nar_relative_url(raw_url, f"narinfo {path}")
        if relative_url not in files:
            fail(f"narinfo {path} refers to missing NAR {relative_url!r}")
        nar_path = cache_dir.joinpath(*PurePosixPath(relative_url).parts)
        ensure_regular_file(nar_path, f"NAR for {path}")
        try:
            actual_size = nar_path.stat().st_size
        except OSError as error:
            fail(f"cannot stat NAR for {path}: {error}")
        if file_size is not None and actual_size != file_size:
            fail(
                f"NAR size mismatch for {path}: narinfo={file_size}, file={actual_size}"
            )
        referenced_nars.add(relative_url)
        local_narinfos.append(
            LocalNarinfo(
                path=path,
                content=content,
                nar_relative_url=relative_url,
                nar_path=nar_path,
                nar_size=actual_size,
            )
        )

    actual_nars = {path for path in files if path.startswith("nar/")}
    orphaned = sorted(actual_nars - referenced_nars)
    if orphaned:
        fail(f"cache contains unreferenced NAR files: {orphaned!r}")
    return nix_cache_info, tuple(local_narinfos)


def reject_duplicate_json_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            fail(f"JSON contains duplicate key: {key!r}")
        result[key] = value
    return result


def load_release_inventory(path: Path, repository: str) -> ReleaseInventory:
    """Load the compact, API-derived inventory of published Releases."""

    ensure_regular_file(path, f"release inventory {path}")
    try:
        with path.open("rb") as inventory_file:
            content = inventory_file.read(MAX_INVENTORY_SIZE + 1)
            if inventory_file.read(1):
                content += b"x"
    except OSError as error:
        fail(f"cannot read release inventory {path}: {error}")
    if len(content) > MAX_INVENTORY_SIZE:
        fail(f"release inventory exceeds {MAX_INVENTORY_SIZE} bytes: {path}")
    try:
        raw = json.loads(content, object_pairs_hook=reject_duplicate_json_keys)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"invalid release inventory JSON in {path}: {error}")

    document = require_exact_keys(raw, {"releases", "repository"}, "inventory")
    inventory_repository = validate_repository(
        document["repository"], "inventory.repository"
    )
    if inventory_repository != repository:
        fail(
            "release inventory belongs to a different repository: "
            f"{inventory_repository}"
        )
    raw_releases = document["releases"]
    if not isinstance(raw_releases, list):
        fail("inventory.releases must be an array")

    releases: dict[str, InventoryRelease] = {}
    for release_index, raw_release in enumerate(raw_releases):
        release_field = f"inventory.releases[{release_index}]"
        release = require_exact_keys(
            raw_release, {"assets", "published_at", "release_tag"}, release_field
        )
        tag = validate_github_tag(
            release["release_tag"], f"{release_field}.release_tag"
        )
        if tag in releases:
            fail(f"release inventory contains duplicate tag: {tag}")
        published_at = parse_timestamp(
            release["published_at"], f"{release_field}.published_at"
        )
        raw_assets = release["assets"]
        if not isinstance(raw_assets, list):
            fail(f"{release_field}.assets must be an array")
        assets: dict[str, InventoryAsset] = {}
        for asset_index, raw_asset in enumerate(raw_assets):
            asset_field = f"{release_field}.assets[{asset_index}]"
            inventory_asset = require_exact_keys(
                raw_asset, {"digest", "name", "size", "state"}, asset_field
            )
            name = require_string(inventory_asset["name"], f"{asset_field}.name")
            if (
                name in {".", ".."}
                or not SAFE_NAR_SEGMENT_RE.fullmatch(name)
                or len(name) > 255
            ):
                fail(f"{asset_field}.name is not a safe asset name")
            if name in assets:
                fail(f"release inventory contains duplicate asset {tag}/{name}")
            size = require_size(
                inventory_asset["size"], f"{asset_field}.size", allow_zero=True
            )
            state = require_string(inventory_asset["state"], f"{asset_field}.state")
            if state != "uploaded":
                fail(f"{asset_field}.state must be 'uploaded'")
            raw_digest = require_string(
                inventory_asset["digest"], f"{asset_field}.digest"
            )
            digest_match = GITHUB_SHA256_RE.fullmatch(raw_digest)
            if digest_match is None:
                fail(
                    f"{asset_field}.digest must use canonical "
                    "sha256:<lowercase-hex> form"
                )
            assets[name] = InventoryAsset(size, digest_match.group(1))
        if NAR_SHARD_TAG_RE.fullmatch(tag):
            shard_identity = parse_nar_shard_tag(tag, f"{release_field}.release_tag")
            if not 1 <= len(assets) <= MAX_NAR_ASSETS_PER_SHARD:
                fail(
                    f"NAR shard {tag} must contain from 1 to "
                    f"{MAX_NAR_ASSETS_PER_SHARD} assets"
                )
            for name, inventory_asset in assets.items():
                expected_name = asset_name(inventory_asset.sha256)
                if name != expected_name:
                    fail(
                        f"NAR shard {tag} asset name does not match its "
                        f"API digest: {name!r}"
                    )
            inventory_digest = nar_shard_asset_set_digest(
                (asset.sha256, asset.size) for asset in assets.values()
            )
            if inventory_digest != shard_identity[3]:
                fail(f"NAR shard {tag} asset-set digest does not match its tag")
        elif GC_MARKER_TAG_RE.fullmatch(tag):
            generation_tag_for_gc_marker(tag)
            if assets:
                fail(f"GC marker Release {tag} must not contain assets")
        releases[tag] = InventoryRelease(published_at, assets)
    return ReleaseInventory(inventory_repository, releases)


def validate_published_assets(
    generations: Iterable[Generation], inventory: ReleaseInventory
) -> None:
    """Verify generation and NAR assets against published API state."""

    checked: set[tuple[str, str]] = set()
    for generation in generations:
        release = inventory.releases.get(generation.release_tag)
        if release is None:
            fail(
                "release inventory is missing generation metadata: "
                f"{generation.release_tag}"
            )
        release_assets = release.assets
        if set(release_assets) != {MANIFEST_ASSET, METADATA_ASSET}:
            fail(
                f"generation Release {generation.release_tag} must contain "
                f"exactly {MANIFEST_ASSET} and {METADATA_ASSET}"
            )
        expected_generation_assets = {
            MANIFEST_ASSET: (generation.manifest_size, generation.manifest_sha256),
            METADATA_ASSET: (generation.metadata_size, generation.metadata_sha256),
        }
        for name, (
            expected_size,
            expected_digest,
        ) in expected_generation_assets.items():
            if expected_size is None or expected_digest is None:
                fail(
                    "cannot validate generation Release without loaded archive "
                    f"integrity data: {generation.release_tag}"
                )
            published_asset = release_assets[name]
            if (
                published_asset.size != expected_size
                or published_asset.sha256 != expected_digest
            ):
                fail(
                    "release inventory reports the wrong generation asset "
                    f"digest or size: {generation.release_tag}/{name}"
                )

        for asset in generation.objects:
            key = (asset.owner_release_tag, asset.name)
            if key in checked:
                continue
            checked.add(key)
            if asset.owner_repository != inventory.repository:
                fail(
                    "NAR asset owner belongs to a different repository: "
                    f"{asset.owner_repository}/{asset.owner_release_tag}"
                )
            release = inventory.releases.get(asset.owner_release_tag)
            if release is None:
                fail(
                    f"release inventory is missing NAR shard: {asset.owner_release_tag}"
                )
            release_assets = release.assets
            inventory_asset = release_assets.get(asset.name)
            if inventory_asset is None:
                fail(
                    "release inventory is missing NAR asset: "
                    f"{asset.owner_release_tag}/{asset.name}"
                )
            if (
                inventory_asset.size != asset.size
                or inventory_asset.sha256 != asset.sha256
            ):
                fail(
                    "release inventory reports the wrong NAR asset digest or size: "
                    f"{asset.owner_release_tag}/{asset.name} "
                    f"(metadata={asset.size}/{asset.sha256}, "
                    f"inventory={inventory_asset.size}/{inventory_asset.sha256})"
                )


def validate_inventory_generations(
    generations: Iterable[Generation],
    inventory: ReleaseInventory,
    *,
    absent_release_tag: str | None = None,
) -> None:
    """Require one downloaded ZIP for every managed generation Release."""

    generation_list = list(generations)
    loaded_tags = {generation.release_tag for generation in generation_list}
    inventory_tags = {
        tag for tag in inventory.releases if GENERATION_TAG_RE.fullmatch(tag)
    }
    if absent_release_tag is not None and absent_release_tag in inventory_tags:
        fail(f"current release tag already exists: {absent_release_tag}")
    if inventory_tags != loaded_tags:
        fail(
            "managed generation tags in the release inventory do not exactly "
            "match loaded version-2 metadata "
            f"(unloaded={sorted(inventory_tags - loaded_tags)!r}, "
            f"absent={sorted(loaded_tags - inventory_tags)!r})"
        )


def validate_archive_name(name: str, archive: Path) -> None:
    if not name or "\\" in name or "\0" in name:
        fail(f"metadata archive has an unsafe member name: {archive}")
    path = PurePosixPath(name)
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        fail(f"metadata archive has path traversal: {name!r} in {archive}")


def read_zip_member(
    archive: zipfile.ZipFile, info: zipfile.ZipInfo, limit: int, context: str
) -> bytes:
    try:
        with archive.open(info, "r") as member:
            content = member.read(limit + 1)
            if member.read(1):
                content += b"x"
    except (OSError, RuntimeError, zipfile.BadZipFile) as error:
        fail(f"cannot read {context}: {error}")
    if len(content) > limit:
        fail(f"{context} exceeds {limit} bytes")
    return content


def parse_asset(value: Any, index: int) -> Asset:
    field = f"manifest nar_objects[{index}]"
    item = require_exact_keys(
        value,
        {
            "asset_name",
            "asset_url",
            "owner_release_tag",
            "owner_repository",
            "sha256",
            "size",
        },
        field,
    )
    digest = require_sha256(item["sha256"], f"{field}.sha256")
    size = require_size(item["size"], f"{field}.size")
    name = require_string(item["asset_name"], f"{field}.asset_name")
    if name != asset_name(digest):
        fail(f"{field}.asset_name is not canonical for its SHA-256")
    repository = validate_repository(
        item["owner_repository"], f"{field}.owner_repository"
    )
    tag = require_string(item["owner_release_tag"], f"{field}.owner_release_tag")
    parse_nar_shard_tag(tag, f"{field}.owner_release_tag")
    url = require_string(item["asset_url"], f"{field}.asset_url")
    if url != asset_url(repository, tag, name):
        fail(f"{field}.asset_url is not the canonical GitHub Release URL")
    return Asset(digest, size, name, url, repository, tag)


def parse_manifest(
    manifest_content: bytes,
    members: dict[str, bytes],
    source: Path,
) -> Generation:
    try:
        decoded = manifest_content.decode("utf-8")
        raw = json.loads(decoded, object_pairs_hook=reject_duplicate_json_keys)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"invalid JSON manifest in {source}: {error}")
    if canonical_json(raw) != manifest_content:
        fail(f"manifest is not canonical JSON in {source}")

    manifest = require_exact_keys(
        raw,
        {
            "cache",
            "generated_at",
            "guix_commit",
            "nar_objects",
            "narinfos",
            "published_nar_sha256",
            "qubes_commit",
            "release_tag",
            "repository",
            "schema",
            "schema_version",
        },
        "manifest",
    )
    if (
        manifest["schema"] != SCHEMA
        or type(manifest["schema_version"]) is not int
        or manifest["schema_version"] != SCHEMA_VERSION
    ):
        fail(f"metadata archive claims an unsupported version-2 schema: {source}")
    repository = validate_repository(manifest["repository"])
    release_tag = validate_generation_tag(manifest["release_tag"])
    qubes_commit = require_commit(manifest["qubes_commit"], "manifest.qubes_commit")
    guix_commit = require_commit(manifest["guix_commit"], "manifest.guix_commit")
    validate_revision_tag(
        release_tag,
        qubes_commit,
        guix_commit,
        "manifest.release_tag",
    )
    generated_at_text = require_string(
        manifest["generated_at"], "manifest.generated_at"
    )
    generated_at = parse_timestamp(generated_at_text, "manifest.generated_at")

    cache = require_exact_keys(manifest["cache"], {"sha256", "size"}, "manifest.cache")
    cache_digest = require_sha256(cache["sha256"], "manifest.cache.sha256")
    cache_size = require_size(cache["size"], "manifest.cache.size", allow_zero=False)
    nix_cache_info = members.get(NIX_CACHE_MEMBER)
    if nix_cache_info is None:
        fail(f"metadata archive lacks {NIX_CACHE_MEMBER}: {source}")
    if (
        len(nix_cache_info) != cache_size
        or sha256_bytes(nix_cache_info) != cache_digest
    ):
        fail(f"nix-cache-info digest or size mismatch in {source}")
    validate_nix_cache_info(nix_cache_info, str(source))

    raw_objects = manifest["nar_objects"]
    if not isinstance(raw_objects, list):
        fail("manifest.nar_objects must be an array")
    objects = tuple(parse_asset(item, index) for index, item in enumerate(raw_objects))
    if [item.sha256 for item in objects] != sorted(
        item.sha256 for item in objects
    ) or len({item.sha256 for item in objects}) != len(objects):
        fail("manifest.nar_objects must be uniquely sorted by SHA-256")
    object_map = {item.sha256: item for item in objects}

    raw_published = manifest["published_nar_sha256"]
    if not isinstance(raw_published, list) or any(
        not isinstance(item, str) for item in raw_published
    ):
        fail("manifest.published_nar_sha256 must be an array of strings")
    published = tuple(raw_published)
    for digest in published:
        require_sha256(digest, "manifest.published_nar_sha256[]")

    raw_narinfos = manifest["narinfos"]
    if not isinstance(raw_narinfos, list):
        fail("manifest.narinfos must be an array")
    narinfos: list[Narinfo] = []
    expected_members = {MANIFEST_MEMBER, NIX_CACHE_MEMBER}
    previous_path = ""
    referenced_objects: set[str] = set()
    for index, raw_narinfo in enumerate(raw_narinfos):
        field = f"manifest.narinfos[{index}]"
        item = require_exact_keys(
            raw_narinfo,
            {"nar_sha256", "path", "sha256", "size"},
            field,
        )
        path = require_string(item["path"], f"{field}.path")
        if not NARINFO_NAME_RE.fullmatch(path) or path <= previous_path:
            fail("manifest.narinfos must have unique, sorted safe paths")
        previous_path = path
        digest = require_sha256(item["sha256"], f"{field}.sha256")
        size = require_size(item["size"], f"{field}.size")
        nar_digest = require_sha256(item["nar_sha256"], f"{field}.nar_sha256")
        asset = object_map.get(nar_digest)
        if asset is None:
            fail(f"narinfo refers to an absent NAR object: {path}")
        member_name = f"{ARCHIVE_ROOT}/narinfo/{path}"
        expected_members.add(member_name)
        content = members.get(member_name)
        if content is None:
            fail(f"metadata archive lacks narinfo member: {member_name}")
        if len(content) != size or sha256_bytes(content) != digest:
            fail(f"narinfo digest or size mismatch: {member_name}")
        _, file_size, url = narinfo_fields(content, path, allow_absolute_url=True)
        if (
            file_size is not None
            and file_size != asset.size
            or url.decode("ascii") != asset.url
        ):
            fail(f"narinfo does not match its NAR object: {member_name}")
        referenced_objects.add(nar_digest)
        narinfos.append(Narinfo(path, content, nar_digest))

    if set(object_map) != referenced_objects:
        fail("manifest contains unreferenced NAR objects")
    unexpected_members = sorted(set(members) - expected_members)
    if unexpected_members:
        fail(f"metadata archive has unexpected members: {unexpected_members!r}")
    generation = Generation(
        repository=repository,
        release_tag=release_tag,
        qubes_commit=qubes_commit,
        guix_commit=guix_commit,
        generated_at=generated_at,
        generated_at_text=generated_at_text,
        nix_cache_info=nix_cache_info,
        narinfos=tuple(narinfos),
        objects=objects,
        published_sha256=published,
    )
    validate_published_shards(generation)
    return generation


def load_prior_metadata(path: Path) -> Generation | None:
    """Load a version-2 metadata ZIP; return None for a pre-v2 archive."""

    ensure_regular_file(path, f"metadata ZIP {path}")
    try:
        archive_size = path.stat().st_size
    except OSError as error:
        fail(f"cannot stat metadata ZIP {path}: {error}")
    if archive_size > MAX_METADATA_ARCHIVE_SIZE:
        fail(f"metadata ZIP exceeds {MAX_METADATA_ARCHIVE_SIZE} bytes: {path}")
    metadata_digest, metadata_size = hash_file(path)
    try:
        archive = zipfile.ZipFile(path, "r")
    except (OSError, zipfile.BadZipFile) as error:
        fail(f"cannot open metadata ZIP {path}: {error}")
    with archive:
        try:
            infos = archive.infolist()
        except (OSError, zipfile.BadZipFile) as error:
            fail(f"cannot inspect metadata ZIP {path}: {error}")
        if len(infos) > MAX_ARCHIVE_MEMBERS:
            fail(f"metadata ZIP has too many members: {path}")

        # Version 2 starts a clean epoch.  Do not interpret, extract, retain,
        # or garbage-collect anything in an older archive.  Looking only for
        # this exact central-directory name is safe and avoids imposing the v2
        # member rules on unrelated historical formats.
        if not any(info.filename == MANIFEST_MEMBER for info in infos):
            return None

        names: set[str] = set()
        expanded_size = 0
        for info in infos:
            validate_archive_name(info.filename, path)
            if info.filename in names:
                fail(f"metadata ZIP has a duplicate member: {info.filename!r}")
            names.add(info.filename)
            if info.is_dir():
                fail(f"metadata ZIP contains a directory member: {info.filename!r}")
            if info.flag_bits & 0x1:
                fail(f"metadata ZIP contains an encrypted member: {info.filename!r}")
            unix_mode = info.external_attr >> 16
            file_type = stat.S_IFMT(unix_mode)
            if file_type and not stat.S_ISREG(unix_mode):
                fail(f"metadata ZIP contains a non-regular member: {info.filename!r}")
            expanded_size += info.file_size
            if expanded_size > MAX_ARCHIVE_EXPANDED_SIZE:
                fail(f"metadata ZIP expands beyond the safety limit: {path}")

        members: dict[str, bytes] = {}
        for info in infos:
            if info.filename == MANIFEST_MEMBER:
                limit = MAX_MANIFEST_SIZE
            elif info.filename == NIX_CACHE_MEMBER:
                limit = MAX_NIX_CACHE_INFO_SIZE
            else:
                limit = MAX_NARINFO_SIZE
            members[info.filename] = read_zip_member(
                archive, info, limit, f"{path}:{info.filename}"
            )
        generation = parse_manifest(members[MANIFEST_MEMBER], members, path)
        final_digest, final_size = hash_file(path)
        if (final_digest, final_size) != (metadata_digest, metadata_size):
            fail(f"metadata ZIP changed while it was being validated: {path}")
        manifest_content = members[MANIFEST_MEMBER]
        return replace(
            generation,
            metadata_sha256=metadata_digest,
            metadata_size=metadata_size,
            manifest_sha256=sha256_bytes(manifest_content),
            manifest_size=len(manifest_content),
        )


def validate_generation_graph(
    generations: Iterable[Generation],
    repository: str,
    generated_at: dt.datetime,
) -> dict[str, Asset]:
    generation_list = list(generations)
    by_release: dict[tuple[str, str], Generation] = {}
    global_objects: dict[str, Asset] = {}
    urls: dict[str, str] = {}
    for generation in generation_list:
        if generation.repository != repository:
            fail(
                "prior metadata belongs to a different repository: "
                f"{generation.repository}/{generation.release_tag}"
            )
        if generation.generated_at > generated_at:
            fail(
                f"prior generation is newer than the current generation: {generation.release_tag}"
            )
        if generation.release_id in by_release:
            fail(f"duplicate prior generation: {generation.release_tag}")
        by_release[generation.release_id] = generation
        for asset in generation.objects:
            if asset.owner_repository != repository:
                fail(
                    "NAR shard belongs to a different repository: "
                    f"{asset.owner_repository}/{asset.owner_release_tag}"
                )
            previous = global_objects.get(asset.sha256)
            if previous is not None and previous != asset:
                fail(f"conflicting ownership for NAR SHA-256 {asset.sha256}")
            previous_digest = urls.get(asset.url)
            if previous_digest is not None and previous_digest != asset.sha256:
                fail(
                    f"one Release asset URL names conflicting NAR objects: {asset.url}"
                )
            global_objects[asset.sha256] = asset
            urls[asset.url] = asset.sha256
    return global_objects


def load_prior_generations(paths: Iterable[Path]) -> list[Generation]:
    generations: list[Generation] = []
    for path in paths:
        generation = load_prior_metadata(path)
        if generation is not None:
            generations.append(generation)
    return generations


def validate_policy(
    retention_days: int,
    minimum_generations: int,
    gc_grace_days: int = DEFAULT_GC_GRACE_DAYS,
) -> None:
    if not 1 <= retention_days <= MAX_RETENTION_DAYS:
        fail(f"--retention-days must be from 1 to {MAX_RETENTION_DAYS}")
    if not 1 <= minimum_generations <= MAX_MINIMUM_GENERATIONS:
        fail(f"--minimum-generations must be from 1 to {MAX_MINIMUM_GENERATIONS}")
    if not 0 <= gc_grace_days <= MAX_GC_GRACE_DAYS:
        fail(f"--gc-grace-days must be from 0 to {MAX_GC_GRACE_DAYS}")


def asset_to_manifest(asset: Asset) -> dict[str, Any]:
    return {
        "asset_name": asset.name,
        "asset_url": asset.url,
        "owner_release_tag": asset.owner_release_tag,
        "owner_repository": asset.owner_repository,
        "sha256": asset.sha256,
        "size": asset.size,
    }


def create_manifest(generation: Generation) -> dict[str, Any]:
    return {
        "cache": {
            "sha256": sha256_bytes(generation.nix_cache_info),
            "size": len(generation.nix_cache_info),
        },
        "generated_at": generation.generated_at_text,
        "guix_commit": generation.guix_commit,
        "nar_objects": [
            asset_to_manifest(asset)
            for asset in sorted(generation.objects, key=lambda item: item.sha256)
        ],
        "narinfos": [
            {
                "nar_sha256": narinfo.nar_sha256,
                "path": narinfo.path,
                "sha256": sha256_bytes(narinfo.content),
                "size": len(narinfo.content),
            }
            for narinfo in sorted(generation.narinfos, key=lambda item: item.path)
        ],
        "published_nar_sha256": sorted(generation.published_sha256),
        "qubes_commit": generation.qubes_commit,
        "release_tag": generation.release_tag,
        "repository": generation.repository,
        "schema": SCHEMA,
        "schema_version": SCHEMA_VERSION,
    }


def write_deterministic_zip(
    path: Path, generation: Generation, manifest_content: bytes
) -> None:
    members = [
        (MANIFEST_MEMBER, manifest_content),
        (NIX_CACHE_MEMBER, generation.nix_cache_info),
    ]
    members.extend(
        (f"{ARCHIVE_ROOT}/narinfo/{item.path}", item.content)
        for item in generation.narinfos
    )
    try:
        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_STORED) as archive:
            for name, content in sorted(members):
                info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_STORED
                info.create_system = 3
                info.external_attr = (stat.S_IFREG | 0o644) << 16
                archive.writestr(info, content)
    except OSError as error:
        fail(f"cannot write metadata ZIP {path}: {error}")


def generation_reference(generation: Generation) -> dict[str, str]:
    return {
        "generated_at": generation.generated_at_text,
        "guix_commit": generation.guix_commit,
        "qubes_commit": generation.qubes_commit,
        "release_tag": generation.release_tag,
        "repository": generation.repository,
    }


def release_reference(repository: str, release_tag: str) -> dict[str, str]:
    return {"release_tag": release_tag, "repository": repository}


def select_retained_generations(
    generations: Iterable[Generation],
    as_of: dt.datetime,
    retention_days: int,
    minimum_generations: int,
) -> tuple[list[Generation], list[Generation]]:
    newest = sorted(
        generations,
        key=lambda item: (item.generated_at, item.release_tag),
        reverse=True,
    )
    try:
        cutoff = as_of - dt.timedelta(days=retention_days)
    except (OverflowError, ValueError):
        fail("retention policy underflows the generation timestamp")
    retained_ids = {
        item.release_id
        for index, item in enumerate(newest)
        if index < minimum_generations or item.generated_at >= cutoff
    }
    retained = [item for item in newest if item.release_id in retained_ids]
    expired = [item for item in newest if item.release_id not in retained_ids]
    return retained, expired


def classify_generation_retention(
    generations: Iterable[Generation],
    as_of: dt.datetime,
    retention_days: int,
    minimum_generations: int,
    gc_grace_days: int,
    inventory: ReleaseInventory,
) -> GenerationRetention:
    """Apply Pages retention and require a durable post-deploy GC marker."""

    newest = sorted(
        generations,
        key=lambda item: (item.generated_at, item.release_tag),
        reverse=True,
    )
    retained, expired = select_retained_generations(
        newest, as_of, retention_days, minimum_generations
    )
    indexes = {generation.release_id: index for index, generation in enumerate(newest)}
    protected: list[ExpiredGeneration] = []
    deletable: list[ExpiredGeneration] = []
    for generation in expired:
        index = indexes[generation.release_id]
        # An expired generation necessarily has at least N newer generations.
        # In newest-first order, index-N is the Nth one that arrived after it.
        count_protection_ended_at = newest[index - minimum_generations].generated_at
        try:
            age_protection_ended_at = generation.generated_at + dt.timedelta(
                days=retention_days
            )
            dropped_at = max(
                age_protection_ended_at,
                count_protection_ended_at,
            )
        except (OverflowError, ValueError):
            fail("retention policy overflows a generation timestamp")

        marker_tag = gc_marker_tag_for_commits(
            generation.qubes_commit, generation.guix_commit
        )
        marker_release = inventory.releases.get(marker_tag)
        marker_published_at = (
            marker_release.published_at if marker_release is not None else None
        )
        delete_after = None
        # A marker predating the current retention transition is stale (for
        # example after a policy change made the generation retained again).
        # It is cleanup-only and can never authorize destructive collection.
        if marker_published_at is not None and marker_published_at >= dropped_at:
            try:
                delete_after = marker_published_at + dt.timedelta(days=gc_grace_days)
            except (OverflowError, ValueError):
                fail("GC grace policy overflows a marker publication timestamp")
        state = ExpiredGeneration(
            generation,
            dropped_at,
            marker_tag,
            marker_published_at,
            delete_after,
        )
        (
            protected if delete_after is None or as_of < delete_after else deletable
        ).append(state)
    return GenerationRetention(
        retained=tuple(retained),
        gc_protected_expired=tuple(protected),
        deletable_expired=tuple(deletable),
    )


def format_timestamp(value: dt.datetime) -> str:
    return value.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def expired_generation_reference(state: ExpiredGeneration) -> dict[str, Any]:
    reference = generation_reference(state.generation)
    reference.update(
        {
            "delete_after": (
                format_timestamp(state.delete_after)
                if state.delete_after is not None
                else None
            ),
            "dropped_at": format_timestamp(state.dropped_at),
            "gc_marker_published_at": (
                format_timestamp(state.marker_published_at)
                if state.marker_published_at is not None
                else None
            ),
            "gc_marker_release_tag": state.marker_release_tag,
        }
    )
    return reference


def build_release_plan(
    current: Generation | None,
    as_of_text: str,
    retention: GenerationRetention,
    retention_days: int,
    minimum_generations: int,
    gc_grace_days: int,
    inventory: ReleaseInventory,
) -> dict[str, Any]:
    retained_shards = {
        asset.owner_release_tag
        for generation in retention.retained
        for asset in generation.objects
    }
    gc_protected_shards = {
        asset.owner_release_tag
        for state in retention.gc_protected_expired
        for asset in state.generation.objects
    }
    referenced_shards = retained_shards | gc_protected_shards
    known_shards = {
        tag for tag in inventory.releases if NAR_SHARD_TAG_RE.fullmatch(tag)
    }
    known_markers = {
        tag for tag in inventory.releases if GC_MARKER_TAG_RE.fullmatch(tag)
    }
    retained_generation_tags = {
        generation.release_tag for generation in retention.retained
    }
    expired_by_generation_tag = {
        state.generation.release_tag: state for state in retention.expired
    }
    loaded_generation_tags = retained_generation_tags | set(expired_by_generation_tag)
    create_gc_marker_releases = [
        release_reference(inventory.repository, state.marker_release_tag)
        for state in retention.gc_protected_expired
        if state.marker_published_at is None
    ]
    delete_marker_tags: set[str] = set()
    revoke_marker_tags: set[str] = set()
    for marker_tag in known_markers:
        generation_tag = generation_tag_for_gc_marker(marker_tag)
        if generation_tag not in loaded_generation_tags:
            revoke_marker_tags.add(marker_tag)
            continue
        if generation_tag in retained_generation_tags:
            revoke_marker_tags.add(marker_tag)
            continue
        state = expired_by_generation_tag[generation_tag]
        if state.delete_after is None:
            revoke_marker_tags.add(marker_tag)
        elif state in retention.deletable_expired:
            delete_marker_tags.add(marker_tag)
    delete_gc_marker_releases = [
        release_reference(inventory.repository, tag)
        for tag in sorted(delete_marker_tags)
    ]
    revoke_gc_marker_releases = [
        release_reference(inventory.repository, tag)
        for tag in sorted(revoke_marker_tags)
    ]
    delete_generation_releases = [
        release_reference(state.generation.repository, state.generation.release_tag)
        for state in retention.deletable_expired
    ]
    delete_nar_shard_releases = [
        release_reference(inventory.repository, tag)
        for tag in sorted(known_shards - referenced_shards)
    ]
    return {
        "as_of": as_of_text,
        "current_release": (
            generation_reference(current) if current is not None else None
        ),
        "create_gc_marker_releases": create_gc_marker_releases,
        "revoke_gc_marker_releases": revoke_gc_marker_releases,
        "delete_generation_releases": delete_generation_releases,
        "delete_nar_shard_releases": delete_nar_shard_releases,
        "delete_gc_marker_releases": delete_gc_marker_releases,
        "delete_releases": [
            *delete_generation_releases,
            *delete_nar_shard_releases,
            *delete_gc_marker_releases,
        ],
        "expired_releases": [
            generation_reference(state.generation) for state in retention.expired
        ],
        "gc_protected_expired_releases": [
            expired_generation_reference(state)
            for state in retention.gc_protected_expired
        ],
        "gc_protected_nar_shard_releases": [
            release_reference(inventory.repository, tag)
            for tag in sorted(gc_protected_shards - retained_shards)
        ],
        "policy": {
            "gc_grace_days": gc_grace_days,
            "minimum_generations": minimum_generations,
            "retention_days": retention_days,
        },
        "referenced_nar_shard_releases": [
            release_reference(inventory.repository, tag)
            for tag in sorted(referenced_shards)
        ],
        "retained_releases": [
            generation_reference(item) for item in retention.retained
        ],
        "schema": PLAN_SCHEMA,
        "schema_version": SCHEMA_VERSION,
    }


def create_output_staging(output_dir: Path) -> Path:
    output_parent = output_dir.parent
    output_parent.mkdir(parents=True, exist_ok=True)
    if output_dir.exists() or output_dir.is_symlink():
        fail(f"--output-dir already exists: {output_dir}")
    return Path(tempfile.mkdtemp(prefix=f".{output_dir.name}.tmp.", dir=output_parent))


def install_output(staging: Path, output_dir: Path) -> None:
    try:
        staging.rename(output_dir)
    except OSError as error:
        fail(f"cannot install completed output at {output_dir}: {error}")


def copy_verified(source: Path, destination: Path, expected: Asset) -> None:
    try:
        with source.open("rb") as input_file, destination.open("xb") as output_file:
            shutil.copyfileobj(input_file, output_file, length=1024 * 1024)
    except OSError as error:
        fail(f"cannot stage NAR asset {expected.name}: {error}")
    digest, size = hash_file(destination)
    if digest != expected.sha256 or size != expected.size:
        fail(f"NAR changed while staging Release asset: {source}")


def write_pages(pages_dir: Path, retained: Iterable[Generation]) -> None:
    generations = sorted(
        retained,
        key=lambda item: (item.generated_at, item.release_tag),
        reverse=True,
    )
    if not generations:
        fail("cannot write Pages without a retained generation")
    pages_dir.mkdir()
    # nix-cache-info describes the cache endpoint, not a historical generation.
    # Publish the newest validated form so harmless Guix metadata evolution does
    # not make older retained generations block a refresh.
    (pages_dir / "nix-cache-info").write_bytes(generations[0].nix_cache_info)

    # Keep the newest valid representation.  Deriver, publisher signature, and
    # transport fields may legitimately change while the stable content identity
    # remains equal.
    union: dict[str, Narinfo] = {}
    for generation in generations:
        for narinfo in generation.narinfos:
            previous = union.get(narinfo.path)
            if previous is None:
                union[narinfo.path] = narinfo
                continue
            if narinfo_content_identity(
                previous.content, previous.path
            ) != narinfo_content_identity(narinfo.content, narinfo.path):
                fail(
                    "retained generations have conflicting narinfo content "
                    f"identity fields: {narinfo.path}"
                )
    for path, narinfo in sorted(union.items()):
        (pages_dir / path).write_bytes(narinfo.content)


def prepare_release(
    *,
    cache_dir: Path,
    output_dir: Path,
    repository: str,
    release_tag: str,
    qubes_commit: str,
    guix_commit: str,
    generated_at_text: str,
    prior_metadata: Iterable[Path],
    release_inventory: Path,
    retention_days: int,
    minimum_generations: int,
    gc_grace_days: int = DEFAULT_GC_GRACE_DAYS,
) -> None:
    repository = validate_repository(repository)
    qubes_commit = require_commit(qubes_commit, "--qubes-commit")
    guix_commit = require_commit(guix_commit, "--guix-commit")
    release_tag = validate_generation_tag(release_tag)
    validate_revision_tag(release_tag, qubes_commit, guix_commit, "--release-tag")
    generated_at = parse_timestamp(generated_at_text, "--generated-at")
    validate_policy(retention_days, minimum_generations, gc_grace_days)
    inventory = load_release_inventory(release_inventory, repository)

    nix_cache_info, local_narinfos = load_local_cache(cache_dir)
    prior = load_prior_generations(prior_metadata)
    if any(item.release_tag == release_tag for item in prior):
        fail(f"current release tag already has immutable metadata: {release_tag}")
    validate_inventory_generations(
        prior,
        inventory,
        absent_release_tag=release_tag,
    )
    prior_objects = validate_generation_graph(prior, repository, generated_at)
    # Metadata alone is not proof that an immutable GitHub asset still exists.
    # Verify API-derived state before an object can be deduplicated or exposed.
    validate_published_assets(prior, inventory)

    # Hash each local NAR once even when several narinfos reference it.
    local_objects: dict[str, tuple[str, int, Path]] = {}
    for item in local_narinfos:
        previous = local_objects.get(item.nar_relative_url)
        if previous is None:
            digest, size = hash_file(item.nar_path)
            if size != item.nar_size:
                fail(f"NAR changed while hashing: {item.nar_path}")
            local_objects[item.nar_relative_url] = (digest, size, item.nar_path)

    local_by_digest: dict[str, tuple[int, Path]] = {}
    for digest, size, path in local_objects.values():
        previous = local_by_digest.setdefault(digest, (size, path))
        if previous[0] != size:
            fail(f"local NARs have conflicting sizes for SHA-256 {digest}")

    current_assets: dict[str, Asset] = {}
    published: set[str] = set()
    new_objects: list[tuple[str, int, Path]] = []
    for digest, (size, _) in sorted(local_by_digest.items()):
        prior_asset = prior_objects.get(digest)
        if prior_asset is not None:
            if prior_asset.size != size:
                fail(f"prior object has conflicting size for SHA-256 {digest}")
            current_assets[digest] = prior_asset
            continue
        new_objects.append((digest, size, local_by_digest[digest][1]))

    for offset in range(0, len(new_objects), MAX_NAR_ASSETS_PER_SHARD):
        shard_objects = new_objects[offset : offset + MAX_NAR_ASSETS_PER_SHARD]
        shard_number = offset // MAX_NAR_ASSETS_PER_SHARD + 1
        shard_digest = nar_shard_asset_set_digest(
            (digest, size) for digest, size, _ in shard_objects
        )
        shard_tag = nar_shard_tag_for_commits(
            qubes_commit,
            guix_commit,
            shard_number,
            shard_digest,
        )
        for digest, size, _ in shard_objects:
            name = asset_name(digest)
            current_assets[digest] = Asset(
                sha256=digest,
                size=size,
                name=name,
                url=asset_url(repository, shard_tag, name),
                owner_repository=repository,
                owner_release_tag=shard_tag,
            )
            published.add(digest)

    current_narinfos: list[Narinfo] = []
    for item in local_narinfos:
        digest = local_objects[item.nar_relative_url][0]
        asset = current_assets[digest]
        rewritten = rewrite_narinfo_url(item.content, item.path, asset.url)
        _, rewritten_size, rewritten_url = narinfo_fields(
            rewritten, item.path, allow_absolute_url=True
        )
        if (
            rewritten_size is not None
            and rewritten_size != asset.size
            or rewritten_url.decode("ascii") != asset.url
        ):
            fail(f"rewritten narinfo does not name its immutable asset: {item.path}")
        current_narinfos.append(Narinfo(item.path, rewritten, digest))

    current = Generation(
        repository=repository,
        release_tag=release_tag,
        qubes_commit=qubes_commit,
        guix_commit=guix_commit,
        generated_at=generated_at,
        generated_at_text=generated_at_text,
        nix_cache_info=nix_cache_info,
        narinfos=tuple(sorted(current_narinfos, key=lambda item: item.path)),
        objects=tuple(sorted(current_assets.values(), key=lambda item: item.sha256)),
        published_sha256=tuple(sorted(published)),
    )
    all_generations = [*prior, current]
    # Validate the complete ownership graph, including new objects, before any
    # externally consumable output is installed.
    validate_generation_graph(all_generations, repository, generated_at)
    retention = classify_generation_retention(
        all_generations,
        generated_at,
        retention_days,
        minimum_generations,
        gc_grace_days,
        inventory,
    )
    plan = build_release_plan(
        current,
        generated_at_text,
        retention,
        retention_days,
        minimum_generations,
        gc_grace_days,
        inventory,
    )

    staging = create_output_staging(output_dir)
    try:
        release_assets = staging / "release-assets"
        release_assets.mkdir()
        for digest in sorted(published):
            asset = current_assets[digest]
            shard_dir = release_assets / "nar-shards" / asset.owner_release_tag
            shard_dir.mkdir(parents=True, exist_ok=True)
            copy_verified(
                local_by_digest[digest][1],
                shard_dir / asset.name,
                asset,
            )

        manifest_content = canonical_json(create_manifest(current))
        (release_assets / MANIFEST_ASSET).write_bytes(manifest_content)
        metadata_path = release_assets / METADATA_ASSET
        write_deterministic_zip(
            metadata_path,
            current,
            manifest_content,
        )
        reloaded = load_prior_metadata(metadata_path)
        if reloaded is None or reloaded != current:
            fail("newly written metadata ZIP does not reproduce its generation")
        write_pages(staging / "pages", retention.retained)
        (staging / "release-plan.json").write_bytes(canonical_json(plan))
        install_output(staging, output_dir)
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def recover_release_state(
    *,
    output_dir: Path,
    repository: str,
    as_of_text: str,
    prior_metadata: Iterable[Path],
    release_inventory: Path,
    retention_days: int,
    minimum_generations: int,
    gc_grace_days: int = DEFAULT_GC_GRACE_DAYS,
) -> None:
    """Regenerate Pages and cleanup state without preparing a new Release."""

    repository = validate_repository(repository)
    as_of = parse_timestamp(as_of_text, "--as-of")
    validate_policy(retention_days, minimum_generations, gc_grace_days)
    inventory = load_release_inventory(release_inventory, repository)
    generations = load_prior_generations(prior_metadata)
    if not generations:
        fail("recovery requires at least one version-2 metadata ZIP")
    validate_inventory_generations(generations, inventory)
    validate_generation_graph(generations, repository, as_of)
    validate_published_assets(generations, inventory)
    retention = classify_generation_retention(
        generations,
        as_of,
        retention_days,
        minimum_generations,
        gc_grace_days,
        inventory,
    )
    plan = build_release_plan(
        None,
        as_of_text,
        retention,
        retention_days,
        minimum_generations,
        gc_grace_days,
        inventory,
    )

    staging = create_output_staging(output_dir)
    try:
        write_pages(staging / "pages", retention.retained)
        (staging / "release-plan.json").write_bytes(canonical_json(plan))
        install_output(staging, output_dir)
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def parse_arguments(arguments: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "prepare or recover version-2 GitHub Release-backed Guix "
            "substitute-cache state"
        )
    )
    commands = parser.add_subparsers(dest="command", required=True)
    prepare = commands.add_parser(
        "prepare",
        help="prepare one new immutable Release and the retained Pages index",
    )
    recover = commands.add_parser(
        "recover",
        help="regenerate Pages and cleanup state from existing metadata only",
    )

    for command in (prepare, recover):
        command.add_argument(
            "--output-dir",
            type=Path,
            required=True,
            help="new directory in which to write generated output",
        )
        command.add_argument(
            "--repository",
            required=True,
            metavar="OWNER/REPOSITORY",
            help="GitHub repository that owns every version-2 Release",
        )
        command.add_argument(
            "--prior-metadata",
            type=Path,
            action="append",
            default=[],
            metavar="ZIP",
            help=(
                "prior immutable generation metadata ZIP; repeat for every "
                "version-2 Release (pre-v2 ZIPs are ignored)"
            ),
        )
        command.add_argument(
            "--release-inventory",
            type=Path,
            required=True,
            metavar="JSON",
            help=(
                "compact inventory of published GitHub Release tags, asset "
                "names, sizes, SHA-256 digests, upload states, and Release "
                "publication times"
            ),
        )
        command.add_argument(
            "--retention-days",
            type=int,
            default=DEFAULT_RETENTION_DAYS,
            help=(
                f"retain generations this many days (default: {DEFAULT_RETENTION_DAYS})"
            ),
        )
        command.add_argument(
            "--minimum-generations",
            type=int,
            default=DEFAULT_MINIMUM_GENERATIONS,
            help=(
                "retain at least this many newest generations "
                f"(default: {DEFAULT_MINIMUM_GENERATIONS})"
            ),
        )
        command.add_argument(
            "--gc-grace-days",
            type=int,
            default=DEFAULT_GC_GRACE_DAYS,
            help=(
                "delay deletion after its post-deployment GC marker is published "
                f"(default: {DEFAULT_GC_GRACE_DAYS})"
            ),
        )

    prepare.add_argument(
        "--cache-dir",
        type=Path,
        required=True,
        help="fresh output directory from build-substitute-cache.sh",
    )
    prepare.add_argument(
        "--release-tag",
        required=True,
        help=(
            "new immutable tag, exactly substitute-cache-v2-"
            "<qubes-commit>-<guix-commit>"
        ),
    )
    prepare.add_argument(
        "--generated-at",
        required=True,
        metavar="YYYY-MM-DDTHH:MM:SSZ",
        help="generation and retention time in canonical UTC form",
    )
    prepare.add_argument(
        "--qubes-commit",
        required=True,
        metavar="COMMIT",
        help="exact full commit of the Qubes channel source (40 lowercase hex)",
    )
    prepare.add_argument(
        "--guix-commit",
        required=True,
        metavar="COMMIT",
        help="exact full commit of the resolved Guix channel (40 lowercase hex)",
    )
    recover.add_argument(
        "--as-of",
        required=True,
        metavar="YYYY-MM-DDTHH:MM:SSZ",
        help="explicit UTC time at which to apply the retention policy",
    )
    return parser.parse_args(arguments)


def main(arguments: list[str] | None = None) -> int:
    options = parse_arguments(sys.argv[1:] if arguments is None else arguments)
    try:
        if options.command == "prepare":
            prepare_release(
                cache_dir=options.cache_dir,
                output_dir=options.output_dir,
                repository=options.repository,
                release_tag=options.release_tag,
                qubes_commit=options.qubes_commit,
                guix_commit=options.guix_commit,
                generated_at_text=options.generated_at,
                prior_metadata=options.prior_metadata,
                release_inventory=options.release_inventory,
                retention_days=options.retention_days,
                minimum_generations=options.minimum_generations,
                gc_grace_days=options.gc_grace_days,
            )
        else:
            recover_release_state(
                output_dir=options.output_dir,
                repository=options.repository,
                as_of_text=options.as_of,
                prior_metadata=options.prior_metadata,
                release_inventory=options.release_inventory,
                retention_days=options.retention_days,
                minimum_generations=options.minimum_generations,
                gc_grace_days=options.gc_grace_days,
            )
    except (OSError, StateError) as error:
        print(f"prepare-substitute-release: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
