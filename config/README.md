# Multi-Repo Review Artifacts

This directory contains sketches for the Qubes repositories that would need
changes before a Guix community template can be published through normal Qubes
infrastructure.  These files are review aids, not release metadata.

RFC review surfaces:

- QubesOS/qubes-builderv2#245
- QubesOS/qubes-core-admin-linux#211
- QubesOS/qubes-release-configs#19

## Files

- `channels.scm`: pinned Guix channel used only while generating template
  artifacts.
- `../.guix-channel` and `../qubes/vm.scm`: this repository's Guix channel
  metadata and Qubes VM package/service module.
- `qubes-builderv2-guix.example.patch`: Builder v2 sketch for a `vm-guix`
  distribution family and a `builder-guix/builder-v2-template` content path.
- `qubes-release-configs-guix.example.patch`: release-config sketch for
  `builder-guix`, `guix`, and `guix-minimal` entries in R4.3
  `templates-community-testing`.
- `qubes-core-admin-linux-guix-vmupdate.example.patch`: central updater sketch
  for detecting Guix and reconfiguring `/etc/config.scm` with the installed
  system Guix and `/etc/qubes-guix-channel` through the normal Qubes
  updates-proxy environment.

## Patch Refresh Workflow

Refresh these sketches against fresh upstream checkouts when changing them.
Applying a sketch only proves that the review patch still lands; template
runtime evidence belongs in `VALIDATION.md`.

```sh
REPO=/path/to/qubes-template-guix

git -C /tmp/qubes-builderv2 apply \
  "$REPO/config/qubes-builderv2-guix.example.patch"
git -C /tmp/qubes-release-configs apply \
  "$REPO/config/qubes-release-configs-guix.example.patch"
git -C /tmp/qubes-core-admin-linux apply \
  "$REPO/config/qubes-core-admin-linux-guix-vmupdate.example.patch"
```

For the Builder v2 sketch, also run the focused distribution/template tests in
the patched upstream checkout:

```sh
PYTHONPATH=/tmp/qubes-builderv2 \
python -m pytest \
  /tmp/qubes-builderv2/tests/test_objects.py::test_dist_non_default_arch \
  /tmp/qubes-builderv2/tests/test_objects.py::test_dist_family \
  /tmp/qubes-builderv2/tests/test_objects.py::test_template_plugin_supports_guix \
  /tmp/qubes-builderv2/tests/test_objects.py::test_template_plugin_guix_parameters
```

For the core-admin Linux sketch, run the vmupdate tests with a matching
`qubes-core-admin-client` checkout on `PYTHONPATH`.

## Submission Rules

- Regenerate final patches from accepted upstream branches with
  `git format-patch`.
- Do not treat the release-config sketch as publishable release metadata.
- Do not claim Builder v2 acceptance until Qubes maintainers accept a Guix
  distribution/template integration path.
- Keep centralized updater claims tied to real `qubes-vm-update` runtime
  evidence from `VALIDATION.md`.
