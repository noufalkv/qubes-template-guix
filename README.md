# Qubes Guix Template

This repository builds a native GNU Guix System TemplateVM for Qubes OS R4.3.
Guix builds the template root filesystem; Qubes dom0 supplies the VM kernel.
QubesDB, qrexec, GUI/appmenus, shutdown, private-volume persistence, the update
proxy, swap, and `meminfo-writer` are mapped to Guix packages and Shepherd
services.

Variants:

- `guix`: GUI-capable template with Xorg, `xfce4-terminal`, `xterm`, Thunar,
  Mousepad, Evince, and Qubes audio (PipeWire/WirePlumber).
- `guix-minimal`: GUI-capable minimal template with Xorg and `xterm`.

This is a reviewable prototype, not a published Qubes community template.
`VALIDATION.md` and `UPSTREAMING.md` list the remaining publication gates.

## Important Files

| File | Purpose |
| --- | --- |
| `.guix-channel` | Channel metadata (modules live under `modules/`, keyring on the `keyring` branch). |
| `.guix-authorizations` | OpenPGP signers authorized to sign channel commits for `guix pull`. |
| `modules/qubes/packages.scm` | Qubes VM packages and package sets. |
| `modules/qubes/services.scm` | Qubes VM Shepherd services and service lists. |
| `modules/qubes/system.scm` | OS building blocks: privileged programs, system service stack, host name. |
| `modules/qubes/vm.scm` | Umbrella module re-exporting the three modules above. |
| `config/qubes-system.tmpl` | GNU Guix System config template; `scripts/render-config.sh` substitutes the variant and writes the per-variant `config.scm` installed as `/etc/config.scm`. |
| `config/guix-channels.scm` | Installed as `/etc/guix/channels.scm` so `guix pull` can update the Qubes channel. |
| `scripts/render-config.sh` | Render `config/qubes-system.tmpl` to a concrete operating-system file for a variant. |
| `config/channels.scm` | Pinned Guix channel used only while generating template images. |
| `builder-v2-template/` | Builder v2 content-script shape and variant appmenu allowlists. |
| `scripts/build-native-rootfs.sh` | Build or install a Guix root filesystem. |
| `scripts/build-template-rpm.sh` | Build a root image, inspect it, activate it, and package a qvm-template RPM. |
| `scripts/package-native-template-rpm.sh` | Package an existing root image as a Qubes Template Manager RPM. |
| `scripts/run-openqa-template-rpm.sh` | Schedule openQA against an existing template RPM. |
| `VALIDATION.md` | Current artifact/runtime evidence and missing gates. |
| `REVIEW_NOTES.md` | Maintainer-facing review map. |
| `ADAPTATION_INVENTORY.md` | Non-obvious Guix/Qubes adaptations and rationale. |
| `SECURITY.md` | Trust boundaries and review-sensitive behavior. |

## Build Inputs

`scripts/build-native-rootfs.sh` refreshes the build Guix with:

```sh
guix pull -p <temporary-profile> --allow-downgrades -C config/channels.scm
```

The refreshed Guix command is used only for template generation.  The generated
template does not install the pinned channel as root or user `guix pull` state.
The image installs this repository's channel modules under
`/etc/qubes-guix-channel/modules` so `/etc/config.scm` can be reconfigured
offline with `guix system -L /etc/qubes-guix-channel/modules reconfigure
/etc/config.scm`, and it ships `/etc/guix/channels.scm` so a user can instead
`guix pull` the Qubes channel and update the idiomatic way.

`config/channels.scm` uses Guix's official Codeberg channel URL.  That is an
upstream channel pin for the builder, not a checkout or file-channel rewrite.
There is no unauthenticated channel fallback, channel-file override, or
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
- variant selection: `qubes-variant-packages`.

The system definition is `config/qubes-system.tmpl`, a standard
`operating-system` form that imports `(qubes vm)` and wires its package sets,
services, and privileged programs.  `scripts/render-config.sh` substitutes the
variant token and writes the concrete `config.scm` installed as
`/etc/config.scm`.  The image also carries the channel modules under
`/etc/qubes-guix-channel/modules` (for offline `guix system -L … reconfigure`)
and `/etc/guix/channels.scm` (for `guix pull`).  Build-time evaluation uses the
same modules with `guix system -L modules`.

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

## Runtime Gates

Install and smoke a generated RPM in a dom0 review environment:

```sh
./scripts/test-template-rpm-lifecycle-dom0.sh \
  --rpm /path/to/qubes-template-guix-4.3.0-RELEASE.noarch.rpm \
  --replace-existing \
  --run-smoke
```

Schedule RPM-mode openQA against existing artifacts from an already configured
openQA host:

```sh
./scripts/run-openqa-template-rpm.sh \
  --variant normal \
  --template-rpm dist/qubes-template-guix-4.3.0-RELEASE.noarch.rpm \
  --qubes-disk /path/to/qubes-r4.3-dom0.qcow2 \
  --wait

./scripts/run-openqa-template-rpm.sh \
  --variant minimal \
  --template-rpm dist/qubes-template-guix-minimal-4.3.0-RELEASE.noarch.rpm \
  --qubes-disk /path/to/qubes-r4.3-dom0.qcow2 \
  --wait
```

Set `GUIX_RUN_PROXY_PULL_TEST=1` for an RPM-mode openQA run that must exercise
`guix pull` through the Qubes updates proxy.  The pull uses a temporary guest
profile and the official Guix channel URL; it does not install root or user
Guix channel state.

`VALIDATION.md` owns the full gate list and records which runtime evidence is
current for the exact source state under review.

## Builder V2 Review Shape

The local Builder-facing targets are:

```sh
make prepare build-rootimg
make prepare build-rpm
```

`builder-v2-template/` exposes the standard content-script layout.  Upstream
Builder v2 still needs accepted `dist: guix` support or an accepted component
wiring that points at these scripts.  The draft sketch is
`config/qubes-builderv2-guix.example.patch`.

Release-config and central-updater sketches live in:

- `config/qubes-release-configs-guix.example.patch`;
- `config/qubes-core-admin-linux-guix-vmupdate.example.patch`.

## Review Order

Start with:

1. `REVIEWER_GUIDE.md`
2. `REVIEW_NOTES.md`
3. `ADAPTATION_INVENTORY.md`
4. `VALIDATION.md`
5. `UPSTREAMING.md`
