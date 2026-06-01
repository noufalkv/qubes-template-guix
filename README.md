# Qubes Guix Template

This repository builds a native GNU Guix System TemplateVM for Qubes OS R4.3.
Guix builds the template root filesystem; Qubes dom0 supplies the VM kernel.
QubesDB, qrexec, GUI/appmenus, shutdown, private-volume persistence, the update
proxy, swap, and `meminfo-writer` are mapped to Guix packages and Shepherd
services.

Variants:

- `guix`: GUI-capable template with Xorg, `xfce4-terminal`, `xterm`, Thunar,
  Mousepad, Evince, Qubes audio (PipeWire/WirePlumber), and `dnsmasq` so it can
  act as a network provider (NetVM/ProxyVM).
- `guix-minimal`: GUI-capable minimal template with Xorg and `xterm`.

This is a reviewable prototype, not a published Qubes community template.
`VALIDATION.md` lists the remaining publication gates.

## Important Files

| File | Purpose |
| --- | --- |
| `.guix-channel` | Channel metadata (modules live under `modules/`, keyring on the `keyring` branch). |
| `.guix-authorizations` | OpenPGP signers authorized to sign channel commits for `guix pull`. |
| `modules/qubes/packages.scm` | Qubes VM packages and package sets. |
| `modules/qubes/services.scm` | Qubes VM Shepherd services and service lists. |
| `modules/qubes/system.scm` | OS building blocks: privileged programs, system service stack, host name. |
| `modules/qubes/vm.scm` | Umbrella module re-exporting the three modules above. |
| `config/guix-channels.scm` | Installed as `/etc/guix/channels.scm` so `guix pull` can update the Qubes channel. |
| `config/channels.scm` | Pinned Guix channel used only while generating template images. |
| `builder-v2-template/` | Builder v2 content-script shape and variant appmenu allowlists. |
| `scripts/build-native-rootfs.sh` | Build or install a Guix root filesystem. |
| `scripts/build-template-rpm.sh` | Build a root image, inspect it, activate it, and package a qvm-template RPM. |
| `scripts/package-native-template-rpm.sh` | Package an existing root image as a Qubes Template Manager RPM. |
| `VALIDATION.md` | Current artifact/runtime evidence and missing gates. |
| `ADAPTATION_INVENTORY.md` | Non-obvious Guix/Qubes adaptations, rationale, trust boundaries, and review-sensitive behavior. |

## Build Inputs

`scripts/build-native-rootfs.sh` refreshes the build Guix with:

```sh
guix pull -p <temporary-profile> --allow-downgrades -C config/channels.scm
```

The refreshed Guix command is used only for template generation.  The Guix
channel is unpinned (tracks `master`), so each build uses a current Guix.  The
generated template does not install the pinned channel as root or user `guix
pull` state.  In the running template the idiomatic update flow is:

```sh
guix pull
sudo guix system reconfigure /etc/config.scm
```

`guix pull` reads the installed `/etc/guix/channels.scm`, which adds this Qubes
channel (and tracks upstream Guix via `%default-channels`), so `(qubes vm)`
resolves with no `-L`.  The image also ships the channel modules under
`/etc/qubes-guix-channel/modules` as an offline fallback:

```sh
sudo guix system -L /etc/qubes-guix-channel/modules reconfigure /etc/config.scm
```

`config/channels.scm` uses Guix's official Codeberg channel URL on its `master`
branch with no commit pin, so template builds track current Guix.  That is an
upstream channel reference for the builder, not a checkout or file-channel
rewrite.  There is no unauthenticated channel fallback, channel-file override, or
developer checkout override in the build path.

## Build Root Images

Normal:

```sh
./scripts/build-native-rootfs.sh \
  --variant normal \
  --output root.img
```

Minimal:

```sh
./scripts/build-native-rootfs.sh \
  --variant minimal \
  --output root-minimal.img
```

`scripts/build-template-rpm.sh` runs image inspection and activation before
packaging.  To inspect a root image directly:

```sh
./scripts/inspect-native-rootfs.sh --image root.img --variant normal
./scripts/inspect-native-rootfs.sh --image root-minimal.img --variant minimal
```

Run writable-root activation directly on a generated image:

```sh
./scripts/test-native-rootfs-activation.sh --image root.img
```

## Build Template RPMs

Build a complete qvm-template RPM candidate without openQA:

```sh
./scripts/build-template-rpm.sh \
  --variant normal \
  --version 4.3.0 \
  --release "$(date -u +%Y%m%d%H%M)"

./scripts/build-template-rpm.sh \
  --variant minimal \
  --version 4.3.0 \
  --release "$(date -u +%Y%m%d%H%M)"
```

Equivalent Make targets:

```sh
make template-rpm-normal
make template-rpm-minimal
```

The RPM payload follows Qubes Template Manager layout under
`/var/lib/qubes/vm-templates/NAME/`: split `root.img.part.NN` files,
`template.conf`, appmenu allowlists, app directories, and template image
ghosts.  Packages advertise `qrexec=1`, `gui=1`, and `virt-mode=pvh`.

Appmenu allowlists come from:

- `builder-v2-template/appmenus.list`;
- `builder-v2-template/appmenus-minimal.list`.

They should reference desktop files provided by packages.  The only generated
desktop file is `xterm.desktop`, because Guix does not provide one.

## Changing Packages

Package selection lives in the channel module `modules/qubes/packages.scm`:

- shared runtime packages: `%qubes-common-packages`;
- normal desktop packages: `%qubes-normal-desktop-packages`;
- normal audio packages: `%qubes-normal-audio-packages`;
- normal network-provider packages: `%qubes-normal-network-packages`;
- variant selection: `qubes-variant-packages`.

The system definition is `config/qubes-os-normal.scm` and `config/qubes-os-minimal.scm`, calling `qubes-operating-system` which is a standard
`operating-system` form that imports `(qubes vm)` and wires its package sets,
services, and privileged programs.
These concrete configs are installed as
`/etc/config.scm`.  Users update with `guix pull && sudo guix system reconfigure
/etc/config.scm` via the installed `/etc/guix/channels.scm`.  The image also
carries the channel modules under `/etc/qubes-guix-channel/modules` as an offline
fallback (`guix system -L … reconfigure`).  Build-time evaluation uses the same
modules with `guix system -L modules`.

After adding a package with a desktop entry, add that desktop-file ID to the
matching appmenu allowlist under `builder-v2-template/`.  Use package-provided
desktop files and icons; add a custom desktop file only when the package has
none, as with `xterm`.

## Local Artifact Contract

Run:

```sh
make check
```

This builds and extracts normal/minimal qvm-template RPM layouts through the
Builder adapter and native packager, validates Qubes Template Manager metadata,
and verifies the reassembled split root images against their source images.

This is local artifact evidence.  It is not Qubes acceptance and does not
replace openQA or live TemplateVM/AppVM behavior.

Source freshness for pinned Qubes components is checked separately:

```sh
make check-qubes-pins
```

That command records source-pin freshness.  It is not runtime evidence.

## Runtime and Integration Validation

Runtime and integration validation for this template is delegated to Qubes
OS's existing openQA test infrastructure; it is run there rather than from this
repository.  This repository provides the Guix channel, the template build
path, and local artifact validation (`make check`) only; it does not ship a
bespoke dom0/openQA test harness.

Local tooling that needs no dom0:

- `scripts/build-template-rpm.sh` builds the root image, inspects it, runs
  writable-root activation, and packages the RPM.
- `scripts/inspect-native-rootfs.sh` checks the expected profile payload,
  Qubes compatibility paths, variant commands, and desktop entries.
- `scripts/test-native-rootfs-activation.sh` is a local writable-root
  activation check; it is not an integration test.

See `VALIDATION.md` for the current evidence gates and which classes of
evidence are still open.

## Builder V2 Review Shape

The local Builder-facing targets are:

```sh
make prepare build-rootimg
make prepare build-rpm
```

`builder-v2-template/` exposes the standard content-script layout.  Upstream
Builder v2 still needs accepted `dist: guix` support or an accepted component
wiring that points at these scripts.  Upstream Builder v2 / release-config /
central-updater integration is tracked as separate Qubes RFCs:
QubesOS/qubes-builderv2#245, QubesOS/qubes-core-admin-linux#211, and
QubesOS/qubes-release-configs#19.  Their patches are regenerated from accepted
upstream branches rather than vendored here.

## Maintenance

**Updating Qubes components** (for each R4.3 component bump):

1. Run `./scripts/check-qubes-pins.sh` to compare pinned commits against current upstream tags.
2. Update the component tag, commit, and recursive Guix hash in `%qubes-source-components` in `modules/qubes/packages.scm`.
3. Run `make check`, then rebuild and test both variants before publishing.

**Updating the Guix channel pin**:

1. Update `config/channels.scm` to the desired Guix commit.
2. Build both variants normally; `scripts/build-native-rootfs.sh` runs authenticated `guix pull` against that pin.
3. Rebuild both root images, inspect and activate both, package both RPMs, and run RPM-mode openQA.

**Channel authentication**: `.guix-authorizations` lists authorized OpenPGP fingerprints; the signer's public key lives on the `keyring` branch. When rotating a key, update `.guix-authorizations`, add the key to the `keyring` branch, and refresh the channel introduction in `config/guix-channels.scm`.

**Security cadence**: rebuild and publish when a pinned Qubes VM component receives a relevant R4.3 update or the pinned Guix channel needs security or compatibility updates. Each rebuild must record source commit, Guix channel commit, component pins and hashes, RPM hashes, and openQA results.

**Rollback**: Qubes template rollback uses `qvm-template` to reinstall or downgrade the `qubes-template-guix*` RPM. Inside a running TemplateVM, Guix system generations can be rolled back when the user deliberately reconfigures.

**Release ownership**: before stable publication, a release owner must supply a public repository URL, release-owner metadata, fresh build and runtime evidence for both variants, and a maintainer handoff plan. The current RFC/review state intentionally omits that metadata.

## Review Guide

Start with `ADAPTATION_INVENTORY.md` and `VALIDATION.md` before reading code.
`ADAPTATION_INVENTORY.md` maps every non-obvious adaptation to its rationale and
validation path.  `VALIDATION.md` separates artifact, openQA, and runtime
evidence and lists which publication gates remain open.

Review areas by file group:

- **Native Guix implementation**: `.guix-channel`, `modules/qubes/packages.scm`,
  `config/qubes-os-normal.scm`, `config/qubes-os-minimal.scm`.
- **Image and RPM tooling**: `scripts/build-native-rootfs.sh`,
  `scripts/inspect-native-rootfs.sh`, `scripts/test-native-rootfs-activation.sh`,
  `scripts/package-native-template-rpm.sh`.
- **Builder and release-config sketches**: `builder-v2-template/`.
  Upstream Builder v2 / release-config / central-updater integration is tracked
  as separate Qubes RFCs (QubesOS/qubes-builderv2#245,
  QubesOS/qubes-core-admin-linux#211, QubesOS/qubes-release-configs#19); patches
  are regenerated from accepted upstream branches and are not vendored here.
- **Process and evidence**: `VALIDATION.md`, `ADAPTATION_INVENTORY.md`.

Publication gates not yet closed:

- Qubes has not accepted the Builder v2, release-config, or core-admin Linux sketches.
- Release-owner metadata is not present.
- Integration/openQA evidence from Qubes' own suite has not been rerun against the final branch or tag.
- Qubes maintainers have not reviewed or accepted the template.
