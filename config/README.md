# Multi-Repo Review Artifacts

This directory contains review sketches for the Qubes repositories that would
need to change before a Guix community template can be published through normal
Qubes infrastructure.

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

## Sanity Checks

When local upstream checkouts exist, check the sketch patches directly:

```sh
git -C /tmp/qubes-builderv2 apply --check \
  /home/user/guix/config/qubes-builderv2-guix.example.patch
git -C /tmp/qubes-release-configs apply --check \
  /home/user/guix/config/qubes-release-configs-guix.example.patch
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
  /home/user/guix/config/qubes-builderv2-guix.example.patch
PYTHONPATH=/tmp/qubes-builderv2-current \
python -m pytest \
  /tmp/qubes-builderv2-current/tests/test_objects.py::test_dist \
  /tmp/qubes-builderv2-current/tests/test_objects.py::test_dist_family \
  /tmp/qubes-builderv2-current/tests/test_objects.py::test_template_plugin_supports_guix
```

That focused check passed in a fresh patched checkout with:

```text
3 passed in 0.12s
```

The full Builder v2 test suite was not used as evidence in this environment
because unrelated tests require Docker.  Do not claim full Builder v2
acceptance until Qubes maintainers accept the final integration path.

The release-config patch was also applied to a fresh
`/tmp/qubes-release-configs-current` checkout at upstream commit `e7ad66d` and
the resulting R4.3 community template YAML was parsed to confirm the
`builder-guix`, `guix`, and `guix-minimal` entries.

## Submission Notes

- Do not submit the release-config fragment or patch with `<OWNER>` or
  `<MAINTAINER_GPG_FINGERPRINT>` placeholders.
- The Builder v2 patch is intentionally minimal.  It proves the expected shape,
  but the final upstream choice may instead be a different Guix-aware template
  plugin path accepted by Qubes maintainers.
- The release-config target should be `templates-community-testing` first, not a
  direct stable community template promotion.
