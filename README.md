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
| `config/channels.scm` | Unpinned Guix channel (tracks `master`) used only while generating template images. |
| `builder-v2-template/` | Builder v2 content-script tree and Builder-resolved variant appmenu directories. |
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

The refreshed Guix command and its temporary profile are used only for template
generation.  The Guix channel is unpinned (tracks `master`), so each build uses
a current Guix.  The generated template installs `/etc/guix/channels.scm` for
normal in-template updates, but does not install the builder's temporary
`guix pull` profile as root or user state.  In the running template the
idiomatic update flow is:

```sh
guix pull
sudo guix system reconfigure /etc/config.scm
```

`guix pull` reads the installed `/etc/guix/channels.scm`, which adds this Qubes
channel and tracks the authenticated, unpinned Guix `master` branch at its
official Codeberg repository, so `(qubes vm)` resolves with no `-L`.  The image
also ships the channel modules under
`/etc/qubes-guix-channel/modules` as an offline fallback:

```sh
sudo guix system -L /etc/qubes-guix-channel/modules reconfigure /etc/config.scm
```

The Qubes update check compares the active generation's recorded Guix and
Qubes revisions with Guix's authenticated resolution of this channel file.  It
runs five minutes after boot and every two days, preserves dom0's existing
status on refresh failures, and rechecks immediately after a reconfiguration
when the last successful result cannot prove the new generation is current.

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

Build inputs owned by this repository are evaluated from one immutable commit
snapshot.  An explicit `--config` inside the repository must be tracked and
committed; a config outside it is copied once before the build and is not
attributed to the Qubes channel commit.

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

- `builder-v2-template/appmenus_guix/whitelisted-appmenus.list` for `guix`;
- `builder-v2-template/appmenus_guix_minimal/whitelisted-appmenus.list` for
  `guix-minimal`.

Each Builder-resolved directory also exposes relative
`vm-whitelisted-appmenus.list` and `netvm-whitelisted-appmenus.list` aliases to
the canonical list.  The RPM packaging path materializes all three as regular
files.

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
modules through the build scripts.  Those scripts require repository-owned
inputs to match `HEAD` and pass that exact commit as
`QUBES_TEMPLATE_CHANNEL_COMMIT` when running `guix system -L modules`, so the
installed update baseline names the source that was actually built.

After adding a package with a desktop entry, add that desktop-file ID to the
canonical `whitelisted-appmenus.list` in the matching appmenu directory listed
above.  Use package-provided desktop files and icons; add a custom desktop file
only when the package has none, as with `xterm`.

## Local Checks

Run the complete local functional suite with:

```sh
make check
```

`make check` combines two independently useful targets:

- `make source-check` runs shell syntax checks; Python unit tests for the
  bounded qvm-template repository helper; the offline Builder v2 content lookup
  contract; shared network-sysctl source checks; RPM metadata rejection tests;
  transaction and concurrency tests for Qubes pin refreshes; and
  substitute-cache delayed-bake, deadline, and failure-preservation tests.  On
  a host with Guix it also exercises channel-resolution and update-check
  behavior; static parity contracts run everywhere.
- `make guix-check` is the required functional target on release and other
  Guix-enabled hosts.  It runs the same suite but fails instead of
  accepting a skipped update-check behavior test when `guix` is unavailable.
- `make artifact-check` builds and extracts normal/minimal qvm-template RPM
  layouts through the local Builder adapter and native packager, validates
  Qubes Template Manager metadata, and compares reassembled split root images
  byte-for-byte with their sources.

Static linting is separate so environments without the optional tools can
still run the complete functional suite:

```sh
make lint
```

That target runs ShellCheck over the shell sources and Ruff over the Python
helper and tests.

These are local source, contract, and artifact checks.  The Builder v2 content
contract uses an in-tree fixture of upstream's resource lookup; it does not
execute upstream Builder v2.  None of these checks is Qubes acceptance or a
replacement for openQA or live TemplateVM/AppVM behavior.

Source freshness for pinned Qubes components is checked separately:

```sh
make check-qubes-pins
```

That command records source-pin freshness.  It is not runtime evidence.

## Runtime and Integration Validation

Runtime and integration validation for this template is delegated to Qubes
OS's existing openQA test infrastructure; it is run there rather than from this
repository.  This repository provides the Guix channel, the template build
path, and local source/contract/artifact validation (`make check`) only; it does
not ship a bespoke dom0/openQA test harness.

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

The local Builder-facing adapter targets are:

```sh
make prepare build-rootimg
make prepare build-rpm
```

These targets invoke this repository's adapter directly; they do not run the
upstream Builder v2 plugin.  Similarly,
`tests/builder-v2-content-contract-check.sh` checks the content tree against an
offline copy of upstream's resource-resolution order, including normal/minimal
appmenu and `template.conf` lookup, but is not an upstream Builder execution.

`builder-v2-template/` exposes the standard content-script layout.  Upstream
Builder v2 still needs accepted `dist: guix` support or an accepted component
wiring that points at these scripts.  Upstream Builder v2 / release-config /
central-updater integration is tracked as separate Qubes RFCs:
QubesOS/qubes-builderv2#245, QubesOS/qubes-core-admin-linux#211, and
QubesOS/qubes-release-configs#19.  Their patches are regenerated from accepted
upstream branches rather than vendored here.

## Maintenance

**Updating Qubes components** (for each R4.3 component bump):

1. Run `./scripts/check-qubes-pins.sh --write` and review the proposed update.
   The writer resolves the newest tag in each pinned release series, recomputes
   its recursive Guix hash, and refuses concurrent edits.
2. Run `./scripts/check-qubes-pins.sh` again to verify every tag, commit, and
   recursive hash against live upstream state.
3. Run `make guix-check` and `make lint`, then rebuild and test both variants
   before publishing.

**Refreshing the build-time Guix**:

1. `config/channels.scm` is unpinned and tracks Guix `master`, so each build
   already uses a current Guix; nothing needs editing for routine refreshes.
2. Build both variants normally; `scripts/build-native-rootfs.sh` runs an
   authenticated `guix pull` against that channel.
3. Rebuild both root images, inspect and activate both, package both RPMs, and run RPM-mode openQA.
4. To reproduce an exact past template, use `guix time-machine` with the Guix
   commit recorded for that build rather than re-introducing a permanent pin.

**Channel authentication**: `.guix-authorizations` lists authorized OpenPGP fingerprints; the signer's public key lives on the `keyring` branch. When rotating a key, update `.guix-authorizations`, add the key to the `keyring` branch, and refresh the channel introduction in `config/guix-channels.scm`.

**Security cadence**: rebuild and publish when a pinned Qubes VM component receives a relevant R4.3 update or upstream Guix needs security or compatibility updates. Each rebuild must record source commit, Guix channel commit, component pins and hashes, RPM hashes, and openQA results.

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
