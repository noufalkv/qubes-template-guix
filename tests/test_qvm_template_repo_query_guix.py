#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Unit tests for the Guix qvm-template rpm-md helper."""

import contextlib
import gzip
import importlib.util
import io
import pathlib
import sys
import types
import unittest
from unittest import mock

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
HELPER_PATH = (
    REPO_ROOT
    / "modules"
    / "qubes"
    / "files"
    / "qvm-template-repo-query-guix.py"
)
SPEC = importlib.util.spec_from_file_location("qvm_template_repo_query", HELPER_PATH)
assert SPEC is not None and SPEC.loader is not None
HELPER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HELPER)


REPO_CONFIG = """\
[qubes-templates]
name = Qubes templates
baseurl = https://example.test/r4.3/$releasever/$basearch
enabled = 1
"""

REPOMD = f"""\
<repomd xmlns="{HELPER.REPO_NS}">
  <data type="primary">
    <location href="repodata/primary.xml.gz"/>
  </data>
</repomd>
""".encode()

PRIMARY = f"""\
<metadata xmlns="{HELPER.COMMON_NS}"
          xmlns:rpm="{HELPER.RPM_NS}" packages="4">
  <package type="rpm">
    <name>qubes-template-guix</name>
    <version epoch="0" ver="4.3.0" rel="1"/>
    <size package="1234"/>
    <time build="42"/>
    <location href="Packages/q/qubes-template-guix.rpm"/>
    <url>https://www.qubes-os.org/</url>
    <summary>Guix | template</summary>
    <description>Native\nGuix template</description>
    <format><rpm:license>GPLv3+</rpm:license></format>
  </package>
  <package type="rpm">
    <name>unrelated-package</name>
    <version epoch="0" ver="1" rel="1"/>
    <size package="1"/>
    <location href="unrelated.rpm"/>
  </package>
  <package type="rpm">
    <name>qubes-template-bad-version</name>
    <version epoch="0" ver="café" rel="1"/>
    <size package="1"/>
    <location href="bad-version.rpm"/>
  </package>
  <package type="rpm">
    <name>qubes-template-bad-url</name>
    <version epoch="0" ver="1" rel="1"/>
    <size package="1"/>
    <location href="file:///etc/passwd"/>
  </package>
</metadata>
""".encode()


class PayloadTests(unittest.TestCase):
    def test_parse_payload(self):
        payload = (
            "--refresh\n"
            "--releasever=4.3\n"
            "--enablerepo=qubes-*\n"
            "qubes-template-guix*\n"
            f"---\n{REPO_CONFIG}"
        )

        options, package_spec, repo_text = HELPER.parse_payload(payload)

        self.assertEqual(
            options,
            [("releasever", "4.3"), ("enable", "qubes-*")],
        )
        self.assertEqual(package_spec, "qubes-template-guix*")
        self.assertEqual(repo_text, REPO_CONFIG)

    def test_parse_payload_rejects_ambiguous_or_malformed_input(self):
        invalid_payloads = (
            "qubes-template-guix",
            "--unknown=value\n---\n" + REPO_CONFIG,
            "--releasever=\n---\n" + REPO_CONFIG,
            "--releasever=$basearch\n---\n" + REPO_CONFIG,
            "--enablerepo=" + "x" * (HELPER.MAX_OPTION_SIZE + 1)
            + "\n---\n" + REPO_CONFIG,
            "--releasever=4.3\r--enablerepo=evil\n---\n" + REPO_CONFIG,
            "--releasever=4.3\N{LINE SEPARATOR}evil\n---\n" + REPO_CONFIG,
            "one\ntwo\n---\n" + REPO_CONFIG,
            "has whitespace\n---\n" + REPO_CONFIG,
            "ok\n---\n[repo]\nbaseurl=https://example.test/\0",
        )
        for payload in invalid_payloads:
            with self.subTest(payload=payload), self.assertRaises(
                HELPER.PayloadError
            ):
                HELPER.parse_payload(payload)

    def test_read_payload_is_bounded(self):
        with mock.patch.object(HELPER, "MAX_PAYLOAD_SIZE", 4):
            self.assertEqual(HELPER.read_payload(io.BytesIO(b"1234")), "1234")
            with self.assertRaisesRegex(HELPER.PayloadError, "exceeds"):
                HELPER.read_payload(io.BytesIO(b"12345"))
            with self.assertRaisesRegex(HELPER.PayloadError, "valid UTF-8"):
                HELPER.read_payload(io.BytesIO(b"\xff"))

    def test_payload_matches_upstream_wrapper_shape(self):
        payload = (
            "--releasever=4.3\n"
            "qubes-template-guix\n"
            "---\n"
            + REPO_CONFIG
            + "\n###!Q!BEGIN-QUBES-WRAPPER!Q!###\n"
            "#/etc/qubes/repo-templates/keys/key.asc\n"
            "#ZmFrZQ==\n"
            "###!Q!END-QUBES-WRAPPER!Q!###\n"
        )

        options, package_spec, repo_text = HELPER.parse_payload(payload)

        self.assertEqual(options, [("releasever", "4.3")])
        self.assertEqual(package_spec, "qubes-template-guix")
        self.assertEqual(
            HELPER.parse_repo_config(repo_text).sections(),
            ["qubes-templates"],
        )

    def test_parse_repo_config_requires_a_section(self):
        with self.assertRaises(HELPER.PayloadError):
            HELPER.parse_repo_config("# comments only\n")


class RepositoryTests(unittest.TestCase):
    def setUp(self):
        HELPER._diagnostic_output_size = 0
        HELPER._metadata_deadline = None

    def test_command_output_is_bounded_and_checks_exit_status(self):
        self.assertEqual(
            HELPER.command_output_limited(
                [sys.executable, "-c", "print('ok', end='')"], 2
            ),
            b"ok",
        )
        with self.assertRaises(HELPER.RepositoryError):
            HELPER.command_output_limited(
                [sys.executable, "-c", "print('too large', end='')"], 3
            )
        with self.assertRaisesRegex(HELPER.RepositoryError, "status 7"):
            HELPER.command_output_limited(
                [sys.executable, "-c", "raise SystemExit(7)"], 1
            )

    def test_command_failure_does_not_expose_command_url(self):
        process = mock.Mock()
        process.stdout = io.BytesIO()
        process.wait.return_value = 22
        secret_url = "https://user:secret@example.test/metadata"
        with (
            mock.patch.object(HELPER.subprocess, "Popen", return_value=process),
            self.assertRaises(HELPER.RepositoryError) as raised,
        ):
            HELPER.command_output_limited(["curl", secret_url], 1)

        self.assertNotIn(secret_url, str(raised.exception))
        self.assertNotIn("secret", str(raised.exception))

    def test_command_output_limit_terminates_and_reaps_child(self):
        process = mock.Mock()
        process.stdout = mock.Mock()
        process.stdout.read.return_value = b"too large"
        process.poll.return_value = None
        with (
            mock.patch.object(
                HELPER.subprocess, "Popen", return_value=process
            ) as popen,
            self.assertRaises(HELPER.RepositoryError),
        ):
            HELPER.command_output_limited(["producer"], 3)

        self.assertIs(
            popen.call_args.kwargs["stderr"], HELPER.subprocess.DEVNULL
        )
        process.kill.assert_called_once_with()
        process.wait.assert_called_once_with()
        process.stdout.close.assert_called_once_with()

    def test_template_download_stream_is_exactly_size_bounded(self):
        process = mock.Mock()
        process.stdout = io.BytesIO(b"1234")
        process.wait.return_value = 0
        target = io.BytesIO()
        stdout = types.SimpleNamespace(buffer=target)
        with (
            mock.patch.object(HELPER.subprocess, "Popen", return_value=process),
            mock.patch.object(HELPER.sys, "stdout", stdout),
        ):
            self.assertEqual(
                HELPER.curl_to_stdout("https://example.test/template.rpm", 4),
                0,
            )
        self.assertEqual(target.getvalue(), b"1234")

        oversized = mock.Mock()
        oversized.stdout = io.BytesIO(b"12345")
        oversized.poll.return_value = None
        with (
            mock.patch.object(HELPER.subprocess, "Popen", return_value=oversized),
            mock.patch.object(
                HELPER.sys,
                "stdout",
                types.SimpleNamespace(buffer=io.BytesIO()),
            ),
            self.assertRaisesRegex(HELPER.RepositoryError, "exceeds"),
        ):
            HELPER.curl_to_stdout("https://example.test/template.rpm", 4)
        oversized.kill.assert_called_once_with()
        oversized.wait.assert_called_once_with()

    def test_curl_commands_disable_config_and_url_globbing(self):
        metadata_url = "https://example.test/metadata[1-3].xml"
        with mock.patch.object(
            HELPER, "command_output_limited", return_value=b"metadata"
        ) as command_output:
            self.assertEqual(HELPER.curl_bytes(metadata_url), b"metadata")

        metadata_command = command_output.call_args.args[0]
        self.assertEqual(
            metadata_command[:3], ["curl", "--disable", "--globoff"]
        )
        self.assertEqual(metadata_command[-1], metadata_url)

        package_url = "https://example.test/template{one,two}.rpm"
        process = mock.Mock()
        process.stdout = io.BytesIO(b"x")
        process.wait.return_value = 0
        with (
            mock.patch.object(HELPER.subprocess, "Popen", return_value=process)
            as popen,
            mock.patch.object(
                HELPER.sys,
                "stdout",
                types.SimpleNamespace(buffer=io.BytesIO()),
            ),
        ):
            self.assertEqual(HELPER.curl_to_stdout(package_url, 1), 0)

        package_command = popen.call_args.args[0]
        self.assertEqual(
            package_command[:3], ["curl", "--disable", "--globoff"]
        )
        self.assertEqual(package_command[-1], package_url)

    def test_validate_url_accepts_only_absolute_http_urls(self):
        for url in ("https://example.test/repo", "http://example.test/repo"):
            with self.subTest(url=url):
                self.assertEqual(HELPER.validate_url(url), url)

        for url in (
            "file:///etc/passwd",
            "ftp://example.test/repo",
            "/relative/repo",
            "https:///missing-host",
            "https://[invalid-ipv6/repo",
        ):
            with self.subTest(url=url), self.assertRaises(
                HELPER.RepositoryError
            ):
                HELPER.validate_url(url)

    def test_metadata_deadline_stops_further_fetches(self):
        HELPER._metadata_deadline = HELPER.time.monotonic() - 1
        with (
            mock.patch.object(HELPER.subprocess, "Popen") as popen,
            self.assertRaisesRegex(HELPER.RepositoryError, "timed out"),
        ):
            HELPER.curl_bytes("https://example.test/repomd.xml")
        popen.assert_not_called()

    def test_repo_options_and_variable_expansion(self):
        config = HELPER.parse_repo_config(
            REPO_CONFIG
            + "\n[disabled]\nbaseurl=https://disabled.test/\nenabled=0\n"
        )
        self.assertTrue(HELPER.repo_enabled("qubes-templates", config, []))
        self.assertFalse(HELPER.repo_enabled("disabled", config, []))
        self.assertTrue(
            HELPER.repo_enabled(
                "disabled", config, [("enable", "disabled")]
            )
        )
        self.assertFalse(
            HELPER.repo_enabled(
                "qubes-templates", config, [("repoid", "disabled")]
            )
        )
        self.assertTrue(
            HELPER.repo_enabled(
                "disabled", config, [("repoid", "disabled")]
            )
        )
        self.assertTrue(
            HELPER.repo_enabled(
                "disabled",
                config,
                [("disable", "disabled"), ("repoid", "disabled")],
            )
        )
        self.assertEqual(
            HELPER.repo_baseurls("qubes-templates", config, "4.3"),
            ["https://example.test/r4.3/4.3/x86_64"],
        )

    def test_repository_config_and_baseurl_counts_are_bounded(self):
        with (
            mock.patch.object(HELPER, "MAX_REPOSITORIES", 1),
            self.assertRaisesRegex(HELPER.PayloadError, "sections"),
        ):
            HELPER.parse_repo_config(
                "[one]\nenabled=0\n[two]\nenabled=0\n"
            )

        config = HELPER.parse_repo_config(
            "[repo]\nbaseurl=https://one.test/ https://two.test/\n"
        )
        with (
            mock.patch.object(HELPER, "MAX_REPOSITORY_URLS", 1),
            self.assertRaisesRegex(HELPER.RepositoryError, "base URLs"),
        ):
            HELPER.repo_baseurls("repo", config, "4.3")

    def test_generic_metalink_candidates_are_truncated_to_attempt_budget(self):
        metalink = b"""\
<metalink>
  <url>file:///local/repo/repodata/repomd.xml</url>
  <url>ftp://unsupported.test/repo/repodata/repomd.xml</url>
  <url>https://one.test/repo/repodata/repomd.xml</url>
  <url>https://two.test/repo/repodata/repomd.xml</url>
  <url>https://three.test/repo/repodata/repomd.xml</url>
</metalink>
"""
        config = HELPER.parse_repo_config(
            "[repo]\nmetalink=https://index.test/metalink.xml\n"
        )
        with (
            mock.patch.object(HELPER, "curl_bytes", return_value=metalink),
            mock.patch.object(HELPER, "MAX_REPOSITORY_URLS", 3),
            mock.patch.object(HELPER, "MAX_REPOSITORY_ATTEMPTS", 2),
        ):
            baseurls = HELPER.repo_baseurls("repo", config, "4.3")

        self.assertEqual(
            baseurls,
            ["https://one.test/repo", "https://two.test/repo"],
        )

    def test_canonical_metalink_uses_mirrors_with_origin_fallback(self):
        metalink_url = (
            "https://yum.qubes-os.org/r4.3/templates-itl/"
            "repodata/repomd.xml.metalink"
        )
        metalink = b"""\
<metalink>
  <url>https://mirror.test/qubes/repodata/repomd.xml</url>
</metalink>
"""
        config = HELPER.parse_repo_config(
            f"[repo]\nmetalink={metalink_url}\n"
        )

        with mock.patch.object(
            HELPER, "curl_bytes", return_value=metalink
        ) as curl_bytes:
            self.assertEqual(
                HELPER.repo_baseurls("repo", config, "4.3"),
                [
                    "https://mirror.test/qubes",
                    "https://yum.qubes-os.org/r4.3/templates-itl",
                ],
            )
        curl_bytes.assert_called_once_with(
            metalink_url, HELPER.MAX_REPOSITORY_INDEX_SIZE
        )

        with mock.patch.object(
            HELPER,
            "curl_bytes",
            side_effect=HELPER.RepositoryError("index unavailable"),
        ):
            self.assertEqual(
                HELPER.repo_baseurls("repo", config, "4.3"),
                ["https://yum.qubes-os.org/r4.3/templates-itl"],
            )

    def test_parse_packages_filters_and_normalizes_metadata(self):
        responses = (REPOMD, gzip.compress(PRIMARY))
        with mock.patch.object(
            HELPER, "curl_bytes", side_effect=responses
        ) as curl_bytes:
            packages = list(HELPER.parse_packages(
                "qubes-templates", "https://example.test/repository"
            ))

        self.assertEqual(
            curl_bytes.call_args_list[0].args[1],
            HELPER.MAX_REPOSITORY_INDEX_SIZE,
        )
        self.assertEqual(len(packages), 1)
        package = packages[0]
        self.assertEqual(package["name"], "qubes-template-guix")
        self.assertEqual(package["version"], "4.3.0")
        self.assertEqual(package["repoid"], "qubes-templates")
        self.assertEqual(
            package["download_url"],
            "https://example.test/repository/Packages/q/"
            "qubes-template-guix.rpm",
        )
        self.assertTrue(HELPER.package_matches(package, "qubes-template-*"))
        self.assertTrue(HELPER.package_matches(package, "qubes-template-guix-4.3.0"))
        self.assertFalse(HELPER.package_matches(package, "qubes-template-debian*"))

    def test_structural_fields_match_dom0_wire_grammar(self):
        package = {
            "name": "qubes-template-guix",
            "epoch": "0",
            "version": "4.3.0",
            "release": "1",
            "repoid": "qubes-templates",
            "size": "1234",
            "buildtime": "42",
            "license": "GPLv3+",
        }
        self.assertTrue(HELPER.valid_package_fields(package))

        invalid_updates = (
            ("name", "qubes-template-é"),
            ("epoch", "٠"),
            ("version", "1^git"),
            ("repoid", "repo name"),
            ("size", "-1"),
            ("size", str(HELPER.MAX_PACKAGE_SIZE + 1)),
            ("buildtime", "not-a-time"),
            ("buildtime", str(HELPER.MAX_BUILD_TIMESTAMP + 1)),
            ("license", "GPLv3+ and MIT"),
        )
        for field, value in invalid_updates:
            with self.subTest(field=field, value=value):
                candidate = dict(package)
                candidate[field] = value
                self.assertFalse(HELPER.valid_package_fields(candidate))

    def test_decompression_rejects_expansion_beyond_limit(self):
        with (
            mock.patch.object(HELPER, "MAX_UNCOMPRESSED_METADATA_SIZE", 4),
            self.assertRaisesRegex(HELPER.RepositoryError, "exceeds"),
        ):
            HELPER.decompress_metadata(
                "https://example.test/primary.xml.gz",
                gzip.compress(b"12345"),
            )

    def test_decompression_rejects_corrupt_gzip_as_repository_error(self):
        truncated = gzip.compress(b"metadata")[:-4]
        with self.assertRaisesRegex(HELPER.RepositoryError, "invalid gzip"):
            HELPER.decompress_metadata(
                "https://example.test/primary.xml.gz", truncated
            )

    def test_decompression_uses_url_path_when_query_is_present(self):
        self.assertEqual(
            HELPER.decompress_metadata(
                "https://example.test/primary.xml.gz?token=value",
                gzip.compress(b"metadata"),
            ),
            b"metadata",
        )

    def test_unknown_xml_encodings_are_controlled_repository_errors(self):
        unknown_encoding = (
            b'<?xml version="1.0" encoding="x-unknown"?><metadata/>'
        )
        with (
            self.assertRaisesRegex(HELPER.RepositoryError, "repository index"),
            mock.patch.object(
                HELPER, "curl_bytes", return_value=unknown_encoding
            ),
        ):
            HELPER.primary_metadata_url("https://example.test/repository")

        with self.assertRaisesRegex(HELPER.RepositoryError, "primary repository"):
            list(HELPER.iter_package_elements(unknown_encoding))

    def test_metadata_fields_and_package_count_are_bounded_during_parse(self):
        long_summary = "x" * (HELPER.MAX_FIELD_SIZE + 100)
        primary = f"""\
<metadata xmlns="{HELPER.COMMON_NS}" xmlns:rpm="{HELPER.RPM_NS}">
  <package type="rpm">
    <name>qubes-template-guix</name>
    <version epoch="0" ver="4.3.0" rel="1"/>
    <size package="1234"/>
    <time build="42"/>
    <location href="template.rpm"/>
    <summary>{long_summary}</summary>
    <format><rpm:license>GPLv3+</rpm:license></format>
  </package>
</metadata>
""".encode()
        responses = (REPOMD, gzip.compress(primary))
        with mock.patch.object(HELPER, "curl_bytes", side_effect=responses):
            package = next(HELPER.parse_packages(
                "qubes-templates", "https://example.test/repository"
            ))
        self.assertEqual(len(package["summary"]), HELPER.MAX_FIELD_SIZE)

        responses = (REPOMD, gzip.compress(primary))
        with (
            mock.patch.object(HELPER, "curl_bytes", side_effect=responses),
            mock.patch.object(HELPER, "MAX_REPOSITORY_PACKAGES", 0),
            self.assertRaisesRegex(HELPER.RepositoryError, "too many"),
        ):
            list(HELPER.parse_packages(
                "qubes-templates", "https://example.test/repository"
            ))

        unrelated = f"""\
<metadata xmlns="{HELPER.COMMON_NS}">
  <package/><package/>
</metadata>
""".encode()
        responses = (REPOMD, gzip.compress(unrelated))
        with (
            mock.patch.object(HELPER, "curl_bytes", side_effect=responses),
            mock.patch.object(HELPER, "MAX_REPOSITORY_PACKAGES", 1),
            self.assertRaisesRegex(HELPER.RepositoryError, "package records"),
        ):
            list(HELPER.parse_packages(
                "qubes-templates", "https://example.test/repository"
            ))

        with (
            mock.patch.object(HELPER, "MAX_METADATA_ELEMENTS", 1),
            self.assertRaisesRegex(HELPER.RepositoryError, "XML elements"),
        ):
            list(HELPER.iter_package_elements(unrelated))

    def test_bad_repository_does_not_abort_other_repositories(self):
        config = HELPER.parse_repo_config(
            REPO_CONFIG
            + "\n[second]\nbaseurl=https://second.test/\nenabled=1\n"
        )
        expected = {
            "name": "qubes-template-guix",
            "download_url": "https://second.test/template.rpm",
            "download_reference": "template.rpm",
        }

        def parse_repository(repoid, _baseurl):
            if repoid == "qubes-templates":
                raise gzip.BadGzipFile("bad")
            return [expected]

        with (
            mock.patch.object(
                HELPER,
                "repo_baseurls",
                side_effect=lambda section, *_args: [
                    f"https://{section}.test"
                ],
            ),
            mock.patch.object(
                HELPER, "parse_packages", side_effect=parse_repository
            ),
            contextlib.redirect_stderr(io.StringIO()) as stderr,
        ):
            packages = list(HELPER.iter_enabled_packages(config, []))

        self.assertEqual(packages, [expected])
        self.assertIn("WARNING: failed to query", stderr.getvalue())

    def test_all_repository_resolution_errors_are_reported(self):
        config = HELPER.parse_repo_config(REPO_CONFIG)
        with (
            mock.patch.object(
                HELPER, "repo_baseurls", side_effect=OSError("spawn failed")
            ),
            contextlib.redirect_stderr(io.StringIO()) as stderr,
            self.assertRaisesRegex(
                HELPER.RepositoryError, "all enabled repositories failed"
            ),
        ):
            list(HELPER.iter_enabled_packages(config, []))

        self.assertIn("WARNING: failed to resolve", stderr.getvalue())

    def test_unexpected_runtime_error_is_not_hidden_as_repository_failure(self):
        config = HELPER.parse_repo_config(REPO_CONFIG)
        with (
            mock.patch.object(
                HELPER,
                "repo_baseurls",
                return_value=["https://example.test/repository"],
            ),
            mock.patch.object(
                HELPER,
                "parse_packages",
                side_effect=RuntimeError("programming defect"),
            ),
            self.assertRaisesRegex(RuntimeError, "programming defect"),
        ):
            list(HELPER.iter_enabled_packages(config, []))

    def test_repository_attempt_count_is_bounded(self):
        config = HELPER.parse_repo_config(
            REPO_CONFIG
            + "\n[second]\nbaseurl=https://second.test/\nenabled=1\n"
        )
        with (
            mock.patch.object(
                HELPER,
                "repo_baseurls",
                side_effect=lambda section, *_args: [
                    f"https://{section}.test/"
                ],
            ),
            mock.patch.object(HELPER, "parse_packages", return_value=[])
            as parse_packages,
            mock.patch.object(HELPER, "MAX_REPOSITORY_ATTEMPTS", 1),
            contextlib.redirect_stderr(io.StringIO()) as stderr,
            self.assertRaisesRegex(
                HELPER.RepositoryError,
                "before all enabled repositories were queried",
            ),
        ):
            list(HELPER.iter_enabled_packages(config, []))

        self.assertEqual(parse_packages.call_count, 1)
        self.assertIn("attempt limit", stderr.getvalue())

    def test_query_sanitizes_untrusted_metadata_fields(self):
        config = HELPER.parse_repo_config(REPO_CONFIG)
        package = {
            "name": "qubes-template-guix",
            "epoch": "0",
            "version": "4.3.0",
            "release": "1",
            "repoid": "qubes-templates",
            "size": "1234",
            "buildtime": "42",
            "license": "GPLv3+",
            "url": "https://www.qubes-os.org/",
            "summary": "café | with separator\x07",
            "description": "two\nlines",
            "download_url": "https://example.test/template.rpm",
        }
        with (
            mock.patch.object(
                HELPER, "iter_enabled_packages", return_value=iter((package,))
            ),
            contextlib.redirect_stdout(io.StringIO()) as stdout,
        ):
            self.assertEqual(HELPER.query(config, [], "*"), 0)

        row = stdout.getvalue()
        self.assertIn("caf? with separator", row)
        self.assertIn("two lines", row)
        self.assertEqual(row.count("\n"), 1)

    def test_query_output_is_bounded(self):
        config = HELPER.parse_repo_config(REPO_CONFIG)
        package = {
            "name": "qubes-template-guix",
            "epoch": "0",
            "version": "4.3.0",
            "release": "1",
            "repoid": "qubes-templates",
            "size": "1234",
            "buildtime": "42",
            "license": "GPLv3+",
            "url": "https://www.qubes-os.org/",
            "summary": "summary",
            "description": "description",
            "download_url": "https://example.test/template.rpm",
        }
        with (
            mock.patch.object(
                HELPER, "iter_enabled_packages", return_value=iter((package,))
            ),
            mock.patch.object(HELPER, "MAX_QUERY_OUTPUT_SIZE", 10),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()) as stderr,
        ):
            self.assertEqual(HELPER.query(config, [], "*"), 1)
        self.assertIn("query output exceeds", stderr.getvalue())

    def test_download_reports_unsafe_metadata_url(self):
        config = HELPER.parse_repo_config(REPO_CONFIG)
        package = {
            "name": "qubes-template-guix",
            "epoch": "0",
            "version": "4.3.0",
            "release": "1",
            "repoid": "qubes-templates",
            "size": "1234",
            "buildtime": "42",
            "license": "GPLv3+",
            "url": "https://www.qubes-os.org/",
            "summary": "summary",
            "description": "description",
            "download_url": "file:///etc/passwd",
        }
        with (
            mock.patch.object(
                HELPER, "iter_enabled_packages", return_value=iter((package,))
            ),
            contextlib.redirect_stderr(io.StringIO()) as stderr,
        ):
            self.assertEqual(
                HELPER.download(config, [], "qubes-template-guix"), 1
            )
        self.assertIn("template download failed", stderr.getvalue())

    def test_download_retries_zero_byte_failures_on_other_mirrors(self):
        config = HELPER.parse_repo_config(REPO_CONFIG)
        package = {
            "name": "qubes-template-guix",
            "epoch": "0",
            "version": "4.3.0",
            "release": "1",
            "repoid": "qubes-templates",
            "size": "1234",
            "buildtime": "42",
            "license": "GPLv3+",
            "url": "https://www.qubes-os.org/",
            "summary": "summary",
            "description": "description",
            "download_url": "https://one.test/template.rpm",
            "download_urls": (
                "https://one.test/template.rpm",
                "https://two.test/template.rpm",
            ),
        }
        with (
            mock.patch.object(
                HELPER, "iter_enabled_packages", return_value=iter((package,))
            ),
            mock.patch.object(
                HELPER,
                "curl_to_stdout",
                side_effect=(HELPER.DownloadError("curl exited", 0), 0),
            ) as curl_to_stdout,
            contextlib.redirect_stderr(io.StringIO()) as stderr,
        ):
            self.assertEqual(
                HELPER.download(config, [], "qubes-template-guix"), 0
            )

        self.assertEqual(
            [call.args[0] for call in curl_to_stdout.call_args_list],
            [
                "https://one.test/template.rpm",
                "https://two.test/template.rpm",
            ],
        )
        self.assertIn("download attempt failed", stderr.getvalue())

    def test_download_does_not_concatenate_after_a_partial_transfer(self):
        config = HELPER.parse_repo_config(REPO_CONFIG)
        package = {
            "name": "qubes-template-guix",
            "epoch": "0",
            "version": "4.3.0",
            "release": "1",
            "repoid": "qubes-templates",
            "size": "1234",
            "buildtime": "42",
            "license": "GPLv3+",
            "url": "https://www.qubes-os.org/",
            "summary": "summary",
            "description": "description",
            "download_url": "https://one.test/template.rpm",
            "download_urls": (
                "https://one.test/template.rpm",
                "https://two.test/template.rpm",
            ),
        }
        with (
            mock.patch.object(
                HELPER, "iter_enabled_packages", return_value=iter((package,))
            ),
            mock.patch.object(
                HELPER,
                "curl_to_stdout",
                side_effect=HELPER.DownloadError("curl exited", 3),
            ) as curl_to_stdout,
            contextlib.redirect_stderr(io.StringIO()) as stderr,
        ):
            self.assertEqual(
                HELPER.download(config, [], "qubes-template-guix"), 1
            )

        curl_to_stdout.assert_called_once_with(
            "https://one.test/template.rpm", 1234
        )
        self.assertIn("template download failed", stderr.getvalue())

    def test_download_attempts_are_bounded_across_matching_records(self):
        config = HELPER.parse_repo_config(REPO_CONFIG)
        package = {
            "name": "qubes-template-guix",
            "epoch": "0",
            "version": "4.3.0",
            "release": "1",
            "repoid": "qubes-templates",
            "size": "1234",
            "buildtime": "42",
            "license": "GPLv3+",
            "url": "https://www.qubes-os.org/",
            "summary": "summary",
            "description": "description",
            "download_url": "https://example.test/template.rpm",
        }
        packages = iter(
            dict(package, download_url=f"https://{index}.test/template.rpm")
            for index in range(HELPER.MAX_DOWNLOAD_ATTEMPTS + 2)
        )
        with (
            mock.patch.object(
                HELPER, "iter_enabled_packages", return_value=packages
            ),
            mock.patch.object(
                HELPER,
                "curl_to_stdout",
                side_effect=HELPER.DownloadError("curl exited", 0),
            ) as curl_to_stdout,
            contextlib.redirect_stderr(io.StringIO()) as stderr,
        ):
            self.assertEqual(HELPER.download(config, [], "*"), 1)

        self.assertEqual(
            curl_to_stdout.call_count, HELPER.MAX_DOWNLOAD_ATTEMPTS
        )
        self.assertIn("download attempt limit reached", stderr.getvalue())

    def test_diagnostics_are_ascii_and_have_a_total_byte_bound(self):
        HELPER._diagnostic_output_size = 0
        with contextlib.redirect_stderr(io.StringIO()) as stderr:
            for _index in range(20):
                HELPER.warning("token=secret\n" + "é" * 10_000)

        output = stderr.getvalue()
        self.assertLessEqual(
            len(output.encode("ascii")), HELPER.MAX_DIAGNOSTIC_OUTPUT_SIZE
        )
        self.assertNotIn("\né", output)

    def test_warning_budget_reserves_space_for_terminal_error(self):
        HELPER._diagnostic_output_size = 0
        with contextlib.redirect_stderr(io.StringIO()) as stderr:
            for _index in range(20):
                HELPER.warning("repository failed: " + "x" * 1000)
            HELPER.error("all enabled repositories failed")

        output = stderr.getvalue()
        self.assertLessEqual(
            len(output.encode("ascii")), HELPER.MAX_DIAGNOSTIC_OUTPUT_SIZE
        )
        self.assertIn("ERROR: all enabled repositories failed", output)


class MainTests(unittest.TestCase):
    def test_main_reports_bad_payload_without_traceback(self):
        stderr = io.StringIO()
        with (
            mock.patch.object(sys, "argv", [str(HELPER_PATH), "query"]),
            mock.patch.object(sys, "stdin", io.StringIO("missing delimiter")),
            contextlib.redirect_stderr(stderr),
        ):
            self.assertEqual(HELPER.main(), 1)

        self.assertIn("invalid template repository request", stderr.getvalue())

    def test_main_fails_when_all_enabled_repository_queries_fail(self):
        payload = "*\n---\n" + REPO_CONFIG
        stderr = io.StringIO()
        with (
            mock.patch.object(sys, "argv", [str(HELPER_PATH), "query"]),
            mock.patch.object(sys, "stdin", io.StringIO(payload)),
            mock.patch.object(
                HELPER,
                "parse_packages",
                side_effect=HELPER.RepositoryError("repository offline"),
            ),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(stderr),
        ):
            self.assertEqual(HELPER.main(), 1)

        self.assertIn("WARNING: failed to query", stderr.getvalue())
        self.assertIn("all enabled repositories failed", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
