# Validation Snapshot

This file records evidence for the native GNU Guix System Qubes TemplateVM
prototype.  It is not Qubes acceptance or publication evidence.

Evidence that matters for this repository is generated artifacts, rootfs
activation, qvm-template lifecycle behavior, openQA jobs, and live TemplateVM or
AppVM behavior.  Local maintenance commands are not runtime evidence.

## Current Source State

- `.guix-channel` and `modules/qubes/packages.scm` make this repository a Guix channel for
  Qubes VM package and service definitions.
- `config/qubes-os-normal.scm` and `config/qubes-os-minimal.scm` are the configurations;
  per variant and installed as
  `/etc/config.scm`.  Generated images also install the channel module under
  `/etc/qubes-guix-channel`.
- `config/channels.scm` pins Guix commit
  `9873d2c433b7dc8e2d510fc437c5b13c98d0a4ff` from Guix's official Codeberg channel URL
  for template generation.
- `scripts/build-native-rootfs.sh` runs build-scoped authenticated
  `guix pull -p <temporary-profile> --allow-downgrades -C
  config/channels.scm`, then builds with the refreshed Guix command.
- Checkout/file-channel rewrites, unauthenticated channel paths,
  branch-only fallback, custom channel-file override, custom checkout toggle,
  and custom pull-profile toggle are removed.
- The installed template removes `/etc/guix/channels.scm`, root
  `current-guix`, user `current-guix`, and per-user `current-guix-*` links.
- `make check-qubes-pins` passed on May 29, 2026 against current R4.3 tags
  after refreshing `qubes-core-agent-linux` to `v4.3.44` and
  `qubes-gui-agent-linux` to `v4.3.17`.
- Normal appmenus are sourced from `builder-v2-template/appmenus.list`.
- Minimal appmenus are sourced from
  `builder-v2-template/appmenus-minimal.list`.
- Template RPM generation is independent of any test harness; integration
  testing is delegated to Qubes OS's existing openQA suite (external to this
  repo).
- The normal template provides Qubes audio: the new `pipewire-qubes` package
  builds `libpipewire-module-qubes.so` from the pinned `qubes-gui-agent-linux`
  source against Guix `pipewire`, `qubes-libvchan-xen`, and `qubesdb-vm`, and
  installs the `30_qubes.conf` PipeWire drop-in plus an XDG autostart launcher
  that starts `pipewire`/`pipewire-pulse`/`wireplumber` in the GUI session.
  The minimal template, like Qubes' own minimal templates, omits audio.
- The package baseline uses Guix `%base-packages` for the standard CLI/userland
  baseline.  `glibc` (for `getent`, used by Qubes' private-volume home setup)
  and `python` (the `python3` interpreter Qubes qrexec/vmexec agents run with)
  are added explicitly because they are not part of `%base-packages`.  No
  standalone `guile` is listed: the `guix` package propagates its own guile,
  and adding a second one made the system profile contain two conflicting
  `guile` entries.
- The in-template `guix pull` through the Qubes updates proxy is validated
  externally via Qubes' existing openQA and integration infrastructure.
- G-OPEN-2 (updates-proxy): local half done (`http_proxy`/`https_proxy`
  exported to the updates-proxy forwarder when the `updates-proxy-setup` flag is
  set; the export sits behind the flag guard in
  `modules/qubes/services.scm`, so the flag-absent path and `guix-daemon`
  itself stay unproxied per `%qubes-base-services`).  Full closure DEFERRED
  pending qubes-core-admin-linux#211 upstream (vmupdate guix backend:
  `guix pull` → `guix system reconfigure`) + L4 openQA evidence that
  `bordeaux.guix.gnu.org`/`ci.guix.gnu.org` is reachable through the proxy.

The current Guix pin contains the upstream libgit2 proxy redirect fix,
`libgit2-proxy-reconnection.patch`, for `guix/guix#87`.  The pinned commit
matched the remote `master` ref on May 29, 2026.  Older SSL/proxy failures
against the removed checkout rewrite should be treated as historical unless
reproduced with the current authenticated channel path.

## Local Artifact Coverage

`make check` passed locally on May 29, 2026 after the builder/appmenu, channel,
openQA decoupling, import cleanup, and script-entry cleanup.  That command
runs:

- `tests/builder-rpm-contract-check.sh`;
- `tests/rpm-layout-check.sh`.

Those checks build normal and minimal RPM artifacts through the Builder adapter
and native packager, validate Qubes Template Manager metadata/layout, extract
payloads through `tests/template-rpm-payload-check.sh`, and verify the
reassembled split root images byte-for-byte against their source images.

This is artifact evidence only.  It does not replace openQA, qvm-template
lifecycle checks, or live VM behavior.

`make check-qubes-pins` also passed locally against the current upstream Qubes
R4.3 tag state.  That records source pins; it is not runtime evidence.

## Generated Artifact Coverage

On May 29, 2026, on an x86_64 Guix build host, both variants were generated and
checked end to end from the current source state:

- `guix system build` of the full system profile succeeded for both the normal
  and minimal variants (this builds the profile union, which is where package
  collisions surface; it caught and confirmed the fix for a `guile` profile
  collision).
- `scripts/build-native-rootfs.sh` produced normal (`root.img`) and minimal
  (`root-minimal.img`) ext4 root images.
- `scripts/inspect-native-rootfs.sh` passed for both variants, confirming the
  expected profile payload (including `bin/python3`), Qubes compatibility
  paths, variant commands, and variant desktop entries with present icons.
- `scripts/test-native-rootfs-activation.sh` passed for both variants,
  exercising writable-root activation through Qubes' `initialize_home`
  private-volume home setup (the path that requires `getent`).
- `scripts/package-native-template-rpm.sh` produced both qvm-template RPMs:
  `qubes-template-guix-4.3.0-*` and `qubes-template-guix-minimal-4.3.0-*`.
- The normal image was confirmed to contain the PipeWire Qubes audio module
  (`lib/pipewire-0.3/libpipewire-module-qubes.so`), the `30_qubes.conf`
  drop-in, the audio autostart entry, `pipewire`, and `wireplumber`.

After the channel split, channel authentication, and bootloader changes, both
variants were rebuilt and re-checked end to end on the same host on
May 29, 2026:

- The channel is now split into `modules/qubes/{packages,services,system}.scm`
  with a `(qubes vm)` re-export umbrella; with `(directory "modules")` in
  `.guix-channel`, all four modules byte-compile and an authenticated
  `guix pull` of the channel (keyring branch + signed introduction commit)
  succeeds and exposes `(qubes vm)` to a pulled config.
- Each variant's `config.scm` uses `qubes-operating-system`,
  builds (`guix system build`), produces a root image, passes inspection and
  writable-root activation, and is packaged into a qvm-template RPM
  (`qubes-template-guix-4.3.0-*`, `qubes-template-guix-minimal-4.3.0-*`); the
  final RPMs were rebuilt from these final images and pass
  `tests/rpm-layout-check.sh`.
- Each built image carries `/etc/guix/channels.scm` (single source in
  `config/guix-channels.scm`; the `guix-configuration` channels duplication was
  removed), the flat rendered `/etc/config.scm`, and the channel modules under
  `/etc/qubes-guix-channel/modules/qubes/`.
- The operating-system uses the stock `grub-bootloader` built with
  `--no-bootloader` (no boot code is installed); a custom no-op bootloader was
  found to make `guix system init` copy an empty store closure, so it was
  dropped.
- Runtime execution was exercised in a chroot of the final normal image:
  `pipewire`, `wireplumber`, and `python3` run; the Qubes audio module's shared
  libraries resolve in-image; the `qubes-pipewire-start` launcher is executable;
  and `xterm.desktop`, `nano`, `zenity`, the qrexec autostart entry, and the
  Thunar `uca_qubes.xml` are present.  The Guix initrd was also confirmed to
  boot under QEMU (early-boot Guile runs and searches for the `guix-root`
  label); a full standalone QEMU boot is not representative because the template
  is booted by the dom0-supplied kernel and Qubes volume attachment.

The final normal image was also booted to userspace under QEMU (host CPU,
virtio root by `guix-root` label, the image's own system loaded via
`gnu.load`).  The serial log shows the Guix boot program run, `/etc` populated
from the system's etc closure, privileged programs set up, `/etc/machine-id`
created, then **GNU Shepherd 1.0.9 running as PID 1**, loading its
configuration and starting services: `root`, `root-file-system`, `host-name`
(value `"guix-qubes"`), and `pam`, followed by `eudev` starting.  This is live
boot-to-userspace evidence for the final artifact; full GUI/audio/qrexec
behavior still requires a real Qubes dom0 (and AudioVM) and remains a
publication gate.

This is generated-artifact evidence from a working tree.  Release evidence must
still be reproduced from the exact final public branch or tag.

Source hygiene commands also passed locally on May 29, 2026:

- `bash -n scripts/*.sh tests/*.sh builder-v2-template/*.sh`;
- `git diff --check`.

These commands only catch source-level breakage.  They do not replace generated
artifact checks or runtime gates.

## Official openQA Integration Testing

On May 29-30, 2026 the template was exercised against Qubes OS's own openQA
integration-test suite, on a nested-virt openQA host, replicating the official
setup rather than any bespoke harness:

- The official `QubesOS/openqa-tests-qubesos` repository is the test source
  (unmodified), pinned to the same upstream commit our reference job used.  Jobs
  were created with the official `openqa-clone-job` from real upstream jobs
  (`CLONED_FROM=https://openqa.qubes-os.org/tests/...`), using the official
  `templates` flavor variables (`DISTRI=qubesos`, `VERSION=4.3`,
  `TEST_TEMPLATES` scoped to the guix template, `TEST=system_tests_*`).
- That harness runs the official Qubes integration suites
  (`qubes.tests.integ.*`: network, audio, storage, grub, salt, dom0_update,
  vm_update, extra) via `nose2`, through the official module chain
  (`startup` -> `switch_template` -> `update_templates` -> `system_tests`).

Install phase (proven): the flow boots a real Qubes R4.3 dom0, passes `startup`
and `switch_template`, reaches `update_templates`, and runs the official
`qvm-template install --nogpgcheck` of the template RPM to completion
(`finished update_templates`).

Test phase (executed): the official `system_tests` module ran
`nose2 -v ... qubes.tests.integ.network` against the guix template to
completion (`finished system_tests`), producing the official JUnit artifact
`nose2-junit-qubes.tests.integ.network.xml` plus per-test logs named for the
template under test (`qubes.tests.integ.network.VmNetworking_guix.test_NNN.*`).

Actual result of `qubes.tests.integ.network.VmNetworking_guix` (27 cases):
most cases reported `test skipped: dnsmasq not installed`, with one genuine
test failure and zero harness errors.  This is a real, informative test verdict,
not an infrastructure artifact: the network suite exercises the template under
test in NetVM/ProxyVM roles, which require `dnsmasq` for the DHCP/DNS path, and
the current guix template does not ship `dnsmasq`.  The actionable follow-up is
to add `dnsmasq` (and revisit the one hard failure) before claiming network-
provider parity; the GUI/AppVM-oriented variants do not need it to function as
ordinary AppVM templates.

Setup adaptations required to drive the official flow on this single host,
none of which modify the harness or the template:

- `DEFAULT_TEMPLATE=fedora-43-xfce` (an existing base template) so the official
  `switch_template` early-exits cleanly; template scoping stays on the guix
  template via `TEST_TEMPLATES`.
- The pinned `update_templates.pm` fetches the RPM with `curl URL` (no `-L`), so
  RPMs are served from a direct, non-redirecting local HTTP server reachable
  from the dom0 as `http://10.0.2.2:8080/...`.
- `QEMURAM=12288 QEMUCPUS=6` (up from the default 8192/2): the leaner default
  left qubesd not ready when `switch_template` polled it and made the ~0.9 GB
  RPM transfer miss the harness's hardcoded 1500 s `curl` timeout; the larger
  allocation makes qubesd ready in time and the download complete in ~7-8 min.
- The dom0 disk's kernel command line was quieted offline
  (`audit=0 loglevel=1 systemd.show_status=0 rd.udev.log_level=3`,
  `journald ForwardToConsole=no`), keeping `console=hvc0`.  Without this, kernel
  audit / journald console noise intermittently corrupted the os-autoinst serial
  exit-code markers that the harness's `script_output` helper parses, causing
  flaky pre-test failures.  This is guest-environment tuning, not a harness edit.

Open caveats:

- The dom0 image used for the executed integ run already carried a guix template
  at an earlier build; on that image the same-name `qvm-template install` is an
  upgrade/no-op rather than a first-time install, so the executed integ run
  validates the template's runtime behavior but not unambiguously the exact
  newest RPM build.  A first-time install on a guix-free base disk is proven
  separately (install phase reaches `qvm-template install`); combining both on
  one image is an infrastructure (dependency-chain / asset-publishing) gap, not
  a template defect.
- These runs are on a single nested-virt worker.  Full multi-flavor green
  coverage of all `qubes.tests.integ.*` suites still needs stable openQA
  infrastructure (bridged/tap networking, the install->publish->test job
  dependency chain) of the kind the Qubes project runs on dedicated workers.

## Known Gaps

The following gates are not closed for publication:

- clean public branch or release tag evidence;
- fresh `make check` and `make check-qubes-pins` from the final public branch or
  release tag;
- fresh normal/minimal root image build, inspection, activation, and RPM
  packaging from that exact source state;
- qvm-template lifecycle reruns for both variants from the final RPMs;
- integration/openQA validation against Qubes OS's existing openQA suite for
  both variants from the final RPMs;
- real Guix download and `guix pull` behavior through an Internet-capable Qubes
  update target;
- passing centralized `qubes-vm-update` evidence with the Guix backend, if that
  backend is submitted;
- Qubes maintainer acceptance of the Builder v2 and release-config pieces;
- publication owner and release metadata.
