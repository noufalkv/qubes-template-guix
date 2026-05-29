# Contributing

This repository is prepared for Qubes community-template review.  Contributions
should keep the review surface small, explicit, and reproducible.

## Public History

- Submit a clean review branch.
- Do not publish local backup refs, generated images, RPMs, cache directories,
  or obsolete experiment history.
- Keep commits reviewable.  If the public branch is a single initial import,
  the commit message must summarize scope, validation, and explicit blockers.
- Any later changes should be split by review area:
  packaging/source pins, Shepherd services, image/RPM tooling, Builder/release
  integration, validation harnesses, and documentation.

Before asking Qubes to publish the template, replace publication placeholders
in draft/config files and add the release-owner metadata requested by the Qubes
publication path at that stage.  Do not add that metadata to draft RFC comments.

## Publication Hygiene

Before pushing or opening any upstream discussion, verify that the review branch
contains only source, review documentation, and reproducible build scripts:

```sh
git status --short
git ls-files
```

Keep local builder paths, provider regions, generated RPMs, root images, logs,
API credentials, temporary build directories, and local instance names out of
commits.  In-guest Qubes paths such as `/home/user` are expected in runtime
diagnostics.  Test RPMs may be attached to a review issue for convenience, but
the public repository must let reviewers reproduce them from the final source
branch or release object.

## Required Local Contract Checks

Run before asking for review:

```sh
make check
```

Validation evidence must exercise generated artifacts, Guix system records,
qvm-template behavior, dom0 behavior, or openQA.

Run the Builder v2 and release-config sketch checks directly in fresh upstream
checkouts when changing files under `config/`.  For release candidates, add
runtime evidence: rootfs activation, qvm-template lifecycle, RPM-mode openQA,
and live TemplateVM/AppVM smoke.

When changing pinned Qubes sources, run `./scripts/check-qubes-pins.sh`
directly and document the result as source-pin information only.  It is not a
template behavior test.

For the Builder v2 sketch:

```sh
rm -rf /tmp/qubes-builderv2-test
git clone --depth 1 https://github.com/QubesOS/qubes-builderv2.git \
  /tmp/qubes-builderv2-test
git -C /tmp/qubes-builderv2-test apply \
  "$PWD/config/qubes-builderv2-guix.example.patch"
cd /tmp/qubes-builderv2-test
PYTHONPATH="$PWD" \
  python -m pytest \
    tests/test_objects.py::test_dist_non_default_arch \
    tests/test_objects.py::test_dist_family \
    tests/test_objects.py::test_template_plugin_supports_guix \
    tests/test_objects.py::test_template_plugin_guix_parameters
```

For the release-config sketch, apply
`config/qubes-release-configs-guix.example.patch` to a fresh
`qubes-release-configs` checkout and parse the resulting R4.3 community
template YAML.  Record the command and result in `VALIDATION.md` only when
review discussion relies on it.

## Release Evidence

Do not ask Qubes to publish a template until `VALIDATION.md` contains fresh
evidence from the final public branch or release object.  Contributors should
add commands, logs, artifact hashes, openQA job IDs, and qvm-template results
there instead of copying partial checklists into review comments.

## Review Rules

- Explain every non-obvious Guix/Qubes adaptation in `ADAPTATION_INVENTORY.md`
  or `SECURITY.md`.
- Keep openQA-specific behavior in the dedicated `guix_template.pm` job unless
  a reviewer asks for integration with the broader upstream openQA suite.
- Do not replace standard Qubes behavior with Guix-specific policy unless the
  reason is documented and covered by validation.
- Keep placeholders such as `<OWNER>`, `<REPOSITORY>`, and `<NAME>` only in
  draft/config or review-process files that explicitly mark them as
  non-publishable release metadata, or in tests that validate those
  draft/config placeholders.
- RFC/review PRs can be opened before there is a release owner, but publication
  requests need an agreed release owner for the review branch.

## Multi-Repo Flow

Use this order:

1. Publish a clean template review branch.
2. Write reviewer updates from current `VALIDATION.md` evidence only; do not
   reuse stale comment drafts.
3. Discuss or submit the Builder v2 Guix distribution path.
4. Discuss or submit the `qubes-core-admin-linux` Guix vmupdate backend if
   centralized Qubes updater support is part of the requested scope.
5. Keep release-config entries as RFC/review-only until the Builder path is
   accepted and publication evidence is ready.
6. Refresh all release evidence from the final release branch before asking for
   `templates-community-testing` publication.
