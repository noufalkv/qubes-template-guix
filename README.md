# Qubes Guix Template

This repository builds and tests a native GNU Guix System TemplateVM for Qubes
OS.  The template root filesystem is produced by Guix, while Qubes dom0 supplies
the VM kernel.  QubesDB, qrexec, shutdown, private-volume persistence, and GUI
agent startup are mapped to Shepherd services.

There are two native variants, mirroring the normal/minimal split used by
official Qubes templates:

- `normal`: Qubes GUI support, Xorg, and `xfce4-terminal`.
- `minimal`: Qubes GUI support, Xorg, and `xterm`.

A secondary fallback path can clone an existing Debian/Fedora template and
install GNU Guix as a foreign package manager.  That path is useful for quick
experiments but is not the native Guix System template.

Reviewer entry points:

| Need | File |
| --- | --- |
| Short first-pass reviewer guide | `REVIEWER_GUIDE.md` |
| Publication gap and release-readiness checklist | `UPSTREAMING.md` |
| Maintainer-oriented review map | `REVIEW_NOTES.md` |
| Latest validation evidence and missing gates | `VALIDATION.md` |
| Prompt-to-artifact completion audit | `SUBMISSION_AUDIT.md` |
| Package/service adaptation rationale | `ADAPTATION_INVENTORY.md` |
| Security-review framing | `SECURITY.md` |
| Editable upstream submission drafts | `SUBMISSION_DRAFTS.md` |
| Qubes template-builder precedent mapping | `TEMPLATE_PRECEDENTS.md` |
| Maintainer, update, signing, rollback, and handoff model | `MAINTENANCE.md` |
| Contribution workflow and required checks | `CONTRIBUTING.md` |
| Suggested human review order | `PATCH_SERIES.md` |

## Quick Path: Guix Inside an Existing Template

Run this from dom0:

```sh
./scripts/create-foreign-guix-template-dom0.sh \
  --base debian-13-minimal \
  --name guix-debian-13
```

If the base template does not exist, omit `--base` and the script will choose
the first available Debian/Fedora template from its known list.

After creation, run the test script from dom0:

```sh
./scripts/test-foreign-guix-template-dom0.sh guix-debian-13
```

For a heavier substitute/build smoke test:

```sh
./scripts/test-foreign-guix-template-dom0.sh --build-hello guix-debian-13
```

## Native Guix System Track

The native tree contains:

- `native/qubes-guix.scm`: normal TemplateVM variant.
- `native/qubes-guix-minimal.scm`: minimal TemplateVM variant.
- `native/modules/qubes/systems/guix-template.scm`: shared operating-system
  definition for both variants.
- `native/modules/qubes/packages/qubes-vm.scm`: first-pass Guix package
  definitions for the Qubes VM-side components.
- `native/modules/qubes/services/qubes-vm.scm`: Shepherd service definitions
  for QubesDB, qrexec, persistence, and GUI agent wiring.

Both variants are intentionally lean.  They keep the runtime needed for Qubes
VM integration and GUI application forwarding, but omit ssh, DHCP, default
gettys, and other non-Qubes desktop extras.  Like the standard Qubes templates,
they keep default privileged helpers and passwordless sudo for the Qubes user.

Build the normal variant on a host with Guix installed:

```sh
./scripts/build-native-rootfs.sh --variant normal --output root.img
```

Build the minimal variant:

```sh
./scripts/build-native-rootfs.sh --variant minimal --output root-minimal.img
```

Inspect each root image before importing it into dom0:

```sh
./scripts/inspect-native-rootfs.sh \
  --image root.img \
  --expect-command xfce4-terminal \
  --expect-command Xorg \
  --expect-desktop xfce4-terminal.desktop

./scripts/inspect-native-rootfs.sh \
  --image root-minimal.img \
  --expect-command xterm \
  --expect-command Xorg \
  --expect-desktop xterm.desktop
```

Build a Qubes Template Manager compatible package:

```sh
./scripts/package-native-template-rpm.sh \
  --root-image root.img \
  --name guix \
  --version 20260509

./scripts/package-native-template-rpm.sh \
  --root-image root-minimal.img \
  --name guix-minimal \
  --version 20260509
```

The package payload follows Qubes Template Manager layout under
`/var/lib/qubes/vm-templates/NAME/`: split `root.img.part.NN` files,
`template.conf`, appmenu allowlists, app directories, and Qubes template image
ghosts.  Packages advertise `qrexec=1`, `gui=1`, and `virt-mode=pvh`.  The
normal package defaults to `xfce4-terminal.desktop` in the appmenu allowlists;
the minimal package defaults to `xterm.desktop`.  The packager runs an ext4
shrink pass before splitting `root.img`, so the RPM contains the minimum
filesystem size for the built template instead of the larger staging image
size.  Use `--no-shrink` only when inspecting an exact staging image.
The package source payload is world-readable because `qvm-template-postprocess`
executes `qvm-appmenus` as the dom0 user while reading the extracted appmenu
allowlists from a temporary directory.

For direct `qvm-volume import` testing, qvm-template metadata and appmenus are
not set as dom0 features; the smoke test verifies behavior.  Feature metadata
and appmenu allowlists belong to the Template Manager package payload.

Import attempt, from dom0:

```sh
./scripts/import-native-rootfs-dom0.sh --image root.img --name guix-native-test
```

The native path is deliberately staged. First prove the imported TemplateVM and
a disposable test AppVM can start, speak QubesDB, and complete qrexec calls:

```sh
./scripts/test-native-guix-template-dom0.sh --template guix-native-test
```

For deeper dom0 integration testing, the test script can run selected Qubes
system tests using the same `QUBES_TEST_TEMPLATES` mechanism used by Qubes'
openQA jobs.  The default `--run-system-tests` set uses Qubes' official qrexec
and `vm_qrexec_gui` modules, which exercise the tested template directly:

```sh
./scripts/test-native-guix-template-dom0.sh \
  --template guix-native-test \
  --expect-command xfce4-terminal \
  --expect-command Xorg \
  --expect-desktop xfce4-terminal.desktop \
  --run-system-tests
```

Minimal variant smoke tests should pass `--expect-command xterm` instead of
`xfce4-terminal`.

## Nested Qubes dom0 Test VM

On a bare-metal Linux host with KVM and nested VMX, this repository can build a
throwaway Qubes dom0 VM and import the native Guix root image into it:

```sh
./scripts/qubes-nested-dom0-host.sh download
./scripts/qubes-nested-dom0-host.sh prepare
./scripts/qubes-nested-dom0-host.sh install
./scripts/qubes-nested-dom0-host.sh start
./scripts/qubes-nested-dom0-host.sh import-test
```

The helper uses the same basic QEMU shape as Qubes' openQA jobs: q35,
`host,+vmx,+invtsc`, SCSI disk, and an e1000e NIC. Defaults are intentionally
large enough for a nested dom0 plus test qubes: 120G disk, 32G RAM, and 8 vCPUs.
Override them with `QUBES_NESTED_*` environment variables if needed.

## openQA Test

The native TemplateVM path also has a dedicated openQA harness. On a host with
openQA installed, a completed nested Qubes dom0 qcow2, and a Guix `root.img`,
schedule the normal direct-image job with:

```sh
GUIX_EXPECT_COMMANDS='xfce4-terminal Xorg' \
GUIX_EXPECT_DESKTOPS='xfce4-terminal.desktop' \
  ./scripts/setup-openqa-guix-template-test.sh --wait
```

Minimal direct-image job:

```sh
QUBES_OPENQA_GUIX_ROOT_IMAGE=root-minimal.img \
QUBES_OPENQA_GUIX_ASSET=guix-minimal-root.img \
QUBES_OPENQA_TEMPLATE_NAME=guix-minimal-openqa-test \
QUBES_OPENQA_APPVM_NAME=guix-minimal-openqa-test-app \
GUIX_EXPECT_COMMANDS='xterm Xorg' \
GUIX_EXPECT_DESKTOPS='xterm.desktop' \
  ./scripts/setup-openqa-guix-template-test.sh --wait
```

The setup script overlays `openqa/qubesos/` onto Qubes' own openQA test suite,
copies the nested dom0 and Guix root images into openQA's HDD asset pool,
configures a local worker, schedules a direct `guix_template` job, and waits for
the job when `--wait` is provided. The job boots Qubes dom0, imports the Guix
root disk as a TemplateVM, creates a test AppVM, and runs the same qrexec,
QubesDB, shutdown, private-volume, `/home`, and `/usr/local` persistence smoke
tests as `scripts/test-native-guix-template-dom0.sh`.

RPM-mode jobs exercise `qvm-template --yes install --nogpgcheck` against the
generated package, including Qubes Template Manager post-install handling:

```sh
GUIX_INSTALL_MODE=rpm \
QUBES_OPENQA_GUIX_TEMPLATE_RPM=dist/qubes-template-guix-20260509-1.noarch.rpm \
GUIX_EXPECT_COMMANDS='xfce4-terminal Xorg' \
GUIX_EXPECT_DESKTOPS='xfce4-terminal.desktop' \
  ./scripts/setup-openqa-guix-template-test.sh --wait
```

Set `GUIX_RUN_QUBES_SYSTEM_TESTS=1` to run the optional Qubes dom0 integration
tests after the template smoke test.  By default this runs
`qubes.tests.integ.qrexec:14400` and
`qubes.tests.integ.vm_qrexec_gui:14400`, using the same modules as Qubes'
official `system_tests_qrexec` and `system_tests_vm_qrexec_gui_pipewire`
scenarios.  Set `GUIX_QUBES_SYSTEM_TESTS` explicitly to run broader host-level
suites such as the full `system_tests_basic_vm_qrexec_gui` module list.
The dom0-side script follows Qubes' openQA runner shape with
`nose2 --plugin nose2.plugins.loader.loadtests`; if `nose2` is missing, it
installs `python3-nose2` before running those optional tests.  Before invoking
nose2, the serial harness sets the imported Guix template as dom0's
`default_template` and runs the tests with root privileges, while preserving the
normal dom0 user's home, display, and `XDG_RUNTIME_DIR`, matching the
environment Qubes' GUI xterm-based openQA path gives to `sudo -E nose2`.  The
serial openQA smoke harness runs that nose2 command directly with unbuffered
output instead of wrapping it in `script(1)`, because `script(1)` can stop
itself under the non-interactive serial pipeline before nose2 starts.  For
nested dom0 images without a configured UpdateVM, the openQA scheduler stages a
Fedora 41 `python3-nose2` RPM as an offline test asset and passes it to the dom0
script.

The harness refreshes the openQA HDD assets before each scheduled run. This is
required because the nested Qubes job disables QEMU snapshots for host-CPU
nested virtualization, making the openQA asset copy mutable during the test.
On the openQA host, `scripts/watch-openqa-guix-job.sh` shows the latest running
job state and streams only newly appended bytes from the live `autoinst`,
serial, and worker logs.

For an end-to-end release check that mirrors the normal and minimal package
split, use `scripts/run-openqa-template-rpm.sh`.  It builds the selected
Guix System root image, inspects the
mounted image for the
variant-specific terminal and Xorg support, runs the writable-root activation
test described below, packages the Qubes Template Manager RPM, schedules the
RPM-mode openQA job, and can stream the job logs:

```sh
./scripts/run-openqa-template-rpm.sh \
  --variant normal \
  --version 20260510 \
  --release 1 \
  --watch

./scripts/run-openqa-template-rpm.sh \
  --variant minimal \
  --version 20260510 \
  --release 1 \
  --watch
```

Equivalent Make targets are available for the two release smoke gates:

```sh
make openqa-template-rpm-normal
make openqa-template-rpm-minimal
```

Those smoke gates are the default package validation path in nested cloud
infrastructure: they build the real rootfs, exercise the activation script and
PAM stacks on a writable root image, install the RPM through Qubes Template
Manager in nested dom0, create a TemplateVM and AppVM, and verify QubesDB,
qrexec, private-volume persistence, `/home`, `/usr/local`, shutdown, and the
variant-specific GUI/appmenu surface.  The RPM-mode job also runs
`scripts/test-guix-update-proxy-config-dom0.sh` against the installed TemplateVM
so generated Guix daemon/client proxy configuration is covered by the same
runtime smoke path.

The optional Qubes system-test modules can be run with `--run-system-tests` or
`make openqa-template-rpm-system-tests VARIANT=normal`.  They use the same
official `nose2 --plugin nose2.plugins.loader.loadtests` runner and module
names described above, but they create additional test qubes.  On cloud hosts
where Qubes dom0 is already nested under KVM, those additional inner-Xen VM
starts can fail with `libxenlight failed to create new domain`; treat that as a
host-capability result unless the preceding RPM smoke gate also fails.

For a dom0 or nested-dom0 lifecycle check outside openQA, use:

```sh
./scripts/test-template-rpm-lifecycle-dom0.sh \
  --rpm /path/to/qubes-template-guix-4.3.0-RELEASE.noarch.rpm \
  --replace-existing \
  --run-smoke
```

That script exercises local RPM install, reinstall, optional upgrade/downgrade
RPMs, removal, and optional TemplateVM/AppVM smoke tests.

After booting a built template, verify the Guix-specific updates-proxy
configuration separately:

```sh
./scripts/test-guix-update-proxy-config-dom0.sh --template guix
```

That check confirms the Qubes service flag, generated `guix` wrapper, and
`guix-daemon` proxy environment.  A release candidate should still run a real
Guix update or download command through the Qubes proxy before submission:

```sh
./scripts/test-guix-update-proxy-download-dom0.sh \
  --template guix \
  --download-url https://guix.gnu.org/
```

The download check depends on an update-proxy target with working Internet
access.  The openQA harness stages the same script and runs it only when
`GUIX_RUN_PROXY_DOWNLOAD_TEST=1` is set, so ordinary local RPM smoke does not
silently depend on public network availability.

## Local Checks

These checks run in a normal VM and do not require dom0 or Guix:

```sh
make check
```

`make check` runs contract checks only.  It executes the Builder content hooks
against a temporary install tree, packages tiny normal and minimal ext4 root
images through the Builder v2 RPM adapter, validates the generated
`qvm-template` metadata, then builds and extracts template RPMs through the real
packager, verifies the Qubes Template Manager payload layout, and reassembles
the split root image.  These checks exercise generated artifacts and externally
visible package contracts, not source-code pattern matching.

`make check` fails if the tools required for those package-contract checks are
missing.  It intentionally does not include source-pattern or patch-sketch
checks as substitute evidence for a working template.

The runtime-focused root image check is
`scripts/test-native-rootfs-activation.sh`.  It mounts a writable copy of the
root image, runs the generated Guix activation script in a chroot, verifies that
generated `/etc/pam.d` and `/etc/skel` are materialized correctly, checks qrexec
PAM with libpam, verifies that `qubes.PostInstall` is configured to run as
root, and simulates qrexec's login-shell wrapper for `qubes.VMShell` as both
`root` and `user`.

The local checks exercise local contracts, but they are not release-quality
validation by themselves.  A package change still needs the native rootfs
build, root image inspection, activation test, real RPM layout test, RPM
packaging, RPM-mode openQA install, TemplateVM and AppVM smoke tests, and the
optional Qubes dom0 integration tests.
