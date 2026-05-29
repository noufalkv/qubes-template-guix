# Upstreaming Status

This repository is a native GNU Guix System TemplateVM prototype for Qubes OS
R4.3.  It is reviewable as a draft, but it is not yet a publishable Qubes
community template.

The upstream shape is deliberately split:

- this repository contains the Guix System definition, rootfs/RPM build path,
  Builder-shaped hooks, and review evidence;
- upstream Builder v2 / release-config / central-updater integration is tracked
  as separate Qubes RFCs; their patches are regenerated from accepted upstream
  branches rather than vendored here (QubesOS/qubes-builderv2#245,
  QubesOS/qubes-core-admin-linux#211, QubesOS/qubes-release-configs#19).

The RFC PRs are review surfaces only:
QubesOS/qubes-builderv2#245, QubesOS/qubes-core-admin-linux#211, and
QubesOS/qubes-release-configs#19.  They do not mean Qubes has accepted or will
publish the template.

## Current Local State

This repository is a Guix channel.  `.guix-channel` declares the channel
metadata, `modules/qubes/packages.scm` contains the Qubes VM package and service module, and
`config/qubes-system.tmpl` is the operating-system template rendered per variant
by `scripts/render-config.sh` and installed as `/etc/config.scm`.  The image also
installs the channel module under `/etc/qubes-guix-channel` for later
reconfiguration.

Release-quality builds use `config/channels.scm` as a template-generation
input.  The rootfs builder runs authenticated
`guix pull -p <temporary-profile> --allow-downgrades -C config/channels.scm`
against Guix's official Codeberg channel URL, then builds with the refreshed
Guix command.  The generated template does not install that channel pin as root
or user `guix pull` state.

Qubes VM component sources are pinned in Guix package definitions with
immutable commits and recursive hashes.  Source freshness is checked with:

```sh
make check-qubes-pins
```

That command records source-pin freshness.  It is not runtime evidence.

The local artifact contract is:

```sh
make check
```

`make check` builds and extracts normal/minimal qvm-template RPM layouts through
the Builder adapter and native packager.  Release evidence still requires real
rootfs builds, activation, qvm-template lifecycle, openQA, and live VM behavior
from the branch or tag being submitted.

## Builder Path

The repository exposes the standard targets a Builder integration can call:

```sh
make prepare build-rootimg
make prepare build-rpm
```

`builder-v2-template/` provides the Qubes template content-script shape:
`00_prepare.sh`, `01_install_core.sh`, `02_install_groups.sh`,
`04_install_qubes.sh`, and `09_cleanup.sh`.  The core install hook delegates to
`scripts/build-native-rootfs.sh --install-dir`.  Builder v2 calls
`02_install_groups.sh` and `09_cleanup.sh` unconditionally, so those hooks are
kept as explicit no-ops; package selection and cleanup are handled by the Guix
system build itself.

This does not make upstream Builder v2 understand Guix by itself.  Builder v2
still needs accepted `dist: guix` support or release-config wiring that points
at this component.  The checked-in Builder patch sketch takes the
content-script route.

Template generation is independent of any test harness.  `scripts/build-template-rpm.sh`
builds the root image, inspects the expected variant contents, runs rootfs
activation, and packages the RPM.  Integration testing is delegated to Qubes
OS's existing openQA suite, which is external to this repository.

## Guix Alignment

The template is expressed as Guix package definitions, Guix operating-system
records, and Shepherd service types.  Qubes behavior that distributions
normally provide through packages and systemd units is mapped to Guix package
phases and Shepherd services.

Important boundaries:

- one channel module for Qubes VM package/service definitions;
- no checkout/file-channel, channel-file override, or unauthenticated channel
  workaround;
- no custom appmenu desktop files except the `xterm` entry needed because Guix
  does not provide one;
- no root/user `current-guix` profile pin installed into the image;
- no bespoke openQA/dom0 test harness is shipped; integration testing is
  delegated to Qubes' existing suite;
- no overlay implementation has been added, and no overlay design is decided.

`ADAPTATION_INVENTORY.md` maps the non-obvious Guix/Qubes adaptations to files,
rationale, and evidence.  `SECURITY.md` records trust boundaries and sensitive
guest-side behavior.

## Release Evidence

Fresh publication evidence must come from the exact public branch or release
object being submitted.  `VALIDATION.md` owns the detailed checklist and current
status; old PR comments, CI status, and build logs are historical unless they
are refreshed against that source state.

## Remaining Work

1. Keep the public review branch clean and reproducible.
2. Keep the three upstream component PRs explicitly draft/RFC until the Builder,
   updater, and release-config responsibilities are accepted.
3. Decide the final Builder v2 integration shape.
4. Add release-config-ready metadata for `guix` and `guix-minimal` after there
   is an accepted owner for publication.
5. Convert any source-changing substitutions reviewers reject into small patch
   files, or keep them grouped as explicit Guix phases with rationale.
6. Run fresh release evidence for both variants from a clean public branch or
   tag.
7. Keep `MAINTENANCE.md` current with cadence, update inputs, rollback, and
   handoff/removal policy.

Until those items are closed, this is a reviewable prototype with draft
validation, not a published Qubes community template.
