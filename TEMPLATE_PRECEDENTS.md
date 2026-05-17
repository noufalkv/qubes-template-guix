# Template Builder Precedents

This file maps the Guix template scaffold to the existing Qubes template-builder
shape so reviewers can see where the design follows precedent and where Guix is
different.

## Source Inputs Checked

- Qubes Forum guide, "Building a TemplateVM for a new OS":
  `https://forum.qubes-os.org/t/building-a-templatevm-for-a-new-os/18972`
- Qubes Forum guide, "Building F42 template in R4.3":
  `https://forum.qubes-os.org/t/building-f42-template-in-r4-3/40176`
- Qubes Forum thread, "How to make a template":
  `https://forum.qubes-os.org/t/how-to-make-a-template/34320`
- Qubes Builder v2 documentation:
  `https://doc.qubes-os.org/en/latest/developer/building/qubes-builder-v2.html`
- Qubes Builder v2 template plugin checkout:
  `/tmp/qubes-builderv2/qubesbuilder/plugins/template/`
- Qubes R4.3 community template release config checkout:
  `/tmp/qubes-release-configs/R4.3/qubes-os-r4.3-templates-community.yml`
- Local Qubes agent source checkouts under `/home/user/qubes-opt/repos/`.

The new-OS forum guide points template work at existing Fedora, Debian, and
Arch scripts and describes the relevant hook responsibilities.  The newer
"how to make a template" forum thread reinforces that the correct path depends
on the target OS and required services, and that older BuilderPlugins-era
guidance may not match Builder v2.  The R4.3 F42 guide reinforces the current
Builder v2 and release-config flow before import and TemplateVM testing.  This
repository uses the same high-level hook vocabulary while delegating the actual
system construction to Guix.

## Hook Mapping

| Qubes template hook | Precedent responsibility | Guix implementation |
| --- | --- | --- |
| `00_prepare.sh` | Prepare the install root and early template state before package installation. | `builder-v2-template/00_prepare.sh` creates the install root and delegates rootfs setup state to `scripts/build-native-rootfs.sh --install-dir`. |
| `01_install_core.sh` | Install base operating-system components. | Present as a no-op compatibility hook because Guix computes the full operating-system closure declaratively instead of incrementally installing distro packages. |
| `02_install_groups.sh` | Install the user-facing package groups for the selected template flavor. | `builder-v2-template/02_install_groups.sh` selects normal versus minimal flavor inputs and appmenu sets; package membership is expressed in `native/qubes-guix.scm` and `native/qubes-guix-minimal.scm`. |
| `04_install_qubes.sh` | Install Qubes VM packages and configure Qubes storage/runtime integration. | `builder-v2-template/04_install_qubes.sh` delegates to the native Guix system build.  Qubes packages live in `native/modules/qubes/packages/qubes-vm.scm`; Qubes services, swap, private-volume layout, and compatibility paths live in `native/modules/qubes/services/qubes-vm.scm` and `native/modules/qubes/systems/guix-template.scm`. |
| `09_cleanup.sh` | Remove build-time/cache state and finalize the image. | `builder-v2-template/09_cleanup.sh` performs the reviewable cleanup boundary while Guix keeps package closures immutable and reproducible. |

## Release-Config Precedent

Existing R4.3 community templates are declared as Builder components plus
template entries.  The Guix sketch follows that model:

- `builder-guix` component:
  `config/qubes-os-r4.3-templates-community-guix.example.yml`
- `guix` template entry:
  `dist: guix`
- `guix-minimal` template entry:
  `dist: guix`, `flavor: minimal`

The release-config patch remains a sketch until the maintainer repository URL,
GPG fingerprint, signing path, and Builder v2 integration are accepted.

## Important Guix Differences

- Guix does not install packages into the image with `dnf`, `apt`, or `pacman`.
  It builds an operating-system closure and then materializes the root image.
- The Qubes VM agents are packaged as Guix packages from exact QubesOS Git
  commits and recursive content hashes.
- Runtime service ownership is Shepherd-based rather than systemd-based, so
  `ADAPTATION_INVENTORY.md` and `SECURITY.md` call out the service and wrapper
  translations that require review.
- FHS compatibility paths are deliberate.  They are the bridge between Qubes VM
  agent expectations and Guix store/profile paths.

## Validation Tied To This Mapping

- `tests/builder-hook-contract-check.sh` executes the Guix Builder hooks
  against a temporary install tree.
- `tests/builder-rpm-contract-check.sh` feeds generated root images through
  the Builder v2 RPM adapter and validates the resulting template RPM metadata
  and payload.
- `tests/rpm-layout-check.sh` builds and extracts normal and minimal template
  RPM layouts.
- `VALIDATION.md` records patch application against fresh Builder v2 and
  release-config checkouts, focused Builder v2 distribution tests, and
  release-config YAML validation.

This precedent map does not replace full Qubes runtime validation.  It only
shows that the local scaffolding is shaped for the Qubes template-builder review
model rather than as an opaque local RPM script.
