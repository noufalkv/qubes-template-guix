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
   local contract checks, pin/provenance notes, dom0/openQA evidence, and
   unpassed release gates.
4. Read `UPSTREAMING.md` and `config/README.md` for the multi-repo Builder v2
   and release-config path.

## Review Chunks

- Native Guix implementation:
  `.guix-channel`, `modules/qubes/packages.scm`, `config/qubes-system.tmpl`, and
  `scripts/render-config.sh`.
- Image and RPM tooling:
  `scripts/build-native-rootfs.sh`, `scripts/inspect-native-rootfs.sh`,
  `scripts/test-native-rootfs-activation.sh`, and
  `scripts/package-native-template-rpm.sh`.
- Builder and release-config sketches:
  `builder-v2-template/`, `config/README.md`,
  `config/qubes-builderv2-guix.example.patch`, and
  `config/qubes-release-configs-guix.example.patch`.
- Central Qubes updater sketch:
  `config/qubes-core-admin-linux-guix-vmupdate.example.patch`.
- Runtime and release harnesses:
  `scripts/test-template-rpm-lifecycle-dom0.sh`,
  `scripts/test-native-guix-template-dom0.sh`,
  `scripts/test-guix-update-proxy-dom0.sh`,
  `scripts/test-guix-central-vmupdate-dom0.sh`,
  `scripts/test-memory-balloon-dom0.sh`, and `openqa/qubesos/`.

## Review Evidence

```sh
make check
```

`make check` runs local artifact checks only: normal/minimal template RPMs are
built through the Builder RPM adapter and the native packager, extracted,
checked for Qubes Template Manager layout, and reassembled.

Reviewer evidence should come from artifacts, rootfs activation, dom0 behavior,
and openQA output.

## Do Not Claim Yet

- Qubes has not accepted the Builder v2, release-config, or core-admin Linux
  Guix sketches.
- Release-owner metadata is not present.
- Final branch/tag RPM-mode openQA and central-update evidence have not been
  rerun.
- Qubes maintainers have not reviewed or accepted the template.
