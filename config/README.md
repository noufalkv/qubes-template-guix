# config/ — Build Inputs

This directory contains files that are inputs to template generation.

- `channels.scm`: pinned Guix channel used only while generating template
  images.  `scripts/build-native-rootfs.sh` passes this file to an
  authenticated `guix pull` before building; it is not installed as root or
  user Guix channel state.
- `guix-channels.scm`: installed as `/etc/guix/channels.scm` so users inside
  the TemplateVM can run `guix pull` to update the Qubes channel the idiomatic
  way.
- `qubes-system.tmpl`: the `operating-system` template rendered per variant by
  `scripts/render-config.sh`; the result is installed as `/etc/config.scm` and
  imports the channel modules from `/etc/qubes-guix-channel/modules`.

The channel metadata and module sources live in `../.guix-channel` and
`../modules/qubes/`.

Upstream Builder v2 / release-config / central-updater integration is tracked
as separate Qubes RFCs (QubesOS/qubes-builderv2#245,
QubesOS/qubes-core-admin-linux#211, QubesOS/qubes-release-configs#19); see
`UPSTREAMING.md`.  Their patches are regenerated from accepted upstream
branches and are not vendored in this repository.
