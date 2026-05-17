# Contributing

This repository is prepared for Qubes community-template review.  Contributions
should keep the review surface small, explicit, and reproducible.

## Public History

- Submit a clean branch with signed commits or a signed release tag.
- Do not publish local backup refs, generated images, RPMs, cache directories,
  or obsolete experiment history.
- Keep commits reviewable.  If the public branch is a single initial import,
  the commit message must summarize scope, validation, and explicit blockers.
- Any later changes should be split by review area:
  packaging/source pins, Shepherd services, image/RPM tooling, Builder/release
  integration, validation harnesses, and documentation.

## Required Local Contract Checks

Run before asking for review:

```sh
make check
```

Do not commit or submit tests that only grep source text, compare patch shape,
or inspect whether code "looks right".  Source-only checks are not upstream
evidence and should not be part of the public test suite.  Local tests should
execute build hooks, create or inspect generated artifacts, or validate
Qubes-visible template contracts.  Grep or comparison checks are acceptable
only when they inspect generated artifacts from the code path under test, such
as extracted RPM metadata or files read back from a generated root image.

When Guix is available, also run:

```sh
make guix-system-contract-check
```

This is a real Guix record check, not a source-text check.  It instantiates both
template variants and verifies Qubes-visible defaults such as `/dev/xvdc1`
swap, passwordless sudo, default privileged programs, required Qubes services,
and `meminfo-writer` defaults.

Run the Builder v2 and release-config sketch checks directly in fresh upstream
checkouts when changing files under `config/`.  Treat `make check`, rootfs
activation, RPM lifecycle, and dom0/openQA runs as the evidence that the
template behavior works.

Keep source-only checks out of the repository test suite and the upstream
evidence path.  Do not add static source-shape or patch-shape scripts to this
repository as tests, `make` targets, validation logs, or proof that the
template works.  Formatting and parser commands may still be run manually while
preparing a branch, but upstream evidence must come from artifacts, Guix
system records, dom0 behavior, or openQA.

When changing pinned Qubes sources, run `./scripts/check-qubes-pins.sh`
directly and document the result as source provenance only.  It is not a
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
    tests/test_objects.py::test_dist \
    tests/test_objects.py::test_dist_family \
    tests/test_objects.py::test_template_plugin_supports_guix
```

For the release-config sketch, apply
`config/qubes-release-configs-guix.example.patch` to a fresh
`qubes-release-configs` checkout and parse the resulting R4.3 community
template YAML.  The exact validation snippet is recorded in `VALIDATION.md`.

## Release Evidence

Do not ask Qubes to publish a template until `VALIDATION.md` contains fresh
evidence from the signed public branch for:

- normal and minimal rootfs builds.
- normal and minimal image inspection.
- normal and minimal writable-root activation tests.
- normal and minimal qvm-template-compatible RPM builds.
- RPM-mode openQA for both variants.
- qvm-template install, reinstall, remove, upgrade, and downgrade.
- TemplateVM/AppVM smoke for QubesDB, qrexec, GUI/appmenus, shutdown,
  private-volume persistence, `/dev/xvdc1` swap activation, and guest-side
  `meminfo-writer` startup.
- Update proxy forwarding and generated Guix daemon/client proxy configuration.
- A controlled Guix client download through the Qubes updates proxy in
  disposable/nested review environments, using
  `scripts/test-guix-update-proxy-stub-download-dom0.sh`.
- A real Guix update or download command through the Qubes updates proxy, such
  as `scripts/test-guix-update-proxy-download-dom0.sh` in a review environment
  with a working update-proxy target.
- Dynamic memory-balloon resize behavior under dom0 pressure.

## Review Rules

- Explain every non-obvious Guix/Qubes adaptation in `ADAPTATION_INVENTORY.md`
  or `SECURITY.md`.
- Keep source-changing substitutions named by Guix phase.  If reviewers prefer
  patch files, convert the rows identified in `ADAPTATION_INVENTORY.md`.
- Do not replace standard Qubes behavior with Guix-specific policy unless the
  reason is documented and covered by validation.
- Keep placeholders such as `<OWNER>`, `<REPOSITORY>`, `<NAME>`,
  `<GPG_FINGERPRINT>`, and `<MAINTAINER_GPG_FINGERPRINT>` only in draft/config
  or review-process files that explicitly warn not to submit them unchanged, or
  in tests that validate those draft/config placeholders.
- Disclose generative-AI assistance in the upstream discussion and only submit
  changes a human maintainer has reviewed and will maintain.

## Multi-Repo Flow

Use this order:

1. Publish the signed template repository.
2. Start the `qubes-devel` RFC using `SUBMISSION_DRAFTS.md`.
3. Discuss or submit the Builder v2 Guix distribution path.
4. Submit release-config entries only after the Builder path and maintainer
   identity are accepted.
5. Refresh all release evidence from the final signed branch before asking for
   `templates-community-testing` publication.
