# Multi-Repo Review Artifacts

This directory contains review sketches for the Qubes repositories that would
need to change before a Guix community template can be published through normal
Qubes infrastructure.

The `.example.patch` files include the same rationale and validation notes that
belong in the corresponding upstream commits, but they are kept as
whitespace-clean repository artifacts.  For submission, regenerate exact
email-style patches from the final upstream branches with
`git format-patch`; do not treat these checked-in sketches as a replacement for
release-owner branches.

RFC PRs opened from these sketches:

- QubesOS/qubes-builderv2#245
- QubesOS/qubes-core-admin-linux#211
- QubesOS/qubes-release-configs#19

They are review surfaces only, not acceptance or publication approval.

## Files

- `channels.scm`: pinned Guix channel used by release-quality rootfs builds and
  installed into the template as `/etc/guix/channels.scm`.
- `template.env.example`: local environment defaults for template build helpers.
- `qubes-builderv2-guix.example.patch`: sketch for
  `QubesOS/qubes-builderv2`.  It adds a `vm-guix` distribution family and points
  the template plugin at `builder-guix/builder-v2-template`.
- `qubes-os-r4.3-templates-community-guix.example.yml`: standalone fragment
  showing the intended R4.3 community template entries.
- `qubes-release-configs-guix.example.patch`: sketch for
  `QubesOS/qubes-release-configs`, adding the same `builder-guix`, `guix`, and
  `guix-minimal` entries to the R4.3 community template config.
- `qubes-core-admin-linux-guix-vmupdate.example.patch`: sketch for
  `QubesOS/qubes-core-admin-linux`.  It adds a Guix backend to the existing
  `qubes-vm-update` agent path so dom0's centralized updater can call
  `guix time-machine --branch=master -- describe` for refresh and
  `guix time-machine --branch=master -- system reconfigure /etc/config.scm`
  for the update action through the normal Qubes updates-proxy environment.
  It reports both the Guix System generation and per-output system profile
  manifest entries to the shared updater summary path.

## Sanity Checks

When local upstream checkouts exist, check the sketch patches directly:
`$REPO` is this repository checkout.

```sh
git -C /tmp/qubes-builderv2 apply --check \
  "$REPO/config/qubes-builderv2-guix.example.patch"
git -C /tmp/qubes-release-configs apply --check \
  "$REPO/config/qubes-release-configs-guix.example.patch"
git -C /tmp/qubes-core-admin-linux apply --check \
  "$REPO/config/qubes-core-admin-linux-guix-vmupdate.example.patch"
```

This is review hygiene for the sketch patches, not a test gate and not
template-runtime evidence.

Focused checks used for the Builder v2 sketch, refreshed against current
upstream sources on May 17, 2026, at upstream commit `ff36320`:

```sh
rm -rf /tmp/qubes-builderv2-current
git clone --depth 1 https://github.com/QubesOS/qubes-builderv2.git \
  /tmp/qubes-builderv2-current
git -C /tmp/qubes-builderv2-current apply \
  "$REPO/config/qubes-builderv2-guix.example.patch"
PYTHONPATH=/tmp/qubes-builderv2-current \
python -m pytest \
  /tmp/qubes-builderv2-current/tests/test_objects.py::test_dist_non_default_arch \
  /tmp/qubes-builderv2-current/tests/test_objects.py::test_dist_family \
  /tmp/qubes-builderv2-current/tests/test_objects.py::test_template_plugin_supports_guix \
  /tmp/qubes-builderv2-current/tests/test_objects.py::test_template_plugin_guix_parameters
```

That focused check passed in a fresh patched checkout with:

```text
4 passed
```

The full Builder v2 test suite was not used as evidence in this environment
because unrelated tests require Docker.  Do not claim full Builder v2
acceptance until Qubes maintainers accept the final integration path.

The release-config patch was also applied to a fresh
`/tmp/qubes-release-configs-current` checkout at upstream commit `e7ad66d` and
the resulting R4.3 community template YAML was parsed to confirm the
`builder-guix`, `guix`, and `guix-minimal` entries.

The `qubes-core-admin-linux` vmupdate patch was applied to a fresh local clone
of upstream commit `32a14bb` and its vmupdate tests were run with
`CORE_ADMIN_CLIENT` pointing at a fresh `qubes-core-admin-client` checkout
at commit `f79b7ee`:

```sh
PYTHONPATH="$CORE_ADMIN_CLIENT":. ./run-tests.sh
```

That focused upstream checkout passed with:

```text
48 passed, 1 warning
```

This validates the patch shape and unit-level central-updater selection logic.
The May 17, 2026 nested-dom0 run with this backend installed reached the Guix
backend, parsed system-profile package metadata for dom0, and logged Guix
stderr through the normal `update-guix.log` path.  A direct backend probe in
the guest printed clear `name:output -> version store-path` records.  It still
is not a substitute for a passing `qubes-vm-update --targets guix` run in a
real Qubes dom0 with a working Internet-capable update-proxy target; the remote
nested setup had only `dom0` and `guix`, and `guix time-machine --branch=master`
failed with `Git error: unexpected EOF`.

## Submission Notes

- Do not treat the release-config fragment as publishable release metadata.
  The current RFC keeps publication ownership out of the review gate; final
  release metadata must be supplied by whoever owns an accepted release.
- The Builder v2 patch is intentionally minimal.  It documents the expected shape,
  but the final upstream choice may instead be a different Guix-aware template
  plugin path accepted by Qubes maintainers.
- The release-config target should be `templates-community-testing` first, not a
  direct stable community template promotion.
- The vmupdate patch should be submitted and reviewed in
  `QubesOS/qubes-core-admin-linux`; keeping it here only documents the
  cross-repo change needed for centralized Qubes updater integration.
