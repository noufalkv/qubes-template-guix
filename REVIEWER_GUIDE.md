# Reviewer Guide

This is the short entry point for a human reviewer.  The repository is a
reviewable native GNU Guix System TemplateVM prototype for Qubes OS R4.3; it is
not yet a publishable Qubes community template.

## Start Here

1. Read `REVIEW_NOTES.md` for the maintainer-facing review matrix, scope, and
   non-goals.
2. Read `ADAPTATION_INVENTORY.md` before reviewing Scheme package phases or
   Shepherd services.  It lists each non-obvious Guix/Qubes adaptation, why it
   exists, and what currently validates it.
3. Read `VALIDATION.md` before relying on any validation claim.  It separates
   local contract checks, pin/provenance notes, local artifact and externally-run
   Qubes openQA evidence, and unpassed release gates.
4. Read `UPSTREAMING.md` for the upstream Builder v2 and release-config RFC
   path.

## Review Chunks

- Native Guix implementation:
  `.guix-channel`, `modules/qubes/packages.scm`, `config/qubes-system.tmpl`, and
  `scripts/render-config.sh`.
- Image and RPM tooling:
  `scripts/build-native-rootfs.sh`, `scripts/inspect-native-rootfs.sh`,
  `scripts/test-native-rootfs-activation.sh`, and
  `scripts/package-native-template-rpm.sh`.
- Builder and release-config sketches:
  `builder-v2-template/`.
  Upstream Builder v2 / release-config / central-updater integration is tracked
  as separate Qubes RFCs (QubesOS/qubes-builderv2#245,
  QubesOS/qubes-core-admin-linux#211, QubesOS/qubes-release-configs#19);
  patches are regenerated from accepted upstream branches and are not vendored
  here.

## Review Evidence

```sh
make check
```

`make check` runs local artifact checks only: normal/minimal template RPMs are
built through the Builder RPM adapter and the native packager, extracted,
checked for Qubes Template Manager layout, and reassembled.

Local artifact and rootfs activation evidence comes from this repository.
Dom0/openQA integration evidence is produced externally via Qubes' own openQA
suite.

## Do Not Claim Yet

- Qubes has not accepted the Builder v2, release-config, or core-admin Linux
  Guix sketches.
- Release-owner metadata is not present.
- Integration/openQA evidence from Qubes' own suite has not been rerun against
  the final branch/tag.
- Qubes maintainers have not reviewed or accepted the template.
