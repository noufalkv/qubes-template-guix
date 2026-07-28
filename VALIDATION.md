# Validation Snapshot

This file records evidence for the native GNU Guix System Qubes TemplateVM
prototype.  It is not Qubes acceptance or publication evidence.

Evidence that matters for this repository is generated artifacts, rootfs
activation, qvm-template lifecycle behavior, openQA jobs, and live TemplateVM or
AppVM behavior.  Local maintenance commands are not runtime evidence.

## Current Source State

- `.guix-channel` and `modules/qubes/packages.scm` make this repository a Guix channel for
  Qubes VM package and service definitions.
- The per-interface network sysctl hardening is defined once in
  `qubes-network-sysctl-helper-forms` (`modules/qubes/packages.scm`) and shared by all
  four appliers (boot all-interfaces, managed-uplink startup, managed-uplink
  hotplug reconfiguration, and the generated
  `qubes-network-interface-sysctl` vif helper), replacing duplicated implementations.
  Those writers now fail loudly when an existing `/proc` sysctl path cannot be
  written (missing paths are still skipped), instead of silently swallowing the
  error.  A `verify-network-sysctl-table` build phase errors if
  `%qubes-network-sysctl-settings` drifts from upstream
  `network/81-qubes.conf.optional`, so a component bump that changes the table
  breaks the build with a re-sync message instead of shipping stale hardening.
- The two `init/functions` home-skeleton adaptations are combined into one
  fail-loud `adapt-guix-skel-in-home-init` phase with separate anchors.
- `config/qubes-os-normal.scm` and `config/qubes-os-minimal.scm` are the
  per-variant configurations and are installed as `/etc/config.scm`.  Generated
  images also install the channel module under `/etc/qubes-guix-channel`.
- `config/channels.scm` follows the authenticated `master` branch at Guix's
  official Codeberg channel URL with no commit pin, so template generation
  refreshes to the current branch head.
- `scripts/build-native-rootfs.sh` runs build-scoped authenticated
  `guix pull -p <temporary-profile> --allow-downgrades -C
  config/channels.scm`, then builds with the refreshed Guix command.
- Checkout/file-channel rewrites, unauthenticated channel paths,
  branch-only fallback, custom channel-file override, custom checkout toggle,
  and custom pull-profile toggle are removed.
- The installed template retains `/etc/guix/channels.scm`, sourced from
  `config/guix-channels.scm`, with the same authenticated, unpinned Codeberg
  Guix `master`, so users can update Guix and this Qubes channel.  The builder's
  temporary pull profile is not copied into the image; root/user `current-guix`
  and per-user `current-guix-*` links created during image initialization are
  removed.
- `make check-qubes-pins` passed on July 22, 2026 after refreshing
  `qubes-linux-utils` to `v4.3.18`, `qubes-core-qubesdb` to `v4.3.3`,
  `qubes-core-agent-linux` to `v4.3.46`, and `qubes-gui-agent-linux` to
  `v4.3.18`.
- Normal appmenus are sourced from
  `builder-v2-template/appmenus_guix/whitelisted-appmenus.list`.
- Minimal appmenus are sourced from
  `builder-v2-template/appmenus_guix_minimal/whitelisted-appmenus.list`.
  Each directory provides relative VM and NetVM aliases to its canonical list,
  matching Builder v2's directory lookup while avoiding duplicate allowlists.
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
- The in-template `guix pull` through the Qubes updates proxy must be validated
  externally via Qubes' existing openQA and integration infrastructure; that
  final integration gate remains pending.
- G-OPEN-2 (updates-proxy): local half done (`http_proxy`/`https_proxy`
  exported to the updates-proxy forwarder when the `updates-proxy-setup` flag is
  set; the export sits behind the flag guard in
  `modules/qubes/services.scm`, so the flag-absent path and `guix-daemon`
  itself stay unproxied per `%qubes-base-services`).  Full closure DEFERRED
  pending qubes-core-admin-linux#211 upstream (vmupdate guix backend:
  `guix pull` → `guix system reconfigure`) + L4 openQA evidence that
  `bordeaux.guix.gnu.org`/`ci.guix.gnu.org` is reachable through the proxy.

`config/channels.scm` no longer names a fixed Guix commit.  Release evidence
must therefore record the resolved Guix revision used for each build and verify
that it contains required fixes such as `libgit2-proxy-reconnection.patch` for
`guix/guix#87`.  The revision recorded on May 29, 2026 contained that fix and
matched the remote `master` ref at the time.  Older SSL/proxy failures against
the removed checkout rewrite should be treated as historical unless reproduced
with the current authenticated channel path.

## Local Check Coverage

`make check` is the aggregate functional target.  It runs `make source-check`
followed by `make artifact-check`.

`make source-check` covers:

- Bash syntax for shell sources;
- Python unit tests for bounded request parsing, repository metadata/download
  handling, and output validation in `qvm-template-repo-query-guix.py`;
- the Builder v2 content lookup and appmenu-directory contract;
- use of the shared fail-loud network sysctl helpers by the hotplug path;
- rejection of unsafe RPM version/release metadata;
- atomic, mode-preserving Qubes pin refreshes, including concurrent-edit and
  hash-failure cleanup paths; and
- bounded local-publisher identity and asynchronous-bake checks, including
  delayed success, timeout, malformed-not-found, and publisher-death paths;
  preservation of an existing substitute-cache publication across failures;
  and atomic replacement on success.

`make artifact-check` runs `tests/builder-rpm-contract-check.sh` and
`tests/rpm-layout-check.sh`.  Those checks build normal and minimal RPM
artifacts through the local Builder adapter and native packager, validate Qubes
Template Manager metadata/layout, extract payloads through
`tests/template-rpm-payload-check.sh`, and verify the reassembled split root
images byte-for-byte against their source images.

`make lint` is separate from `make check`: it runs ShellCheck over the shell
sources and Ruff over the Python helper and tests.

The Builder v2 content-contract test uses an offline fixture of the resource
lookup order from a recorded upstream Builder v2 revision.  It validates this
repository's content-tree shape and copy semantics; it neither downloads nor
executes upstream Builder v2.  The Builder adapter artifact test likewise
invokes the local adapter, not the upstream plugin.  These local source,
contract, and artifact checks do not replace an actual Builder v2 run, openQA,
qvm-template lifecycle checks, or live VM behavior.

On July 22, 2026, `make check` and `make lint` passed from the frozen review
tree.  The Guix rpm-md helper also queried both the enabled official
R4.3 stable repository and the disabled testing repository selected explicitly
with `--repoid`; both returned valid template rows with a clean exit.  This is
live metadata/protocol evidence, not a qrexec download, RPM-signature, install,
or runtime test.

`make check-qubes-pins` is intentionally separate from `make check` because it
queries live upstream tags.  The July 22, 2026 pass records source-pin
freshness at that point in time; it must be rerun for each release candidate
and is not runtime evidence.

## Generated Artifact Coverage

On May 29, 2026, on an x86_64 Guix build host, both variants were generated and
checked end to end from the source state recorded at that time:

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
  (`qubes-template-guix-4.3.0-*`, `qubes-template-guix-minimal-4.3.0-*`); those
  RPMs were rebuilt from those images and pass
  `tests/rpm-layout-check.sh`.
- Each built image carries `/etc/guix/channels.scm` (single source in
  `config/guix-channels.scm`; the `guix-configuration` channels duplication was
  removed), the flat rendered `/etc/config.scm`, and the channel modules under
  `/etc/qubes-guix-channel/modules/qubes/`.
- The operating-system used stock `grub-bootloader` with `--no-bootloader` at
  that historical revision.  The current source instead inherits that record
  as `qubes-external-bootloader`, retaining generated `grub.cfg` while making
  only the installer a no-op so in-template reconfiguration cannot attempt
  `grub-install`.
- Runtime execution was exercised in a chroot of the May 29 normal image:
  `pipewire`, `wireplumber`, and `python3` run; the Qubes audio module's shared
  libraries resolve in-image; the `qubes-pipewire-start` launcher is executable;
  and `xterm.desktop`, `nano`, `zenity`, the qrexec autostart entry, and the
  Thunar `uca_qubes.xml` are present.  The Guix initrd was also confirmed to
  boot under QEMU (early-boot Guile runs and searches for the `guix-root`
  label); a full standalone QEMU boot is not representative because the template
  is booted by the dom0-supplied kernel and Qubes volume attachment.

That May 29 normal image was also booted to userspace under QEMU (host CPU,
virtio root by `guix-root` label, the image's own system loaded via
`gnu.load`).  The serial log shows the Guix boot program run, `/etc` populated
from the system's etc closure, privileged programs set up, `/etc/machine-id`
created, then **GNU Shepherd 1.0.9 running as PID 1**, loading its
configuration and starting services: `root`, `root-file-system`, `host-name`
(value `"guix-qubes"`), and `pam`, followed by `eudev` starting.  This is live
boot-to-userspace evidence for that historical artifact; full GUI/audio/qrexec
behavior still requires a real Qubes dom0 (and AudioVM) and remains a
publication gate.

This is historical generated-artifact evidence from earlier working trees.
Release evidence must still be reproduced from the exact final public branch or
tag.

Source hygiene commands also passed locally on May 29, 2026:

- `bash -n scripts/*.sh tests/*.sh builder-v2-template/*.sh`;
- `git diff --check`.

These commands only catch source-level breakage.  They do not replace generated
artifact checks or runtime gates.

## Official openQA Integration Testing

### Historical run, May 31, 2026 (both variants, branch `quality-refactor` @ `fa2b4a5`)

The authoritative L4 run for both variants from the historical branch state at
`fa2b4a5` used the official `openqa-clone-job` flow (not `isos post`; the host
has no products configured).  Test source `QubesOS/openqa-tests-qubesos` was
unmodified, with casedir pinned at `4a652e3`.  Full evidence:
`.omo/evidence/task-14-openqa/`.

RPMs under test (built on the dev host from that commit, release
`202605310444`; `make template-rpm-{normal,minimal}` ran build -> inspect ->
writable-root activation -> package, both exiting 0):

- `qubes-template-guix-4.3.0-202605310444.noarch.rpm` —
  sha256 `7a953e5c02d86aebfbb0c7f1854e786d98ea874f1590293f6d1fb0b36a883ca2`.
- `qubes-template-guix-minimal-4.3.0-202605310444.noarch.rpm` —
  sha256 `368b653761091cac3cecad79cf672ec0b03dcd10b5b653731e2f3f58b11465f2`.

Served to the nested dom0 from a DIRECT, non-redirecting HTTP server at
`http://10.0.2.2:8080/` (the pinned `update_templates.pm` curls with no `-L`).
Overrides: `DISTRI=qubesos VERSION=4.3 flavor=templates TEST_TEMPLATES=<variant>
SYSTEM_TESTS="qubes.tests.integ.network:21600 qubes.tests.integ.audio:10800"
QEMURAM=12288 QEMUCPUS=6`.  Eight jobs were run (156-164) to isolate harness
couplings; canonical per-variant rows are **job 164 (guix)** and **job 163
(guix-minimal)**, corroborated by jobs 158/160 (guix).

Pass criterion for this run (per plan): "both variants install + execute the
network/audio suite path to the SAME point as the prior recorded run, with no
NEW regression."  NOT "all green."  Result against that criterion: **met for
install + suite-setup; nose2 case execution was blocked by host/harness limits,
identical to the baseline (no new regression).**

Module-level results (openQA `jobs/<id>/details`, the authoritative phase
verdicts; JUnit-equivalent in `task14-module-results.xml`):

- **Install (`update_templates`) PASSED for BOTH variants.**  The official
  `qvm-template install --nogpgcheck` of the FRESH RPM ran to completion from
  the direct URL: guix job 164 (387 s; also jobs 158, 160) and guix-minimal job
  163 (303 s).
- **guix `switch_template` PASSED** (job 158): official switch to
  `fedora-43-xfce` early-exits cleanly.
- **guix `system_tests` reached the SAME stop point as the prior baseline.**
  Job 164 read `convert_junit.py` + `split_logs.py` from `/root/extra-files`,
  then died at the unconditional `pactl set-sink-mute 0 0` (`system_tests.pm:46`)
  because the nested dom0 has no PulseAudio sink 0.  The prior recorded baseline
  job 149 died at the EXACT same `pactl set-sink-mute 0 0` command.  =>
  **No NEW regression** vs the prior run; `nose2` was not reached this round, so
  no `nose2-junit-*.xml` was produced (there are currently 0 such files on the
  host — the present dom0 image's `pactl` step blocks every run, baseline
  included).
- **guix-minimal `system_tests` was blocked at harness setup**, not by the
  template: `system_tests_prepare_minimal.pm:83` hard-`die`s "Template
  guix-minimal not supported by this module" because the harness's minimal
  test-dep installer only handles `fedora` (dnf) / `debian` (apt).  This is the
  §4 `zsystemtests.py` Guix gap mirrored in the minimal-prep module; it needs
  upstream Guix support in openqa-tests-qubesos and must not be patched locally.

Timezone (HEAD `fa2b4a5` "Apply dom0 timezone via a writable path"): the casedir
has NO dom0-timezone-propagation integ test (only `install_oem.pm`, an OEM-install
flow).  This change therefore has **no L4 coverage** in openQA — it was neither
passed nor failed here (not exercised).  Lower-layer evidence is recorded under
`.omo/evidence/task-11-*`.

G-OPEN-2 (updates-proxy / central vm-update): **NOT closed; no proxy success.**
Job 156's central `qubes-vm-update --targets=guix` was reached and the update
agent executed, but aborted at `zsystemtests.py:76 AssertionError`
(`COMMAND_EXIT_CODE=26`) — the test-dep installer has no Guix backend — BEFORE
any `guix pull`/substitute fetch.  It therefore did NOT reach or resolve
`bordeaux.guix.gnu.org` / `ci.guix.gnu.org` through `qubes.UpdatesProxy`.  The
substitute path remains UNPROVEN end-to-end.  Evidence:
`task14-156-qubesctl-upgrade.log`.

The 7 in-tree "fixed" gaps are NOT claimed closed by this run.

### Earlier run, May 29-30, 2026

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
- fresh `make check`, `make lint`, and `make check-qubes-pins` from the final
  public branch or release tag;
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
