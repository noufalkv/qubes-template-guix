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

## Required Local Checks

Run before asking for review:

```sh
git diff --check
make check
./scripts/check-qubes-pins.sh
```

When fresh upstream checkouts are available, also run:

```sh
rm -rf /tmp/qubes-builderv2 /tmp/qubes-release-configs
git clone --depth 1 https://github.com/QubesOS/qubes-builderv2.git \
  /tmp/qubes-builderv2
git clone --depth 1 https://github.com/QubesOS/qubes-release-configs.git \
  /tmp/qubes-release-configs
./scripts/maintainer-preflight.sh
```

That command is maintainer hygiene for syntax, patch application, and
configuration sketches.  It is not a test gate.  Treat `make check`, rootfs
activation, RPM lifecycle, and dom0/openQA runs as the evidence that the
template behavior works.

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
- A real Guix update or download command through the Qubes updates proxy.
- Dynamic memory-balloon resize behavior under dom0 pressure.

## Review Rules

- Explain every non-obvious Guix/Qubes adaptation in `ADAPTATION_INVENTORY.md`
  or `SECURITY.md`.
- Keep source-changing substitutions named by Guix phase.  If reviewers prefer
  patch files, convert the rows identified in `ADAPTATION_INVENTORY.md`.
- Do not replace standard Qubes behavior with Guix-specific policy unless the
  reason is documented and covered by validation.
- Keep placeholders such as `<OWNER>` and `<MAINTAINER_GPG_FINGERPRINT>` only
  in draft/config files that explicitly warn not to submit them unchanged.
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
