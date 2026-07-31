#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Tests for immutable substitute-cache Release state preparation."""

import copy
import hashlib
import importlib.util
import json
import pathlib
import shutil
import sys
import tempfile
import unittest
import zipfile
from unittest import mock

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
HELPER_PATH = REPO_ROOT / "scripts" / "prepare-substitute-release.py"
SPEC = importlib.util.spec_from_file_location("prepare_substitute_release", HELPER_PATH)
assert SPEC is not None and SPEC.loader is not None
HELPER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = HELPER
SPEC.loader.exec_module(HELPER)

REPOSITORY = "example/qubes-template-guix"
NIX_CACHE_INFO = b"StoreDir: /gnu/store\nWantMassQuery: 0\nPriority: 100\n"
HASH_ALPHABET = "0123456789abcdfghijklmnpqrsvwxyz"


def store_hash(index):
    characters = []
    for _ in range(32):
        characters.append(HASH_ALPHABET[index % len(HASH_ALPHABET)])
        index //= len(HASH_ALPHABET)
    return "".join(characters)


class SubstituteReleaseStateTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory(
            prefix="work.substitute-state.", dir=REPO_ROOT
        )
        self.work_dir = pathlib.Path(self.temporary_directory.name)
        self.inventory_releases = {}
        self.inventory_published_at = {}
        self.inventory_index = 0
        self.generation_shards = {}

    def tearDown(self):
        self.temporary_directory.cleanup()

    def write_inventory(self):
        self.inventory_index += 1
        path = self.work_dir / f"release-inventory-{self.inventory_index}.json"
        document = {
            "repository": REPOSITORY,
            "releases": [
                {
                    "assets": [
                        {"name": name, **asset}
                        for name, asset in sorted(assets.items())
                    ],
                    "published_at": self.inventory_published_at.get(
                        tag, "2026-07-25T10:00:00Z"
                    ),
                    "release_tag": tag,
                }
                for tag, assets in sorted(self.inventory_releases.items())
            ],
        }
        path.write_text(json.dumps(document), encoding="utf-8")
        return path

    def register_output(self, output):
        release_assets = output / "release-assets"
        manifest = json.loads((release_assets / HELPER.MANIFEST_ASSET).read_text())
        generation_assets = {
            name: self.inventory_asset(release_assets / name)
            for name in (HELPER.MANIFEST_ASSET, HELPER.METADATA_ASSET)
        }
        self.inventory_releases[manifest["release_tag"]] = generation_assets
        self.inventory_published_at[manifest["release_tag"]] = manifest["generated_at"]
        shard_root = release_assets / "nar-shards"
        shard_tags = []
        if shard_root.is_dir():
            for shard_dir in shard_root.iterdir():
                shard_tags.append(shard_dir.name)
                self.inventory_releases[shard_dir.name] = {
                    asset.name: self.inventory_asset(asset)
                    for asset in shard_dir.iterdir()
                }
                self.inventory_published_at[shard_dir.name] = manifest["generated_at"]
        self.generation_shards[manifest["release_tag"]] = tuple(sorted(shard_tags))

    def register_gc_marker(self, name, published_at):
        tag = self.gc_marker_tag(name)
        self.inventory_releases[tag] = {}
        self.inventory_published_at[tag] = published_at
        return tag

    @staticmethod
    def inventory_asset(path):
        content = path.read_bytes()
        return {
            "digest": f"sha256:{hashlib.sha256(content).hexdigest()}",
            "size": len(content),
            "state": "uploaded",
        }

    def make_cache(
        self,
        name,
        *,
        index=0,
        payload=b"compressed nar",
        relative_url="nar/zstd/cache-object.nar.zst",
        file_size=None,
        signature=b"Signature: cache.example:unchanged-signature\n",
        nar_hash=b"sha256:fixture",
        deriver=b"unknown-deriver",
        nix_cache_info=NIX_CACHE_INFO,
    ):
        cache = self.work_dir / name
        nar_path = cache.joinpath(*relative_url.split("/"))
        nar_path.parent.mkdir(parents=True)
        nar_path.write_bytes(payload)
        hash_text = store_hash(index)
        narinfo = (
            f"StorePath: /gnu/store/{hash_text}-fixture\n".encode()
            + b"NarHash: "
            + nar_hash
            + b"\n"
            + b"NarSize: 1234\n"
            + b"References: \n"
            + b"Deriver: "
            + deriver
            + b"\n"
            + signature
            + f"URL: {relative_url}\n".encode()
            + b"Compression: zstd\n"
        )
        if file_size is not None:
            narinfo += f"FileSize: {file_size}\n".encode()
        (cache / "nix-cache-info").write_bytes(nix_cache_info)
        (cache / f"{hash_text}.narinfo").write_bytes(narinfo)
        (cache / ".qubes-template-guix-cache").write_text(
            "qubes-template-guix static cache v1\n", encoding="ascii"
        )
        return cache, narinfo, f"{hash_text}.narinfo"

    def make_many_cache(self, name, count):
        cache = self.work_dir / name
        nar_dir = cache / "nar" / "zstd"
        nar_dir.mkdir(parents=True)
        (cache / "nix-cache-info").write_bytes(NIX_CACHE_INFO)
        (cache / ".qubes-template-guix-cache").write_text(
            "qubes-template-guix static cache v1\n", encoding="ascii"
        )
        for index in range(count):
            payload = f"compressed-nar-{index}".encode()
            relative_url = f"nar/zstd/object-{index}.nar.zst"
            (cache / relative_url).write_bytes(payload)
            hash_text = store_hash(index)
            narinfo = (
                f"StorePath: /gnu/store/{hash_text}-fixture-{index}\n".encode()
                + f"NarHash: sha256:nar-{index}\n".encode()
                + b"NarSize: 1234\n"
                + b"References: \n"
                + b"Deriver: unknown-deriver\n"
                + b"Signature: cache.example:signature\n"
                + f"URL: {relative_url}\n".encode()
                + b"Compression: zstd\n"
                + f"FileSize: {len(payload)}\n".encode()
            )
            (cache / f"{hash_text}.narinfo").write_bytes(narinfo)
        return cache

    def prepare(
        self,
        cache,
        name,
        generated_at,
        *,
        prior=(),
        minimum_generations=8,
        retention_days=180,
        gc_grace_days=HELPER.DEFAULT_GC_GRACE_DAYS,
    ):
        output = self.work_dir / f"output-{name}"
        qubes_commit = hashlib.sha1(f"qubes:{name}".encode()).hexdigest()
        guix_commit = hashlib.sha1(f"guix:{name}".encode()).hexdigest()
        HELPER.prepare_release(
            cache_dir=cache,
            output_dir=output,
            repository=REPOSITORY,
            release_tag=HELPER.release_tag_for_commits(qubes_commit, guix_commit),
            qubes_commit=qubes_commit,
            guix_commit=guix_commit,
            generated_at_text=generated_at,
            prior_metadata=prior,
            release_inventory=self.write_inventory(),
            retention_days=retention_days,
            minimum_generations=minimum_generations,
            gc_grace_days=gc_grace_days,
        )
        self.register_output(output)
        return output

    @staticmethod
    def release_tag(name):
        qubes_commit = hashlib.sha1(f"qubes:{name}".encode()).hexdigest()
        guix_commit = hashlib.sha1(f"guix:{name}".encode()).hexdigest()
        return HELPER.release_tag_for_commits(qubes_commit, guix_commit)

    def shard_tag(self, name, number=1):
        return self.generation_shards[self.release_tag(name)][number - 1]

    @staticmethod
    def gc_marker_tag(name):
        qubes_commit = hashlib.sha1(f"qubes:{name}".encode()).hexdigest()
        guix_commit = hashlib.sha1(f"guix:{name}".encode()).hexdigest()
        return HELPER.gc_marker_tag_for_commits(qubes_commit, guix_commit)

    @staticmethod
    def metadata_path(output):
        return output / "release-assets" / HELPER.METADATA_ASSET

    @staticmethod
    def read_plan(output):
        return json.loads((output / "release-plan.json").read_text())

    def test_fresh_generation_rewrites_only_url_and_is_deterministic(self):
        cache, original, narinfo_name = self.make_cache("cache")

        first = self.prepare(cache, "first", "2026-07-25T10:00:00Z")
        second = self.prepare(
            cache,
            "first-copy",
            "2026-07-25T10:00:00Z",
            prior=[self.metadata_path(first)],
        )

        first_assets = first / "release-assets"
        shard_dir = first_assets / "nar-shards" / self.shard_tag("first")
        nar_assets = sorted(shard_dir.glob("nar-v2-sha256-*"))
        self.assertEqual(len(nar_assets), 1)
        self.assertEqual(nar_assets[0].read_bytes(), b"compressed nar")
        published = (first / "pages" / narinfo_name).read_bytes()
        expected_url = (
            "https://github.com/example/qubes-template-guix/releases/download/"
            f"{self.shard_tag('first')}/{nar_assets[0].name}"
        ).encode()
        self.assertIn(b"URL: " + expected_url + b"\n", published)
        self.assertNotIn(b"FileSize:", original)
        self.assertNotIn(b"FileSize:", published)
        self.assertEqual(
            original.replace(b"URL: nar/zstd/cache-object.nar.zst\n", b""),
            published.replace(b"URL: " + expected_url + b"\n", b""),
        )
        self.assertIn(b"Signature: cache.example:unchanged-signature\n", published)

        # The tag is part of narinfos and therefore intentionally differs, but
        # rebuilding one exact generation produces byte-identical metadata.
        exact_copy = self.work_dir / "exact-copy"
        qubes_commit = hashlib.sha1(b"qubes:first").hexdigest()
        guix_commit = hashlib.sha1(b"guix:first").hexdigest()
        registered_releases = self.inventory_releases
        self.inventory_releases = {}
        try:
            HELPER.prepare_release(
                cache_dir=cache,
                output_dir=exact_copy,
                repository=REPOSITORY,
                release_tag=self.release_tag("first"),
                qubes_commit=qubes_commit,
                guix_commit=guix_commit,
                generated_at_text="2026-07-25T10:00:00Z",
                prior_metadata=[],
                release_inventory=self.write_inventory(),
                retention_days=180,
                minimum_generations=8,
            )
        finally:
            self.inventory_releases = registered_releases
        self.assertEqual(
            self.metadata_path(first).read_bytes(),
            self.metadata_path(exact_copy).read_bytes(),
        )
        generation = HELPER.load_prior_metadata(self.metadata_path(first))
        self.assertIsNotNone(generation)
        self.assertEqual(generation.release_tag, self.release_tag("first"))
        self.assertEqual(generation.qubes_commit, qubes_commit)
        self.assertEqual(generation.guix_commit, guix_commit)

        plan = self.read_plan(first)
        self.assertEqual(plan["policy"]["retention_days"], 180)
        self.assertEqual(plan["policy"]["minimum_generations"], 8)
        self.assertEqual(plan["policy"]["gc_grace_days"], 1)
        self.assertEqual(len(plan["retained_releases"]), 1)
        self.assertEqual(plan["delete_releases"], [])

        # Keep this output referenced so the independently prepared second
        # generation also exercises a distinct, valid immutable tag.
        self.assertTrue(self.metadata_path(second).is_file())

    def test_prior_object_is_deduplicated_to_original_release(self):
        cache_one, _, narinfo_name = self.make_cache("cache-one")
        first = self.prepare(cache_one, "one", "2026-07-24T10:00:00Z")
        first_metadata = self.metadata_path(first)

        newest_signature = b"Signature: runner-two:new-signature\n"
        cache_two, _, _ = self.make_cache("cache-two", signature=newest_signature)
        second = self.prepare(
            cache_two,
            "two",
            "2026-07-25T10:00:00Z",
            prior=[first_metadata],
        )

        second_assets = second / "release-assets"
        self.assertFalse((second_assets / "nar-shards").exists())
        published = (second / "pages" / narinfo_name).read_text()
        self.assertIn(f"/{self.shard_tag('one')}/nar-v2-sha256-", published)
        self.assertIn(newest_signature.decode().strip(), published)
        self.assertNotIn("unchanged-signature", published)
        manifest = json.loads((second_assets / HELPER.MANIFEST_ASSET).read_text())
        self.assertEqual(manifest["published_nar_sha256"], [])
        self.assertEqual(
            manifest["nar_objects"][0]["owner_release_tag"],
            self.shard_tag("one"),
        )

        # Recovery requires the downloaded ZIP for every managed generation
        # Release, including the generation that first published this shard.
        recovered = self.work_dir / "external-owner-recovery"
        HELPER.recover_release_state(
            output_dir=recovered,
            repository=REPOSITORY,
            as_of_text="2026-07-25T11:00:00Z",
            prior_metadata=[self.metadata_path(first), self.metadata_path(second)],
            release_inventory=self.write_inventory(),
            retention_days=180,
            minimum_generations=8,
        )
        self.assertTrue((recovered / "pages" / narinfo_name).is_file())

    def test_changed_same_revision_asset_set_uses_a_distinct_shard_tag(self):
        prior_cache, _, _ = self.make_cache(
            "retry-prior-cache",
            index=0,
            payload=b"retained prior object",
            relative_url="nar/zstd/retry-prior",
        )
        prior = self.prepare(
            prior_cache,
            "retry-prior",
            "2026-07-24T10:00:00Z",
        )
        prior_metadata = self.metadata_path(prior)
        prior_shard = self.shard_tag("retry-prior")

        qubes_commit = hashlib.sha1(b"qubes:retry-current").hexdigest()
        guix_commit = hashlib.sha1(b"guix:retry-current").hexdigest()
        release_tag = HELPER.release_tag_for_commits(qubes_commit, guix_commit)

        def prepare_attempt(cache, output):
            HELPER.prepare_release(
                cache_dir=cache,
                output_dir=output,
                repository=REPOSITORY,
                release_tag=release_tag,
                qubes_commit=qubes_commit,
                guix_commit=guix_commit,
                generated_at_text="2026-07-25T10:00:00Z",
                prior_metadata=[prior_metadata],
                release_inventory=self.write_inventory(),
                retention_days=180,
                minimum_generations=8,
            )

        first_cache, _, _ = self.make_cache(
            "retry-first-cache",
            index=1,
            payload=b"available only during first attempt",
            relative_url="nar/zstd/retry-first",
        )
        first = self.work_dir / "retry-first-output"
        prepare_attempt(first_cache, first)
        first_shard_dirs = list((first / "release-assets" / "nar-shards").iterdir())
        self.assertEqual(len(first_shard_dirs), 1)
        first_shard_dir = first_shard_dirs[0]
        first_shard = first_shard_dir.name

        # Simulate interruption after this shard became public but before its
        # generation metadata Release was created.
        self.inventory_releases[first_shard] = {
            asset.name: self.inventory_asset(asset)
            for asset in first_shard_dir.iterdir()
        }
        self.inventory_published_at[first_shard] = "2026-07-25T10:00:00Z"

        retry_cache, _, _ = self.make_cache(
            "retry-second-cache",
            index=2,
            payload=b"available only during retry",
            relative_url="nar/zstd/retry-second",
        )
        retry = self.work_dir / "retry-second-output"
        prepare_attempt(retry_cache, retry)
        retry_shard_dirs = list((retry / "release-assets" / "nar-shards").iterdir())
        self.assertEqual(len(retry_shard_dirs), 1)
        retry_shard = retry_shard_dirs[0].name

        first_identity = HELPER.parse_nar_shard_tag(first_shard)
        retry_identity = HELPER.parse_nar_shard_tag(retry_shard)
        self.assertEqual(first_identity[:3], retry_identity[:3])
        self.assertNotEqual(first_identity[3], retry_identity[3])

        plan = self.read_plan(retry)
        deleted_shards = {
            item["release_tag"] for item in plan["delete_nar_shard_releases"]
        }
        referenced_shards = {
            item["release_tag"] for item in plan["referenced_nar_shard_releases"]
        }
        self.assertIn(first_shard, deleted_shards)
        self.assertNotIn(prior_shard, deleted_shards)
        self.assertIn(prior_shard, referenced_shards)

    def test_new_nars_are_split_into_deterministic_900_asset_shards(self):
        cache = self.make_many_cache("large-cache", 901)

        output = self.prepare(cache, "large", "2026-07-25T10:00:00Z")

        shard_root = output / "release-assets" / "nar-shards"
        shard_dirs = sorted(path for path in shard_root.iterdir() if path.is_dir())
        self.assertEqual(
            [path.name for path in shard_dirs],
            [self.shard_tag("large", 1), self.shard_tag("large", 2)],
        )
        self.assertEqual(len(list(shard_dirs[0].iterdir())), 900)
        self.assertEqual(len(list(shard_dirs[1].iterdir())), 1)

        manifest = json.loads(
            (output / "release-assets" / HELPER.MANIFEST_ASSET).read_text()
        )
        self.assertEqual(len(manifest["published_nar_sha256"]), 901)
        owners = [item["owner_release_tag"] for item in manifest["nar_objects"]]
        self.assertEqual(owners[:900], [self.shard_tag("large", 1)] * 900)
        self.assertEqual(owners[900:], [self.shard_tag("large", 2)])

    def test_newest_metadata_wins_for_same_content_identity(self):
        first_cache, _, narinfo_name = self.make_cache(
            "transport-one", payload=b"old compressed representation"
        )
        first = self.prepare(first_cache, "transport-one", "2026-07-24T10:00:00Z")
        second_cache, _, _ = self.make_cache(
            "transport-two",
            payload=b"new compressed representation",
            relative_url="nar/zstd/new-representation.nar.zst",
            signature=b"Signature: cache.example:new-signature\n",
            deriver=b"different-deriver",
        )

        second = self.prepare(
            second_cache,
            "transport-two",
            "2026-07-25T10:00:00Z",
            prior=[self.metadata_path(first)],
        )

        published = (second / "pages" / narinfo_name).read_text()
        self.assertIn(f"/{self.shard_tag('transport-two')}/", published)
        self.assertIn("Deriver: different-deriver", published)
        self.assertIn("Signature: cache.example:new-signature", published)
        self.assertNotIn(self.shard_tag("transport-one"), published)

    def test_newest_nix_cache_info_wins_across_retained_generations(self):
        first_cache, _, _ = self.make_cache("cache-info-one")
        first = self.prepare(first_cache, "cache-info-one", "2026-07-24T10:00:00Z")
        newest_cache_info = (
            b"StoreDir: /gnu/store\n"
            b"WantMassQuery: 1\n"
            b"Priority: 50\n"
            b"FutureField: supported\n"
        )
        second_cache, _, _ = self.make_cache(
            "cache-info-two", nix_cache_info=newest_cache_info
        )

        second = self.prepare(
            second_cache,
            "cache-info-two",
            "2026-07-25T10:00:00Z",
            prior=[self.metadata_path(first)],
        )

        self.assertEqual(
            (second / "pages" / "nix-cache-info").read_bytes(), newest_cache_info
        )

    def test_inventory_must_contain_referenced_asset_with_recorded_size(self):
        first_cache, _, _ = self.make_cache("inventory-first")
        first = self.prepare(first_cache, "inventory-first", "2026-07-24T10:00:00Z")
        metadata = self.metadata_path(first)
        shard_tag = self.shard_tag("inventory-first")
        shard_assets = dict(self.inventory_releases[shard_tag])

        del self.inventory_releases[shard_tag]
        second_cache, _, _ = self.make_cache("inventory-second")
        with self.assertRaisesRegex(HELPER.StateError, "missing NAR shard"):
            self.prepare(
                second_cache,
                "inventory-second",
                "2026-07-25T10:00:00Z",
                prior=[metadata],
            )

        self.inventory_releases[shard_tag] = dict(shard_assets)
        asset_name = next(iter(shard_assets))
        del self.inventory_releases[shard_tag][asset_name]
        with self.assertRaisesRegex(HELPER.StateError, "must contain from 1"):
            HELPER.recover_release_state(
                output_dir=self.work_dir / "missing-asset-recovery",
                repository=REPOSITORY,
                as_of_text="2026-07-25T10:00:00Z",
                prior_metadata=[metadata],
                release_inventory=self.write_inventory(),
                retention_days=180,
                minimum_generations=8,
            )

        self.inventory_releases[shard_tag] = dict(shard_assets)
        self.inventory_releases[shard_tag][asset_name]["size"] += 1
        with self.assertRaisesRegex(HELPER.StateError, "asset-set digest"):
            HELPER.recover_release_state(
                output_dir=self.work_dir / "bad-inventory-recovery",
                repository=REPOSITORY,
                as_of_text="2026-07-25T10:00:00Z",
                prior_metadata=[metadata],
                release_inventory=self.write_inventory(),
                retention_days=180,
                minimum_generations=8,
            )

    def test_inventory_requires_settled_assets_and_matches_all_digests(self):
        cache, _, _ = self.make_cache("strict-inventory")
        output = self.prepare(cache, "strict-inventory", "2026-07-25T10:00:00Z")
        metadata = self.metadata_path(output)
        baseline = copy.deepcopy(self.inventory_releases)
        shard_tag = self.shard_tag("strict-inventory")
        nar_name = next(iter(baseline[shard_tag]))

        cases = (
            ("state", "new", "state must be 'uploaded'"),
            ("digest", "0" * 64, "canonical sha256"),
            ("digest", "sha256:" + "A" * 64, "canonical sha256"),
        )
        for index, (field, value, message) in enumerate(cases):
            with self.subTest(field=field, value=value):
                self.inventory_releases = copy.deepcopy(baseline)
                self.inventory_releases[shard_tag][nar_name][field] = value
                with self.assertRaisesRegex(HELPER.StateError, message):
                    HELPER.recover_release_state(
                        output_dir=self.work_dir / f"bad-asset-state-{index}",
                        repository=REPOSITORY,
                        as_of_text="2026-07-25T10:00:00Z",
                        prior_metadata=[metadata],
                        release_inventory=self.write_inventory(),
                        retention_days=180,
                        minimum_generations=8,
                    )

        self.inventory_releases = copy.deepcopy(baseline)
        del self.inventory_releases[shard_tag][nar_name]["state"]
        with self.assertRaisesRegex(HELPER.StateError, "invalid fields"):
            HELPER.recover_release_state(
                output_dir=self.work_dir / "missing-asset-state",
                repository=REPOSITORY,
                as_of_text="2026-07-25T10:00:00Z",
                prior_metadata=[metadata],
                release_inventory=self.write_inventory(),
                retention_days=180,
                minimum_generations=8,
            )

        self.inventory_releases = copy.deepcopy(baseline)
        self.inventory_releases[shard_tag][nar_name]["digest"] = "sha256:" + "0" * 64
        with self.assertRaisesRegex(HELPER.StateError, "asset name does not match"):
            HELPER.recover_release_state(
                output_dir=self.work_dir / "wrong-nar-digest",
                repository=REPOSITORY,
                as_of_text="2026-07-25T10:00:00Z",
                prior_metadata=[metadata],
                release_inventory=self.write_inventory(),
                retention_days=180,
                minimum_generations=8,
            )

    def test_content_bound_shard_inventory_rejects_noncanonical_sets(self):
        cache, _, _ = self.make_cache("content-bound-inventory")
        output = self.prepare(cache, "content-bound-inventory", "2026-07-25T10:00:00Z")
        metadata = self.metadata_path(output)
        baseline = copy.deepcopy(self.inventory_releases)
        shard_tag = self.shard_tag("content-bound-inventory")
        asset_name, asset = next(iter(baseline[shard_tag].items()))

        empty = copy.deepcopy(baseline)
        empty[shard_tag] = {}

        extra = copy.deepcopy(baseline)
        extra_content = b"unexpected extra shard asset"
        extra_digest = hashlib.sha256(extra_content).hexdigest()
        extra[shard_tag][HELPER.asset_name(extra_digest)] = {
            "digest": f"sha256:{extra_digest}",
            "size": len(extra_content),
            "state": "uploaded",
        }

        mismatched_name = copy.deepcopy(baseline)
        del mismatched_name[shard_tag][asset_name]
        mismatched_name[shard_tag][HELPER.asset_name("0" * 64)] = copy.deepcopy(asset)

        wrong_tag_inventory = copy.deepcopy(baseline)
        qubes_commit, guix_commit, shard_number, tag_digest = (
            HELPER.parse_nar_shard_tag(shard_tag)
        )
        wrong_digest = "0" * 64 if tag_digest != "0" * 64 else "1" * 64
        wrong_tag = HELPER.nar_shard_tag_for_commits(
            qubes_commit,
            guix_commit,
            shard_number,
            wrong_digest,
        )
        wrong_tag_inventory[wrong_tag] = wrong_tag_inventory.pop(shard_tag)

        cases = (
            ("empty", empty, "must contain from 1"),
            ("extra", extra, "asset-set digest"),
            ("name-digest", mismatched_name, "asset name does not match"),
            ("tag-digest", wrong_tag_inventory, "asset-set digest"),
        )
        for label, inventory, message in cases:
            with self.subTest(case=label):
                self.inventory_releases = inventory
                inventory_path = self.write_inventory()
                with self.assertRaisesRegex(HELPER.StateError, message):
                    HELPER.load_release_inventory(inventory_path, REPOSITORY)
                with self.assertRaisesRegex(HELPER.StateError, message):
                    HELPER.recover_release_state(
                        output_dir=self.work_dir / f"noncanonical-{label}",
                        repository=REPOSITORY,
                        as_of_text="2026-07-25T10:00:00Z",
                        prior_metadata=[metadata],
                        release_inventory=inventory_path,
                        retention_days=180,
                        minimum_generations=8,
                    )

    def test_inventory_exactly_matches_loaded_generation_releases(self):
        cache, _, _ = self.make_cache("generation-inventory")
        output = self.prepare(cache, "generation-inventory", "2026-07-25T10:00:00Z")
        metadata = self.metadata_path(output)
        generation_tag = self.release_tag("generation-inventory")
        baseline = copy.deepcopy(self.inventory_releases)

        self.inventory_releases[generation_tag][HELPER.MANIFEST_ASSET]["digest"] = (
            "sha256:" + "0" * 64
        )
        with self.assertRaisesRegex(HELPER.StateError, "generation asset digest"):
            HELPER.recover_release_state(
                output_dir=self.work_dir / "wrong-generation-digest",
                repository=REPOSITORY,
                as_of_text="2026-07-25T10:00:00Z",
                prior_metadata=[metadata],
                release_inventory=self.write_inventory(),
                retention_days=180,
                minimum_generations=8,
            )

        self.inventory_releases = copy.deepcopy(baseline)
        self.inventory_releases[generation_tag][HELPER.METADATA_ASSET]["size"] += 1
        with self.assertRaisesRegex(HELPER.StateError, "generation asset digest"):
            HELPER.recover_release_state(
                output_dir=self.work_dir / "wrong-generation-zip-size",
                repository=REPOSITORY,
                as_of_text="2026-07-25T10:00:00Z",
                prior_metadata=[metadata],
                release_inventory=self.write_inventory(),
                retention_days=180,
                minimum_generations=8,
            )

        self.inventory_releases = copy.deepcopy(baseline)
        self.inventory_releases[generation_tag]["unexpected"] = {
            "digest": f"sha256:{hashlib.sha256(b'').hexdigest()}",
            "size": 0,
            "state": "uploaded",
        }
        with self.assertRaisesRegex(HELPER.StateError, "must contain exactly"):
            HELPER.recover_release_state(
                output_dir=self.work_dir / "extra-generation-asset",
                repository=REPOSITORY,
                as_of_text="2026-07-25T10:00:00Z",
                prior_metadata=[metadata],
                release_inventory=self.write_inventory(),
                retention_days=180,
                minimum_generations=8,
            )

        for name, mutate in (
            (
                "missing",
                lambda releases: releases.pop(generation_tag),
            ),
            (
                "unloaded",
                lambda releases: releases.__setitem__(
                    self.release_tag("unloaded-generation"), {}
                ),
            ),
        ):
            with self.subTest(generation_set=name):
                self.inventory_releases = copy.deepcopy(baseline)
                mutate(self.inventory_releases)
                with self.assertRaisesRegex(HELPER.StateError, "do not exactly match"):
                    HELPER.recover_release_state(
                        output_dir=self.work_dir / f"generation-set-{name}",
                        repository=REPOSITORY,
                        as_of_text="2026-07-25T10:00:00Z",
                        prior_metadata=[metadata],
                        release_inventory=self.write_inventory(),
                        retention_days=180,
                        minimum_generations=8,
                    )

        self.inventory_releases = copy.deepcopy(baseline)
        new_cache, _, _ = self.make_cache("existing-current")
        current_tag = self.release_tag("existing-current")
        self.inventory_releases[current_tag] = {}
        with self.assertRaisesRegex(
            HELPER.StateError, "current release tag already exists"
        ):
            self.prepare(
                new_cache,
                "existing-current",
                "2026-07-26T10:00:00Z",
                prior=[metadata],
            )

    def test_gc_marker_inventory_requires_time_and_has_no_assets(self):
        cache, _, _ = self.make_cache("marker-inventory")
        output = self.prepare(cache, "marker-inventory", "2026-07-25T10:00:00Z")
        metadata = self.metadata_path(output)
        generation_tag = self.release_tag("marker-inventory")
        self.inventory_published_at[generation_tag] = "not-a-timestamp"
        with self.assertRaisesRegex(HELPER.StateError, "canonical UTC form"):
            HELPER.recover_release_state(
                output_dir=self.work_dir / "invalid-release-time",
                repository=REPOSITORY,
                as_of_text="2026-07-25T10:00:00Z",
                prior_metadata=[metadata],
                release_inventory=self.write_inventory(),
                retention_days=180,
                minimum_generations=8,
            )

        self.inventory_published_at[generation_tag] = "2026-07-25T10:00:00Z"
        marker_tag = self.register_gc_marker(
            "orphan-with-asset", "2026-07-25T10:01:00Z"
        )
        self.inventory_releases[marker_tag]["unexpected"] = {
            "digest": f"sha256:{hashlib.sha256(b'').hexdigest()}",
            "size": 0,
            "state": "uploaded",
        }
        with self.assertRaisesRegex(HELPER.StateError, "must not contain assets"):
            HELPER.recover_release_state(
                output_dir=self.work_dir / "marker-with-asset",
                repository=REPOSITORY,
                as_of_text="2026-07-25T10:00:00Z",
                prior_metadata=[metadata],
                release_inventory=self.write_inventory(),
                retention_days=180,
                minimum_generations=8,
            )

    def test_post_deploy_marker_starts_gc_grace_at_publication_time(self):
        metadata = []
        for index, timestamp in enumerate(
            ("2026-01-01T00:00:00Z", "2026-01-02T00:00:00Z")
        ):
            cache, _, _ = self.make_cache(
                f"grace-cache-{index}",
                index=index,
                payload=f"grace-{index}".encode(),
                relative_url=f"nar/zstd/grace-{index}",
            )
            output = self.prepare(
                cache,
                f"grace-{index}",
                timestamp,
                prior=metadata,
            )
            metadata.append(self.metadata_path(output))

        third_cache, _, _ = self.make_cache(
            "grace-cache-2",
            index=2,
            payload=b"grace-2",
            relative_url="nar/zstd/grace-2",
        )
        final = self.prepare(
            third_cache,
            "grace-2",
            "2026-01-20T00:00:00Z",
            prior=metadata,
            retention_days=10,
            minimum_generations=2,
            gc_grace_days=1,
        )
        metadata.append(self.metadata_path(final))
        plan = self.read_plan(final)
        protected = plan["gc_protected_expired_releases"]
        self.assertEqual(
            [item["release_tag"] for item in protected], [self.release_tag("grace-0")]
        )
        self.assertEqual(protected[0]["dropped_at"], "2026-01-20T00:00:00Z")
        self.assertIsNone(protected[0]["gc_marker_published_at"])
        self.assertIsNone(protected[0]["delete_after"])
        self.assertEqual(plan["delete_generation_releases"], [])
        self.assertEqual(plan["revoke_gc_marker_releases"], [])
        marker_tag = self.gc_marker_tag("grace-0")
        self.assertEqual(
            plan["create_gc_marker_releases"],
            [{"release_tag": marker_tag, "repository": REPOSITORY}],
        )
        self.assertEqual(
            [item["release_tag"] for item in plan["gc_protected_nar_shard_releases"]],
            [self.shard_tag("grace-0")],
        )
        self.assertFalse((final / "pages" / f"{store_hash(0)}.narinfo").exists())

        delayed = self.work_dir / "delayed-first-success"
        HELPER.recover_release_state(
            output_dir=delayed,
            repository=REPOSITORY,
            as_of_text="2026-02-20T00:00:00Z",
            prior_metadata=metadata,
            release_inventory=self.write_inventory(),
            retention_days=10,
            minimum_generations=2,
            gc_grace_days=1,
        )
        delayed_plan = self.read_plan(delayed)
        self.assertEqual(delayed_plan["delete_generation_releases"], [])
        self.assertEqual(delayed_plan["delete_nar_shard_releases"], [])
        self.assertEqual(
            delayed_plan["create_gc_marker_releases"],
            [{"release_tag": marker_tag, "repository": REPOSITORY}],
        )

        # The first successful Pages deployment creates this marker.  Its API
        # publication time, not the nominal retention boundary, starts grace.
        self.register_gc_marker("grace-0", "2026-02-20T00:01:00Z")
        during_grace = self.work_dir / "during-marker-grace"
        HELPER.recover_release_state(
            output_dir=during_grace,
            repository=REPOSITORY,
            as_of_text="2026-02-20T12:00:00Z",
            prior_metadata=metadata,
            release_inventory=self.write_inventory(),
            retention_days=10,
            minimum_generations=2,
            gc_grace_days=1,
        )
        during_plan = self.read_plan(during_grace)
        self.assertEqual(during_plan["create_gc_marker_releases"], [])
        self.assertEqual(during_plan["delete_generation_releases"], [])
        self.assertEqual(during_plan["delete_gc_marker_releases"], [])
        self.assertEqual(during_plan["revoke_gc_marker_releases"], [])
        during_state = during_plan["gc_protected_expired_releases"][0]
        self.assertEqual(during_state["gc_marker_published_at"], "2026-02-20T00:01:00Z")
        self.assertEqual(during_state["delete_after"], "2026-02-21T00:01:00Z")

        recovered = self.work_dir / "elapsed-marker-grace"
        HELPER.recover_release_state(
            output_dir=recovered,
            repository=REPOSITORY,
            as_of_text="2026-02-21T00:01:00Z",
            prior_metadata=metadata,
            release_inventory=self.write_inventory(),
            retention_days=10,
            minimum_generations=2,
            gc_grace_days=1,
        )
        recovered_plan = self.read_plan(recovered)
        self.assertEqual(
            [
                item["release_tag"]
                for item in recovered_plan["delete_generation_releases"]
            ],
            [self.release_tag("grace-0")],
        )
        self.assertEqual(
            [
                item["release_tag"]
                for item in recovered_plan["delete_nar_shard_releases"]
            ],
            [self.shard_tag("grace-0")],
        )
        self.assertEqual(
            recovered_plan["delete_gc_marker_releases"],
            [{"release_tag": marker_tag, "repository": REPOSITORY}],
        )
        self.assertEqual(recovered_plan["revoke_gc_marker_releases"], [])
        self.assertEqual(
            [item["release_tag"] for item in recovered_plan["delete_releases"]],
            [self.release_tag("grace-0"), self.shard_tag("grace-0"), marker_tag],
        )

    def test_stale_retained_and_orphan_markers_are_cleanup_only(self):
        metadata = []
        for index, timestamp in enumerate(
            (
                "2026-01-01T00:00:00Z",
                "2026-01-02T00:00:00Z",
                "2026-01-20T00:00:00Z",
            )
        ):
            cache, _, _ = self.make_cache(
                f"stale-cache-{index}",
                index=index,
                payload=f"stale-{index}".encode(),
                relative_url=f"nar/zstd/stale-{index}",
            )
            output = self.prepare(
                cache,
                f"stale-{index}",
                timestamp,
                prior=metadata,
                retention_days=10,
                minimum_generations=2,
            )
            metadata.append(self.metadata_path(output))

        # This marker predates stale-0's Jan 20 count-based retention drop and
        # therefore cannot prove a successful post-expiration Pages deploy.
        stale_marker = self.register_gc_marker("stale-0", "2026-01-19T00:00:00Z")
        retained_marker = self.register_gc_marker("stale-2", "2026-01-20T00:01:00Z")
        orphan_marker = self.register_gc_marker(
            "orphan-generation", "2026-01-20T00:01:00Z"
        )
        recovered = self.work_dir / "stale-marker-recovery"
        HELPER.recover_release_state(
            output_dir=recovered,
            repository=REPOSITORY,
            as_of_text="2026-02-01T00:00:00Z",
            prior_metadata=metadata,
            release_inventory=self.write_inventory(),
            retention_days=10,
            minimum_generations=2,
            gc_grace_days=1,
        )
        plan = self.read_plan(recovered)
        self.assertEqual(plan["delete_generation_releases"], [])
        self.assertEqual(plan["delete_nar_shard_releases"], [])
        self.assertEqual(plan["create_gc_marker_releases"], [])
        self.assertEqual(plan["delete_gc_marker_releases"], [])
        self.assertEqual(
            [item["release_tag"] for item in plan["revoke_gc_marker_releases"]],
            sorted([stale_marker, retained_marker, orphan_marker]),
        )
        self.assertEqual(plan["delete_releases"], [])
        state = plan["gc_protected_expired_releases"][0]
        self.assertEqual(state["gc_marker_release_tag"], stale_marker)
        self.assertEqual(state["gc_marker_published_at"], "2026-01-19T00:00:00Z")
        self.assertIsNone(state["delete_after"])

    def test_re_retention_revokes_old_marker_before_later_re_expiry(self):
        metadata = []
        for index, timestamp in enumerate(
            (
                "2026-01-01T00:00:00Z",
                "2026-01-02T00:00:00Z",
                "2026-01-20T00:00:00Z",
            )
        ):
            cache, _, _ = self.make_cache(
                f"policy-cache-{index}",
                index=index,
                payload=f"policy-{index}".encode(),
                relative_url=f"nar/zstd/policy-{index}",
            )
            output = self.prepare(
                cache,
                f"policy-{index}",
                timestamp,
                prior=metadata,
                retention_days=10,
                minimum_generations=2,
            )
            metadata.append(self.metadata_path(output))

        marker_tag = self.register_gc_marker("policy-0", "2026-01-20T00:01:00Z")
        re_retained = self.work_dir / "policy-re-retained"
        HELPER.recover_release_state(
            output_dir=re_retained,
            repository=REPOSITORY,
            as_of_text="2026-02-21T00:01:00Z",
            prior_metadata=metadata,
            release_inventory=self.write_inventory(),
            retention_days=365,
            minimum_generations=2,
            gc_grace_days=1,
        )
        retained_plan = self.read_plan(re_retained)
        marker_reference = {"release_tag": marker_tag, "repository": REPOSITORY}
        self.assertEqual(retained_plan["delete_generation_releases"], [])
        self.assertEqual(retained_plan["delete_nar_shard_releases"], [])
        self.assertEqual(retained_plan["revoke_gc_marker_releases"], [marker_reference])
        self.assertEqual(retained_plan["delete_gc_marker_releases"], [])
        self.assertEqual(retained_plan["delete_releases"], [])
        self.assertTrue((re_retained / "pages" / f"{store_hash(0)}.narinfo").is_file())

        # The workflow must complete this revocation before publishing the
        # re-retained Pages state.  A later policy contraction therefore sees
        # no old authorization and must begin a fresh marker cycle.
        del self.inventory_releases[marker_tag]
        del self.inventory_published_at[marker_tag]
        re_expired = self.work_dir / "policy-re-expired"
        HELPER.recover_release_state(
            output_dir=re_expired,
            repository=REPOSITORY,
            as_of_text="2026-02-22T00:00:00Z",
            prior_metadata=metadata,
            release_inventory=self.write_inventory(),
            retention_days=10,
            minimum_generations=2,
            gc_grace_days=1,
        )
        expired_plan = self.read_plan(re_expired)
        self.assertEqual(expired_plan["delete_generation_releases"], [])
        self.assertEqual(expired_plan["delete_nar_shard_releases"], [])
        self.assertEqual(expired_plan["revoke_gc_marker_releases"], [])
        self.assertEqual(expired_plan["create_gc_marker_releases"], [marker_reference])
        self.assertFalse((re_expired / "pages" / f"{store_hash(0)}.narinfo").exists())

    def test_new_metadata_is_loaded_and_compared_before_install(self):
        cache, _, _ = self.make_cache("self-validation-cache")

        def write_oversized(path, generation, manifest_content):
            with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_STORED) as archive:
                archive.writestr(HELPER.MANIFEST_MEMBER, manifest_content)
                archive.writestr(HELPER.NIX_CACHE_MEMBER, generation.nix_cache_info)
                narinfo = generation.narinfos[0]
                archive.writestr(
                    f"{HELPER.ARCHIVE_ROOT}/narinfo/{narinfo.path}",
                    b"x" * (HELPER.MAX_NARINFO_SIZE + 1),
                )

        with mock.patch.object(
            HELPER, "write_deterministic_zip", side_effect=write_oversized
        ), self.assertRaisesRegex(HELPER.StateError, "exceeds"):
            self.prepare(
                cache,
                "self-validation-oversized",
                "2026-07-25T10:00:00Z",
            )
        self.assertFalse((self.work_dir / "output-self-validation-oversized").exists())

        original_writer = HELPER.write_deterministic_zip

        def write_different_generation(path, generation, _manifest_content):
            changed = HELPER.replace(
                generation,
                nix_cache_info=generation.nix_cache_info + b"Extra: changed\n",
            )
            original_writer(
                path,
                changed,
                HELPER.canonical_json(HELPER.create_manifest(changed)),
            )

        with mock.patch.object(
            HELPER,
            "write_deterministic_zip",
            side_effect=write_different_generation,
        ), self.assertRaisesRegex(HELPER.StateError, "does not reproduce"):
            self.prepare(
                cache,
                "self-validation-different",
                "2026-07-25T10:00:00Z",
            )
        self.assertFalse((self.work_dir / "output-self-validation-different").exists())

    def test_retention_excludes_old_pages_and_requests_gc_marker(self):
        metadata = []
        outputs = []
        # Every generation is older than the 180-day window at the final
        # timestamp.  Of nine generations, exactly the newest eight survive.
        for index in range(9):
            cache, _, _ = self.make_cache(
                f"unique-cache-{index}",
                index=index,
                payload=f"nar-{index}".encode(),
                relative_url=f"nar/zstd/object-{index}.nar.zst",
            )
            output = self.prepare(
                cache,
                f"unique-{index}",
                f"20{10 + index:02d}-01-01T00:00:00Z",
                prior=metadata,
                gc_grace_days=0,
            )
            outputs.append(output)
            metadata.append(self.metadata_path(output))

        final_plan = self.read_plan(outputs[-1])
        self.assertEqual(len(final_plan["retained_releases"]), 8)
        self.assertEqual(final_plan["delete_generation_releases"], [])
        self.assertEqual(final_plan["delete_nar_shard_releases"], [])
        self.assertEqual(
            final_plan["create_gc_marker_releases"],
            [
                {
                    "release_tag": self.gc_marker_tag("unique-0"),
                    "repository": REPOSITORY,
                }
            ],
        )
        pages = outputs[-1] / "pages"
        self.assertFalse((pages / f"{store_hash(0)}.narinfo").exists())
        for index in range(1, 9):
            self.assertTrue((pages / f"{store_hash(index)}.narinfo").is_file())
        self.assertEqual(list(pages.glob("nar/**")), [])

    def test_expired_metadata_is_deleted_but_referenced_shard_is_preserved(self):
        metadata = []
        outputs = []
        # All generations reference one deduplicated object owned by the
        # oldest generation.  Its metadata expires independently, while its
        # object shard remains because retained generations still reference it.
        for index in range(9):
            cache, _, _ = self.make_cache(f"shared-cache-{index}")
            output = self.prepare(
                cache,
                f"shared-{index}",
                f"20{10 + index:02d}-01-01T00:00:00Z",
                prior=metadata,
                gc_grace_days=0,
            )
            outputs.append(output)
            metadata.append(self.metadata_path(output))

        self.register_gc_marker("shared-0", "2018-01-01T00:00:00Z")
        recovered = self.work_dir / "shared-expired-recovery"
        HELPER.recover_release_state(
            output_dir=recovered,
            repository=REPOSITORY,
            as_of_text="2018-01-01T00:00:00Z",
            prior_metadata=metadata,
            release_inventory=self.write_inventory(),
            retention_days=180,
            minimum_generations=8,
            gc_grace_days=0,
        )
        plan = self.read_plan(recovered)
        self.assertEqual(
            [item["release_tag"] for item in plan["delete_generation_releases"]],
            [self.release_tag("shared-0")],
        )
        self.assertNotIn(
            self.shard_tag("shared-0"),
            [item["release_tag"] for item in plan["delete_nar_shard_releases"]],
        )
        published = (recovered / "pages" / f"{store_hash(0)}.narinfo").read_text()
        self.assertIn(f"/{self.shard_tag('shared-0')}/", published)

    def test_recent_generations_extend_retention_beyond_minimum(self):
        metadata = []
        final = None
        for index in range(9):
            cache, _, _ = self.make_cache(
                f"recent-cache-{index}",
                index=index,
                payload=f"recent-{index}".encode(),
                relative_url=f"nar/zstd/recent-{index}.nar.zst",
            )
            final = self.prepare(
                cache,
                f"recent-{index}",
                f"2026-07-{index + 1:02d}T00:00:00Z",
                prior=metadata,
            )
            metadata.append(self.metadata_path(final))

        self.assertIsNotNone(final)
        plan = self.read_plan(final)
        self.assertEqual(len(plan["retained_releases"]), 9)
        self.assertEqual(plan["expired_releases"], [])

    def test_recover_rebuilds_pages_and_plan_from_metadata_only(self):
        first_cache, _, _ = self.make_cache(
            "recovery-cache-one",
            index=0,
            payload=b"recovery-one",
            relative_url="nar/zstd/recovery-one",
        )
        first = self.prepare(first_cache, "recovery-one", "2020-01-01T00:00:00Z")
        second_cache, _, _ = self.make_cache(
            "recovery-cache-two",
            index=1,
            payload=b"recovery-two",
            relative_url="nar/zstd/recovery-two",
        )
        second = self.prepare(
            second_cache,
            "recovery-two",
            "2021-01-01T00:00:00Z",
            prior=[self.metadata_path(first)],
        )

        metadata_one = self.work_dir / "recovery-one.zip"
        metadata_two = self.work_dir / "recovery-two.zip"
        metadata_one.write_bytes(self.metadata_path(first).read_bytes())
        metadata_two.write_bytes(self.metadata_path(second).read_bytes())
        for path in (first_cache, second_cache, first, second):
            shutil.rmtree(path)

        recovered = self.work_dir / "recovered-state"
        status = HELPER.main(
            [
                "recover",
                "--output-dir",
                str(recovered),
                "--repository",
                REPOSITORY,
                "--as-of",
                "2026-07-25T12:00:00Z",
                "--minimum-generations",
                "1",
                "--release-inventory",
                str(self.write_inventory()),
                "--prior-metadata",
                str(metadata_one),
                "--prior-metadata",
                str(metadata_two),
            ]
        )

        self.assertEqual(status, 0)
        self.assertFalse((recovered / "release-assets").exists())
        self.assertTrue((recovered / "pages" / "nix-cache-info").is_file())
        self.assertFalse((recovered / "pages" / f"{store_hash(0)}.narinfo").exists())
        self.assertTrue((recovered / "pages" / f"{store_hash(1)}.narinfo").is_file())
        plan = self.read_plan(recovered)
        self.assertEqual(plan["as_of"], "2026-07-25T12:00:00Z")
        self.assertIsNone(plan["current_release"])
        self.assertEqual(plan["delete_generation_releases"], [])
        self.assertEqual(plan["delete_nar_shard_releases"], [])
        marker_tag = self.gc_marker_tag("recovery-one")
        self.assertEqual(
            plan["create_gc_marker_releases"],
            [{"release_tag": marker_tag, "repository": REPOSITORY}],
        )

    def test_guix_percent_encoded_store_name_is_accepted(self):
        encoded_cache, _, encoded_narinfo = self.make_cache(
            "encoded-store-name",
            relative_url="nar/zstd/example-gtk%2B-3.24.51%3Fbin%3D1",
        )
        encoded_output = self.prepare(
            encoded_cache, "encoded-store-name", "2026-07-25T10:00:00Z"
        )
        self.assertTrue((encoded_output / "pages" / encoded_narinfo).is_file())

    def test_unsafe_or_inconsistent_fresh_cache_is_rejected(self):
        traversal_cache, _, _ = self.make_cache(
            "traversal", relative_url="nar/object?outside"
        )
        with self.assertRaisesRegex(HELPER.StateError, "unsafe"):
            self.prepare(traversal_cache, "traversal", "2026-07-25T10:00:00Z")

        for index, relative_url in enumerate(
            (
                "nar/zstd/object%2foutside",
                "nar/zstd/object%2boutside",
                "nar/zstd/object%3doutside",
                "nar/zstd/object%3foutside",
                "nar/zstd/object%2Foutside",
                "nar/zstd/object%2E%2Eoutside",
                "nar/zstd/object%",
                "nar/zstd/object+outside",
                "nar//zstd/object",
                "nar/./zstd/object",
                "./nar/zstd/object",
                "nar/zstd/object/",
                "nar/zstd/object/.",
            )
        ):
            unsafe_cache, _, _ = self.make_cache(
                f"unsafe-encoding-{index}", relative_url=relative_url
            )
            with self.assertRaisesRegex(HELPER.StateError, "unsafe"):
                self.prepare(
                    unsafe_cache,
                    f"unsafe-encoding-{index}",
                    "2026-07-25T10:00:00Z",
                )

        wrong_size_cache, _, _ = self.make_cache("wrong-size", file_size=999)
        with self.assertRaisesRegex(HELPER.StateError, "size mismatch"):
            self.prepare(wrong_size_cache, "wrong-size", "2026-07-25T10:00:00Z")

        unsigned_cache, _, _ = self.make_cache("unsigned", signature=b"")
        with self.assertRaisesRegex(HELPER.StateError, "Signature field"):
            self.prepare(unsigned_cache, "unsigned", "2026-07-25T10:00:00Z")

    def test_path_traversal_and_corrupt_v2_metadata_are_rejected(self):
        oversized = self.work_dir / "oversized.zip"
        with oversized.open("wb") as archive:
            archive.truncate(HELPER.MAX_METADATA_ARCHIVE_SIZE + 1)
        with self.assertRaisesRegex(HELPER.StateError, "metadata ZIP exceeds"):
            HELPER.load_prior_metadata(oversized)

        traversal = self.work_dir / "traversal.zip"
        with zipfile.ZipFile(traversal, "w") as archive:
            archive.writestr(HELPER.MANIFEST_MEMBER, b"{}")
            archive.writestr("../manifest.json", b"{}")
        with self.assertRaisesRegex(HELPER.StateError, "path traversal"):
            HELPER.load_prior_metadata(traversal)

        cache, _, _ = self.make_cache("valid-for-corruption")
        output = self.prepare(cache, "valid-for-corruption", "2026-07-25T10:00:00Z")
        original_zip = self.metadata_path(output)
        corrupt_zip = self.work_dir / "corrupt.zip"
        with zipfile.ZipFile(original_zip) as source:
            members = {
                info.filename: source.read(info.filename) for info in source.infolist()
            }
        manifest = json.loads(members[HELPER.MANIFEST_MEMBER])
        manifest["cache"]["sha256"] = "0" * 64
        members[HELPER.MANIFEST_MEMBER] = HELPER.canonical_json(manifest)
        with zipfile.ZipFile(corrupt_zip, "w") as archive:
            for name, content in sorted(members.items()):
                info = zipfile.ZipInfo(name)
                info.create_system = 3
                info.external_attr = (0o100644) << 16
                archive.writestr(info, content)
        with self.assertRaisesRegex(HELPER.StateError, "digest or size mismatch"):
            HELPER.load_prior_metadata(corrupt_zip)

    def test_pre_v2_zip_is_ignored_but_retained_conflicts_fail(self):
        legacy = self.work_dir / "legacy.zip"
        with zipfile.ZipFile(legacy, "w") as archive:
            archive.writestr("old-manifest.json", b"{}")
        self.assertIsNone(HELPER.load_prior_metadata(legacy))

        first_cache, _, _ = self.make_cache("conflict-one", payload=b"one")
        first = self.prepare(first_cache, "conflict-one", "2026-07-24T10:00:00Z")
        second_cache, _, _ = self.make_cache(
            "conflict-two", payload=b"two", nar_hash=b"sha256:different"
        )
        with self.assertRaisesRegex(HELPER.StateError, "conflicting narinfo content"):
            self.prepare(
                second_cache,
                "conflict-two",
                "2026-07-25T10:00:00Z",
                prior=[self.metadata_path(first), legacy],
            )

    def test_commits_are_full_and_release_tag_is_revision_derived(self):
        cache, _, _ = self.make_cache("revision-validation")
        output = self.work_dir / "bad-revision-output"
        guix_commit = "2" * 40
        with self.assertRaisesRegex(HELPER.StateError, "40-hex"):
            HELPER.prepare_release(
                cache_dir=cache,
                output_dir=output,
                repository=REPOSITORY,
                release_tag=HELPER.release_tag_for_commits("1" * 40, guix_commit),
                qubes_commit="1" * 39,
                guix_commit=guix_commit,
                generated_at_text="2026-07-25T10:00:00Z",
                prior_metadata=[],
                release_inventory=self.write_inventory(),
                retention_days=180,
                minimum_generations=8,
            )

        with self.assertRaisesRegex(HELPER.StateError, "does not match"):
            HELPER.prepare_release(
                cache_dir=cache,
                output_dir=output,
                repository=REPOSITORY,
                release_tag=HELPER.release_tag_for_commits("3" * 40, guix_commit),
                qubes_commit="1" * 40,
                guix_commit=guix_commit,
                generated_at_text="2026-07-25T10:00:00Z",
                prior_metadata=[],
                release_inventory=self.write_inventory(),
                retention_days=180,
                minimum_generations=8,
            )


if __name__ == "__main__":
    unittest.main()
