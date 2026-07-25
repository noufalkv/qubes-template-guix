#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Create and validate the realized-path handoff for cache publication."""

import argparse
import hashlib
import hmac
import json
import os
import re
import stat
import sys
import tempfile

COMMIT_RE = re.compile(r"[0-9a-f]{40}(?:[0-9a-f]{24})?\Z")
DIGEST_RE = re.compile(r"[0-9a-f]{64}\Z")
CHANNEL_NAME_RE = re.compile(r"[A-Za-z0-9+._-]+\Z")
STORE_NAME_RE = re.compile(r"[0-9abcdfghijklmnpqrsvwxyz]{32}-[A-Za-z0-9+._?=-]+\Z")
VARIANT_SYSTEMS = {
    "normal": {"normal"},
    "minimal": {"minimal"},
    "both": {"normal", "minimal"},
}
UPSTREAM = "https://ci.guix.gnu.org"
MAX_MANIFEST_SIZE = 64 * 1024 * 1024


class ManifestError(Exception):
    """A manifest failed a structural, provenance, or path invariant."""


def reject_json_constant(value):
    raise ManifestError(f"invalid JSON constant: {value}")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ManifestError(f"duplicate JSON member: {key}")
        result[key] = value
    return result


def decode_json(payload, description):
    try:
        return json.loads(
            payload.decode("utf-8"),
            object_pairs_hook=unique_object,
            parse_constant=reject_json_constant,
        )
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ManifestError(f"malformed {description}: {error}") from error


def read_json_file(path, description):
    try:
        with open(path, "rb") as source:
            return decode_json(source.read(), description)
    except OSError as error:
        raise ManifestError(f"cannot read {description}: {error}") from error


def require_exact_members(value, members, description):
    if not isinstance(value, dict) or set(value) != set(members):
        raise ManifestError(f"unexpected {description} schema")


def validate_commit(value, description):
    if not isinstance(value, str) or not COMMIT_RE.fullmatch(value):
        raise ManifestError(f"{description} is malformed")
    return value


def normalize_channels(raw_channels, source_commit, *, allow_extra_members):
    if not isinstance(raw_channels, list) or not raw_channels:
        raise ManifestError("channel provenance is empty")

    channels = []
    seen_names = set()
    for raw_channel in raw_channels:
        if not isinstance(raw_channel, dict):
            raise ManifestError("channel record is not an object")
        if not allow_extra_members and set(raw_channel) != {"commit", "name"}:
            raise ManifestError("channel record has an unexpected schema")
        name = raw_channel.get("name")
        commit = raw_channel.get("commit")
        if not isinstance(name, str) or not CHANNEL_NAME_RE.fullmatch(name):
            raise ManifestError("channel name is malformed")
        validate_commit(commit, f"commit for channel {name}")
        if name in seen_names:
            raise ManifestError(f"channel {name} is duplicated")
        seen_names.add(name)
        channels.append({"commit": commit, "name": name})

    channels.sort(key=lambda channel: channel["name"])
    qubes_commits = [
        channel["commit"] for channel in channels if channel["name"] == "qubes"
    ]
    if qubes_commits != [source_commit] or "guix" not in seen_names:
        raise ManifestError(
            "channel provenance is not bound to Guix and the source commit"
        )
    return channels


def validate_store_directory(path):
    if (
        not isinstance(path, str)
        or not os.path.isabs(path)
        or os.path.normpath(path) != path
        or os.path.realpath(path) != path
        or not os.path.isdir(path)
    ):
        raise ManifestError("store directory is not a concrete directory")
    return path


def validate_store_path(path, description, store_directory):
    if not isinstance(path, str):
        raise ManifestError(f"{description} is not a string")
    if (
        not os.path.isabs(path)
        or os.path.normpath(path) != path
        or os.path.dirname(path) != store_directory
        or not STORE_NAME_RE.fullmatch(os.path.basename(path))
    ):
        raise ManifestError(f"{description} is not a confined Guix store path")
    if not os.path.lexists(path):
        raise ManifestError(f"{description} no longer exists: {path}")
    return path


def validate_document(document, expected_schema):
    require_exact_members(
        document,
        {"provenance", "realization", "schema", "store_paths"},
        "top-level",
    )
    if document["schema"] != expected_schema:
        raise ManifestError("unsupported schema version")

    provenance = document["provenance"]
    realization = document["realization"]
    store_paths = document["store_paths"]
    require_exact_members(
        provenance,
        {
            "channels",
            "public_key_sha256",
            "source_commit",
            "upstream_substitute_server",
            "variant",
        },
        "provenance",
    )
    require_exact_members(
        realization,
        {"guix", "pull_profile", "store_directory", "systems"},
        "realization",
    )

    source_commit = validate_commit(provenance["source_commit"], "source commit")
    public_key_sha256 = provenance["public_key_sha256"]
    if not isinstance(public_key_sha256, str) or not DIGEST_RE.fullmatch(
        public_key_sha256
    ):
        raise ManifestError("public-key SHA-256 is malformed")
    variant = provenance["variant"]
    if variant not in VARIANT_SYSTEMS:
        raise ManifestError("variant is malformed")
    if provenance["upstream_substitute_server"] != UPSTREAM:
        raise ManifestError("upstream substitute server changed")
    channels = normalize_channels(
        provenance["channels"], source_commit, allow_extra_members=False
    )
    if provenance["channels"] != channels:
        raise ManifestError("channels are not in canonical order")

    store_directory = validate_store_directory(realization["store_directory"])
    pull_profile = validate_store_path(
        realization["pull_profile"], "pull profile", store_directory
    )
    if not os.path.isdir(pull_profile):
        raise ManifestError("pull profile is not a directory")
    guix = realization["guix"]
    if guix != os.path.join(pull_profile, "bin", "guix"):
        raise ManifestError("Guix executable is outside the pull profile")
    if not os.path.isfile(guix) or not os.access(guix, os.X_OK):
        raise ManifestError("Guix executable is missing or not executable")

    systems = realization["systems"]
    if not isinstance(systems, dict) or set(systems) != VARIANT_SYSTEMS[variant]:
        raise ManifestError("system roots do not match the variant")
    for name, path in systems.items():
        validate_store_path(path, f"{name} system root", store_directory)

    if not isinstance(store_paths, list) or not store_paths:
        raise ManifestError("published store paths are empty")
    for path in store_paths:
        validate_store_path(path, "published store path", store_directory)
    if store_paths != sorted(store_paths) or len(store_paths) != len(set(store_paths)):
        raise ManifestError("published store paths are not sorted and unique")
    if not set(systems.values()).issubset(store_paths):
        raise ManifestError("published store paths omit a system root")

    return {
        "guix": guix,
        "paths": store_paths,
        "public_key_sha256": public_key_sha256,
        "pull_profile": pull_profile,
        "source_commit": source_commit,
        "variant": variant,
    }


def read_records(path, description):
    records = []
    try:
        with open(path, encoding="utf-8", newline="") as source:
            for line in source:
                if not line.endswith("\n"):
                    raise ManifestError(f"{description} has an unterminated record")
                records.append(line[:-1])
    except (OSError, UnicodeError) as error:
        raise ManifestError(f"cannot read {description}: {error}") from error
    return records


def read_systems(path):
    systems = {}
    for record in read_records(path, "system roots"):
        if record.count("\t") != 1:
            raise ManifestError("invalid system-root record")
        name, store_path = record.split("\t")
        if name in systems:
            raise ManifestError(f"duplicate system root: {name}")
        systems[name] = store_path
    return systems


def publish_no_clobber(output_path, payload):
    output_parent = os.path.dirname(output_path)
    temporary_fd = None
    temporary_path = None
    try:
        temporary_fd, temporary_path = tempfile.mkstemp(
            dir=output_parent,
            prefix=f".{os.path.basename(output_path)}.tmp.",
        )
        os.fchmod(temporary_fd, 0o400)
        with os.fdopen(temporary_fd, "wb", closefd=True) as output:
            temporary_fd = None
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
        os.link(temporary_path, output_path, follow_symlinks=False)
        os.unlink(temporary_path)
        temporary_path = None
        directory_fd = os.open(output_parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except FileExistsError as error:
        raise ManifestError(f"refusing to replace manifest: {output_path}") from error
    except OSError as error:
        raise ManifestError(f"cannot publish manifest: {error}") from error
    finally:
        if temporary_fd is not None:
            os.close(temporary_fd)
        if temporary_path is not None:
            try:
                os.unlink(temporary_path)
            except FileNotFoundError:
                pass


def create_manifest(arguments):
    source_commit = validate_commit(arguments.source_commit, "source commit")
    if not DIGEST_RE.fullmatch(arguments.public_key_sha256):
        raise ManifestError("public-key SHA-256 is malformed")
    if arguments.variant not in VARIANT_SYSTEMS:
        raise ManifestError("variant is malformed")

    raw_channels = read_json_file(arguments.channels, "pulled channel description")
    channels = normalize_channels(raw_channels, source_commit, allow_extra_members=True)
    systems = read_systems(arguments.systems)
    store_paths = sorted(read_records(arguments.paths, "published store paths"))
    store_directory = os.path.dirname(arguments.pull_profile)
    document = {
        "provenance": {
            "channels": channels,
            "public_key_sha256": arguments.public_key_sha256,
            "source_commit": source_commit,
            "upstream_substitute_server": UPSTREAM,
            "variant": arguments.variant,
        },
        "realization": {
            "guix": arguments.guix,
            "pull_profile": arguments.pull_profile,
            "store_directory": store_directory,
            "systems": systems,
        },
        "schema": arguments.schema,
        "store_paths": store_paths,
    }
    validate_document(document, arguments.schema)
    payload = (json.dumps(document, indent=2, sort_keys=True) + "\n").encode()
    publish_no_clobber(arguments.output, payload)


def read_manifest_once(path, expected_digest):
    if not DIGEST_RE.fullmatch(expected_digest):
        raise ManifestError("expected SHA-256 is malformed")
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError as error:
        raise ManifestError(f"cannot open without following links: {error}") from error
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise ManifestError("not a regular file")
        if metadata.st_uid != os.geteuid():
            raise ManifestError("not owned by the exporting user")
        if metadata.st_nlink != 1:
            raise ManifestError("must have exactly one hard link")
        if stat.S_IMODE(metadata.st_mode) & 0o022:
            raise ManifestError("is group- or world-writable")
        if metadata.st_size < 2 or metadata.st_size > MAX_MANIFEST_SIZE:
            raise ManifestError("size is outside the accepted range")
        payload = bytearray()
        remaining = metadata.st_size
        while remaining:
            chunk = os.read(descriptor, min(remaining, 1024 * 1024))
            if not chunk:
                raise ManifestError("changed size while being read")
            payload.extend(chunk)
            remaining -= len(chunk)
        if os.read(descriptor, 1):
            raise ManifestError("changed size while being read")
    finally:
        os.close(descriptor)

    payload = bytes(payload)
    actual_digest = hashlib.sha256(payload).hexdigest()
    if not hmac.compare_digest(actual_digest, expected_digest):
        raise ManifestError("SHA-256 does not match the prepare-step output")
    return payload


def write_validated_paths(path, store_paths):
    try:
        descriptor = os.open(
            path,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
        )
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as output:
            for store_path in store_paths:
                output.write(store_path + "\n")
            output.flush()
            os.fsync(output.fileno())
    except OSError as error:
        raise ManifestError(f"cannot materialize validated paths: {error}") from error


def validate_manifest(arguments):
    payload = read_manifest_once(arguments.manifest, arguments.sha256)
    document = decode_json(payload, "manifest JSON")
    fields = validate_document(document, arguments.schema)
    write_validated_paths(arguments.paths_output, fields["paths"])
    metadata = (
        fields["source_commit"],
        fields["variant"],
        fields["public_key_sha256"],
        fields["guix"],
        fields["pull_profile"],
    )
    sys.stdout.buffer.write(
        b"\0".join(field.encode("utf-8") for field in metadata) + b"\0"
    )


def parse_arguments():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    create = subparsers.add_parser("create")
    create.add_argument("--channels", required=True)
    create.add_argument("--paths", required=True)
    create.add_argument("--systems", required=True)
    create.add_argument("--output", required=True)
    create.add_argument("--schema", required=True)
    create.add_argument("--source-commit", required=True)
    create.add_argument("--variant", required=True)
    create.add_argument("--public-key-sha256", required=True)
    create.add_argument("--pull-profile", required=True)
    create.add_argument("--guix", required=True)
    create.set_defaults(handler=create_manifest)

    validate = subparsers.add_parser("validate")
    validate.add_argument("--manifest", required=True)
    validate.add_argument("--sha256", required=True)
    validate.add_argument("--schema", required=True)
    validate.add_argument("--paths-output", required=True)
    validate.set_defaults(handler=validate_manifest)
    return parser.parse_args()


def main():
    arguments = parse_arguments()
    try:
        arguments.handler(arguments)
    except ManifestError as error:
        prefix = (
            "invalid substitute manifest"
            if arguments.command == "validate"
            else "cannot create substitute manifest"
        )
        print(f"{prefix}: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
