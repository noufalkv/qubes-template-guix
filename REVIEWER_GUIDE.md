# Reviewer Guide

This is the short entry point for a human reviewer.  The repository is a
reviewable native GNU Guix System TemplateVM prototype for Qubes OS R4.3; it is
not yet a publishable Qubes community template.

## Start Here

1. Read `SUBMISSION_AUDIT.md` first.  It maps the requested upstreamability
   requirements to concrete files, checks, and missing gates.
2. Read `REVIEW_NOTES.md` for the maintainer-facing review matrix, scope, and
   non-goals.
3. Read `ADAPTATION_INVENTORY.md` before reviewing Scheme package phases or
   Shepherd services.  It lists each non-obvious Guix/Qubes adaptation, why it
   exists, and what currently validates it.
4. Read `VALIDATION.md` before relying on any test result.  It separates local
   contract checks, pin/provenance notes, nested-dom0 evidence, and unpassed
   release gates.
5. Read `UPSTREAMING.md` and `config/README.md` for the multi-repo Builder v2
   and release-config path.

## Review Chunks

- Native Guix implementation:
  `native/modules/qubes/packages/qubes-vm.scm`,
  `native/modules/qubes/services/qubes-vm.scm`,
  `native/modules/qubes/systems/guix-template.scm`, `native/qubes-guix.scm`,
  and `native/qubes-guix-minimal.scm`.
- Image and RPM tooling:
  `scripts/build-native-rootfs.sh`, `scripts/inspect-native-rootfs.sh`,
  `scripts/test-native-rootfs-activation.sh`, and
  `scripts/package-native-template-rpm.sh`.
- Builder and release-config sketches:
  `builder-v2-template/`, `Makefile.builder`, `config/README.md`,
  `config/qubes-builderv2-guix.example.patch`, and
  `config/qubes-release-configs-guix.example.patch`.
- Central Qubes updater sketch:
  `config/qubes-core-admin-linux-guix-vmupdate.example.patch`.
- Runtime and release harnesses:
  `scripts/test-template-rpm-lifecycle-dom0.sh`,
  `scripts/test-native-guix-template-dom0.sh`,
  `scripts/test-update-proxy-default-target-dom0.sh`,
  `scripts/test-guix-update-proxy-config-dom0.sh`,
  `scripts/test-guix-update-proxy-download-dom0.sh`,
  `scripts/test-guix-update-proxy-stub-download-dom0.sh`,
  `scripts/test-guix-central-vmupdate-dom0.sh`,
  `scripts/diagnose-update-proxy-dom0.sh`,
  `scripts/test-memory-balloon-dom0.sh`, and `openqa/qubesos/`.

`PATCH_SERIES.md` expands this into the intended review order.

## Checks That Count As Review Evidence

```sh
make check
```

Run the Guix record gate on a Guix-capable builder:

```sh
make guix-system-contract-check
```

`make check` runs contract checks only: public script missing-value handling is
executed, the native rootfs builder's pinned-channel failure path is executed
before image/mount work, Builder hooks are executed against a temporary install
tree, and normal/minimal template RPMs are built, extracted, checked for Qubes
Template Manager layout, and reassembled.
`make guix-system-contract-check` requires Guix and instantiates the actual
normal/minimal operating-system records to check Qubes-visible defaults such as
`/dev/xvdc1` swap, the standard `user` account and Qubes group membership,
default privileged programs, passwordless sudo, required Qubes services, and
`meminfo-writer` defaults.

No source-only checker is part of the repository test suite or reviewer
evidence path.  Tests that grep source or compare patch shape should not be
submitted as upstream patches or kept as repository validation scripts.
Formatting, parser-only, inventory, and pin-freshness commands may help a
maintainer prepare a branch manually, but they do not demonstrate that the
template builds, installs, boots, or satisfies Qubes-visible contracts.

## Do Not Claim Yet

- Qubes Builder v2 has not accepted `dist: guix`.
- `qubes-release-configs` has not accepted `guix` or `guix-minimal`.
- Release-owner metadata and release-owner signed tags are not present.  The
  current review commits are signed with the one-shot contribution key only;
  that does not replace maintainer ownership or publication signing.
- Final publication-branch or release-tag RPM-mode openQA has not been rerun.
- Final publication-branch or release-tag central update evidence is still
  needed.  RPM-mode openQA job 129 proved the current review artifact can run
  `guix time-machine --branch=master` and `guix system reconfigure` through a
  standard Debian `sys-net` update target with agent exit status 0.  Job 133
  reached the same Qubes update-proxy path and then failed on an upstream Git
  HTTP 504 during Guix refresh, so public network availability remains an
  external release variable.
- The `qubes-core-admin-linux` Guix vmupdate backend patch is tested in a clean
  patched checkout.  A temporary nested-dom0 backport of the current backend
  reached central `qubes-vm-update` dispatch, parsed system-profile metadata
  into `name:output` records with version and store path values, used the Qubes
  proxy environment, and logged Guix stderr.  It has not been accepted
  upstream, and the passing job 129 evidence still needs a publication-object
  rerun before it can be treated as release evidence.
- Qubes maintainers have not reviewed or accepted the template.
