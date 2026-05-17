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
- Runtime and release harnesses:
  `scripts/test-template-rpm-lifecycle-dom0.sh`,
  `scripts/test-native-guix-template-dom0.sh`,
  `scripts/test-update-proxy-default-target-dom0.sh`,
  `scripts/test-guix-update-proxy-config-dom0.sh`,
  `scripts/test-guix-update-proxy-download-dom0.sh`,
  `scripts/test-guix-update-proxy-stub-download-dom0.sh`,
  `scripts/diagnose-update-proxy-dom0.sh`,
  `scripts/test-memory-balloon-dom0.sh`, and `openqa/qubesos/`.

`PATCH_SERIES.md` expands this into the intended review order.

## Checks That Count As Local Evidence

```sh
git diff --check
make check
```

`make check` runs contract checks only: Builder hooks are executed
against a temporary install tree, and normal/minimal template RPMs are built,
extracted, checked for Qubes Template Manager layout, and reassembled.  It also
parses the example R4.3 release-config fragment for the expected `builder-guix`,
`guix`, and `guix-minimal` entries.

The pin freshness check is useful provenance hygiene, but it is not runtime or
release evidence:

```sh
./scripts/check-qubes-pins.sh
```

## Do Not Claim Yet

- Qubes Builder v2 has not accepted `dist: guix`.
- `qubes-release-configs` has not accepted `guix` or `guix-minimal`.
- Maintainer identity, GPG fingerprint, signed commits, and signed release tags
  are not present.
- Final signed-branch RPM-mode openQA has not been rerun.
- Real `guix pull` or substitute downloads through the Qubes update proxy are
  not proven.  RPM-mode openQA job 27 proves the generated Guix client/daemon
  proxy configuration and service state for the rebuilt minimal RPM, and job 31
  proves a controlled `guix download` through stock Qubes default-target policy
  using a temporary `sys-net` stub.  OpenQA job 29 reached the real-network
  download verifier, but dom0 refused `qubes.UpdatesProxy`; there is still no
  passing release evidence for real Guix update tooling through an Internet
  update target.
- Qubes maintainers have not reviewed or accepted the template.
