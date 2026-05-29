# Maintainer Review Notes

This file is the maintainer map for the native GNU Guix System TemplateVM.  It
lists what the first review is intended to show, where the code lives, and which
claims still need runtime evidence.

Lower-level maps:

- `ADAPTATION_INVENTORY.md`: Guix/Qubes adaptations by file and rationale.
- `SECURITY.md`: trust boundaries and privileged guest behavior.
- `VALIDATION.md`: dated artifact, openQA, and runtime evidence.

## Scope

First review target:

- Qubes OS R4.3;
- x86_64 TemplateVM/AppVM use;
- PVH with dom0-provided kernel and no guest bootloader;
- QubesDB, qrexec, GUI/appmenus, shutdown, private-volume persistence,
  updates-proxy forwarding, standard Qubes swap, guest-side `meminfo-writer`,
  default privileged helpers, and Qubes-style passwordless sudo;
- `guix` and `guix-minimal` variants.

Non-goals for the first review:

- NetVM/ProxyVM/firewall ownership;
- stable community-template publication;
- an opaque prebuilt image submission;
- a Guix store or per-user profile overlay.  None has been added, and no
  overlay design is decided.

## Review Matrix

| Expectation | Local artifact | Current status |
| --- | --- | --- |
| Open-source licensing | `COPYING`, SPDX headers, RPM metadata, Guix package licenses | Present |
| Guix-native implementation | `.guix-channel`, `qubes/vm.scm`, `config/qubes-system.tmpl` | Present; repository channel module plus a rendered `/etc/config.scm` operating-system entrypoint |
| Pinned Guix input | `config/channels.scm`, `scripts/build-native-rootfs.sh` | Present; used for build-scoped authenticated `guix pull`, not installed as root/user state |
| Pinned Qubes sources | `qubes/vm.scm`, `scripts/check-qubes-pins.sh` | Present; freshness check records upstream tag state |
| Builder-shaped pipeline | `Makefile`, `builder-v2-template/`, `scripts/builder-v2-template-adapter.sh` | Present locally; upstream Builder acceptance remains external |
| Qubes release-config sketch | `config/qubes-release-configs-guix.example.patch` | Draft only; publication owner and metadata remain gates |
| Central updater sketch | `config/qubes-core-admin-linux-guix-vmupdate.example.patch` | Draft only; needs fresh central-update runtime evidence |
| Template RPM contract | `scripts/package-native-template-rpm.sh`, `tests/template-rpm-payload-check.sh` | Local artifact checks exercise generated RPM payloads |
| Runtime integration | `qubes/vm.scm`, `config/qubes-system.tmpl`, dom0/openQA scripts, `VALIDATION.md` | Runtime reruns required before publication |
| Maintenance story | `MAINTENANCE.md` | Policy documented; publication owner deferred |
| Security framing | `SECURITY.md`, `ADAPTATION_INVENTORY.md` | Present |

## Patch Review Order

1. Guix package definitions and source pins:
   `qubes/vm.scm`, `scripts/check-qubes-pins.sh`.
2. Runtime service mapping:
   `qubes/vm.scm`.
3. Image and RPM packaging:
   `scripts/build-native-rootfs.sh`,
   `scripts/package-native-template-rpm.sh`,
   `scripts/builder-v2-template-adapter.sh`,
   `tests/template-rpm-payload-check.sh`,
   `tests/builder-rpm-contract-check.sh`, and
   `tests/rpm-layout-check.sh`.
4. Builder content scripts:
   `builder-v2-template/`.
5. Runtime evidence harness:
   `openqa/`, `scripts/test-native-guix-template-dom0.sh`,
   `scripts/test-template-rpm-lifecycle-dom0.sh`,
   update-proxy scripts, central-vmupdate script, and memory-balloon script.
6. Process documents:
   `UPSTREAMING.md`, `MAINTENANCE.md`, `SECURITY.md`,
   `ADAPTATION_INVENTORY.md`, and `VALIDATION.md`.

## Non-Obvious Decisions

- `config/qubes-system.tmpl` is rendered per variant by
  `scripts/render-config.sh` into the `/etc/config.scm` that ships in the image;
  the variant is baked into the rendered file, so there is no runtime variant
  environment variable or marker file.  `/etc/config.scm` imports the installed
  `/etc/qubes-guix-channel` module, so reconfiguration does not depend on the
  builder checkout.
- `config/channels.scm` is a build input only.  It is removed from installed
  root/user Guix state.
- `scripts/build-native-rootfs.sh` writes a generated `/sbin/init` wrapper
  because Qubes enters the guest root at `/sbin/init`, while Guix's boot program
  lives under the system profile.
- Several stock Guix base services are omitted so the TemplateVM does not start
  independent console, login, networking, log rotation, or sysctl policy that
  Qubes owns.
- The template RPM is a Qubes Template Manager payload, not a normal RPM:
  split root image parts, `template.conf`, appmenu allowlists, ghost volumes,
  and a `%pre` guard against direct package-manager installation.
- `scripts/run-openqa-template-rpm.sh` installs the Guix openQA test files and
  assets into an existing openQA host and schedules an already-built RPM.
  Template generation does not depend on it.
- Qubes compatibility links under `/usr`, `/etc/qubes-rpc`, `/usr/lib/qubes`,
  `/run/qubes-service`, and `/var/run/qubes-service-environment` are
  deliberate because upstream Qubes VM tools use fixed FHS-style paths.
- Qrexec and GUI wrappers use `/run/current-system/profile/...` where direct
  store references would break across reconfiguration or reboot.
- QubesDB stays in the foreground so Shepherd supervises the actual process.
- PAM files are provided through Guix `pam-root-service-type`.
- `/etc/fstab` is materialized at activation because Qubes mutates it for
  private volume mounting.
- Qubes private storage follows the standard `/dev/xvdb -> /rw`,
  `/rw/home -> /home`, and `/rw/usrlocal -> /usr/local` model.
- Swap is declared as `/dev/xvdc1`.
- `meminfo-writer` is supervised by Shepherd and honors the standard
  `/run/qubes-service/meminfo-writer` flag.
- The updates proxy remains the Qubes `qubes.UpdatesProxy` model.  Guix update
  operations use an explicit proxy environment, and the central updater sketch
  reuses that path; this does not invent a template-local updater policy.
- Appmenu allowlists use package-provided desktop files.  The only generated
  desktop entry is `xterm.desktop`, because Guix does not provide one.

## Evidence Boundary

`VALIDATION.md` is the source of truth for current evidence and remaining
publication gates.  This file should not repeat that checklist; it only maps
review areas to files and calls out decisions that need maintainer attention.
