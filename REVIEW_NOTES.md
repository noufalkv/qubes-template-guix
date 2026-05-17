# Maintainer Review Notes

This file is the review map for the native GNU Guix System Qubes TemplateVM
work.  It exists so Qubes and Guix reviewers can evaluate the patch set without
reverse-engineering every compatibility decision from shell and Scheme code.
`ADAPTATION_INVENTORY.md` is the lower-level map from Guix/Qubes adaptations to
specific package phases and services.
`SECURITY.md` summarizes the trust boundaries and review-sensitive guest-side
adaptations.
`TEMPLATE_PRECEDENTS.md` maps the Guix Builder hook shape to the existing Qubes
template-builder precedent.

## Scope

Target for the first upstream discussion:

- Qubes OS R4.3.
- x86_64 TemplateVM/AppVM use.
- PVH, dom0-provided kernel, no guest bootloader.
- QubesDB, qrexec, GUI/appmenus, shutdown, private-volume persistence,
  updates-proxy forwarding, standard Qubes swap, guest-side
  `meminfo-writer`, default privileged helpers, and Qubes-style passwordless
  sudo.
- `guix` and `guix-minimal` template variants.

Explicit non-goals for the first review:

- NetVM/ProxyVM/firewall ownership.
- A prebuilt opaque image submission.
- Promotion directly to stable `templates-community`.

## External Review Expectations Checked

This is a targeted review of the Qubes sources most relevant to a new
community template.  It is not an exhaustive review of every Qubes pull request
or issue.

- Qubes package contribution rules: open-source license, clear Qubes use case,
  signed code, tests, low review burden, static hashes for downloads, and
  careful review of build scripts, Makefiles, RPM scripts, and dependencies.
- Qubes Builder v2 template flow: templates go through prep, build, sign,
  publish, and upload stages, and the generic template plugin currently needs
  an accepted distribution path for new template distributions.  Current
  Builder v2 calls its own template Makefile and distribution content scripts;
  it will not automatically call this repository's `Makefile.builder`.
- Qubes R4.3 community template release config: community templates are wired
  through release config entries and publish to `templates-community-testing`
  before stable community promotion.
- Current Qubes Forum build guidance for an R4.3 Fedora 42 template still
  centers Builder v2, release-config YAML, `template fetch prep build`, a
  Qubes-sized root image, and TemplateVM import/testing before treating a
  template as usable.
- Builder v2 forum guidance reinforces that contributors should make the
  component/distribution/template inputs explicit and inspect the generated
  template RPM metadata and payload before install.
- Current forum guidance for "how to make a template" says the right path
  depends on the target OS and the services the template must provide.  It also
  warns that older BuilderPlugins-era guidance may be stale under Builder v2.
  The first Guix review scope therefore stays explicit about TemplateVM/AppVM
  services and uses the current Builder v2/release-config path rather than
  treating an older plugin API as precedent.
- Qubes Forum guidance for a new OS TemplateVM: start from Qubes builder
  scripts for the OS, using Fedora, Debian, and Arch as models.
- Gentoo community-template precedent: source-oriented community templates need
  maintainer ownership, long build timeouts, and automated validation beyond
  normal CI capacity.
- Community template trust and availability: users trust the template
  maintainer, and unmaintained community templates may disappear from Template
  Manager rather than remain a normal supported download.
- NixOS template issue and follow-up PRs: maintainers expect complete Qubes
  package coverage, real Builder support, update mechanism integration,
  qrexec/GUI/appmenu continuity across rebuilds, and signed/rebased PRs rather
  than ad hoc local workarounds.
- Qubes' contribution guidance explicitly covers generative-AI-assisted work.
  Any submission derived from this repository should disclose AI assistance and
  be reviewed, simplified, and tested by the human maintainer before it asks
  Qubes reviewers to spend time on it.

## Review Matrix

| Review expectation | Artifact in this repository | Current status |
| --- | --- | --- |
| Open-source licensing | `COPYING`, SPDX markers in code files, Qubes-template-style RPM `License: GPLv3+` metadata, upstream component license fields in Guix package definitions | Present |
| Static hashes for downloaded source | `native/modules/qubes/packages/qubes-vm.scm`, `scripts/check-qubes-pins.sh` | Present, freshness check is networked |
| Reproducible release inputs | `config/channels.scm`, installed `/etc/guix/channels.scm`, `VALIDATION.md` | Pinned and resolved with `guix time-machine -- describe` on GCP |
| Builder-shaped build pipeline | `Makefile`, `builder-v2-template/`, `config/qubes-builderv2-guix.example.patch` | Reviewable sketch, not accepted upstream |
| Template builder precedent | `TEMPLATE_PRECEDENTS.md`, `builder-v2-template/` | Hook mapping documented against Qubes template-builder model |
| Qubes release-config wiring | `config/qubes-os-r4.3-templates-community-guix.example.yml`, `config/qubes-release-configs-guix.example.patch` | Reviewable sketch with placeholder maintainer identity |
| Template Manager RPM format | `scripts/package-native-template-rpm.sh`, `tests/rpm-layout-check.sh` | Locally tested |
| Runtime Qubes integration | `native/modules/qubes/services/qubes-vm.scm`, `native/modules/qubes/systems/guix-template.scm`, `scripts/test-native-rootfs-activation.sh`, `scripts/test-template-rpm-lifecycle-dom0.sh`, `scripts/test-update-proxy-default-target-dom0.sh`, `scripts/test-guix-update-proxy-config-dom0.sh`, `scripts/test-guix-update-proxy-download-dom0.sh`, `scripts/test-guix-update-proxy-stub-download-dom0.sh`, `scripts/test-memory-balloon-dom0.sh`, `VALIDATION.md` | Partially tested; nested-dom0 `qvm-template` install/reinstall/remove/upgrade/downgrade plus TemplateVM/AppVM smoke passed, including `/dev/xvdc1` swap, `meminfo-writer` startup, dynamic memory growth under pressure, controlled update-proxy qrexec forwarding, default update-target HTTP forwarding through stock Qubes policy, RPM-mode openQA jobs 8/9, rebuilt minimal openQA job 27 with generated Guix daemon/client proxy verification, and job 31 with a controlled `guix download` through a temporary `sys-net` stub target.  OpenQA job 29 reached the opt-in real-network download verifier but failed on dom0 `qubes.UpdatesProxy` refusal, so real Internet update-target downloads and final signed-branch reruns remain unpassed gates. |
| Maintainer/update story | `MAINTENANCE.md` | Policy documented; actual maintainer identity and signed release process still missing |
| Security-review framing | `SECURITY.md`, `ADAPTATION_INVENTORY.md` | Trust boundaries and sensitive adaptations documented; nested-dom0 smoke, dynamic memory pressure, default update-target HTTP forwarding, RPM-mode openQA jobs 8/9, rebuilt minimal openQA job 27 with generated Guix proxy configuration verification, and job 31 controlled Guix proxy download are green; job 29 shows the real-network download verifier is wired but currently blocked by dom0 updates-proxy refusal in the nested openQA environment; real Internet update-target Guix proxy use and final signed-branch reruns remain |
| Human review burden | `REVIEW_NOTES.md`, `UPSTREAMING.md`, `VALIDATION.md` | Explained, but maintainer identity/signatures are still missing |

## Comparable Upstream Discussions

- Qubes issue `QubesOS/qubes-issues#7992` is the closest comparable
  community-template tracker for an unusual declarative OS.  Maintainer
  guidance there starts with packaging all relevant Qubes packages and adding
  Qubes Builder support for producing a template from those packages.
- Qubes PR `QubesOS/qubes-core-admin-linux#168` shows that update integration
  for non-FHS declarative systems is expected to fit the existing Qubes update
  machinery, with distro-specific wrappers where needed, signed commits, and
  rebases when common code changes land.
- Qubes PR `QubesOS/qubes-core-agent-linux#481` is relevant because dom0 can
  use guest-reported distribution metadata to select distro-specific behavior.
  A Guix template should report useful metadata rather than relying on dom0 to
  infer Guix from paths.

Live metadata/comments checked for those sources showed the following concrete
review expectations:

- `QubesOS/qubes-issues#7992` remains open as a NixOS template contribution
  tracker.  Maintainer guidance there starts with packaging all relevant Qubes
  packages and making Qubes Builder able to build a template from them.
- Update integration for declarative/non-FHS templates is not just a local
  updater script issue.  The NixOS discussion records why dom0 injects update
  code into templates: Qubes has used that path to deliver fixes to the update
  mechanism itself.  Guix update handling should therefore fit the Qubes update
  path or explicitly remain an unclaimed gate.
- The same discussion treats PATH-based execution and distro-specific wrappers
  as acceptable when a declarative system does not have a stable
  `/usr/bin/python3`.  That supports keeping Guix wrappers profile-visible
  instead of hard-coding store paths that change after reconfiguration.
- `QubesOS/qubes-core-admin-linux#168` is still open, which means comparable
  declarative update integration has not been a trivial one-shot merge.
- `QubesOS/qubes-core-agent-linux#481` was merged and added distribution
  metadata reporting to dom0.  The Guix package build passes `DIST=guix` and
  `release=Guix` so this template can participate in that model.
- The same merged distribution-metadata PR records the Qubes testing norm for
  dom0-dependent guest behavior: reviewers asked for coverage, and the
  maintainer pointed that path at integration testing through openQA because
  ordinary unit tests do not have a running dom0 to communicate with.  That
  supports keeping Guix system-record checks, artifact checks, and RPM-mode
  openQA as separate evidence layers rather than pretending one unit test can
  cover the whole TemplateVM contract.
- The community template trust model makes `MAINTENANCE.md` part of the review
  surface: the repo needs a named maintainer, signing key, update cadence, and a
  removal/handoff plan before publication.
- Later comments on the NixOS tracker call out app menu launching, GUI session
  environment, keymap sync, audio, time sync, and DispVM startup as practical
  usability gates.  For Guix, the current nested-dom0 smoke covers the basic
  appmenu/GUI and TemplateVM/AppVM path; update proxy, time-like Qubes
  services, dynamic memory-pressure behavior, and broader usability checks
  should remain release gates until proven.

## Patch Set Shape

The changes should be reviewed in this order:

1. Packaging and source pins:
   `native/modules/qubes/packages/qubes-vm.scm`,
   `scripts/check-qubes-pins.sh`, and `make check-qubes-pins`.
2. Runtime service mapping:
   `native/modules/qubes/services/qubes-vm.scm` and
   `native/modules/qubes/systems/guix-template.scm`.
3. Image and template packaging:
   `scripts/build-native-rootfs.sh`, `scripts/package-native-template-rpm.sh`,
   `tests/builder-rpm-contract-check.sh`, `tests/rpm-layout-check.sh`, and
   `scripts/builder-v2-template-adapter.sh`.
4. Test and release harness:
   openQA files, nested-dom0 scripts, and
   `tests/build-native-rootfs-policy-check.sh`,
   `tests/builder-hook-contract-check.sh`, `tests/builder-rpm-contract-check.sh`,
   `tests/rpm-layout-check.sh`,
   `scripts/test-update-proxy-default-target-dom0.sh`,
   `scripts/test-guix-update-proxy-config-dom0.sh`,
   `scripts/test-guix-update-proxy-download-dom0.sh`, and
   `scripts/test-memory-balloon-dom0.sh`.
5. Pin freshness check:
   `scripts/check-qubes-pins.sh` compares pinned Qubes component versions
   against upstream tags before submission.  It is provenance hygiene, not test
   evidence for template behavior.
6. Upstream process documents:
   `UPSTREAMING.md`, `Makefile.builder`,
   `config/qubes-os-r4.3-templates-community-guix.example.yml`, and `COPYING`.

Auxiliary local helpers are intentionally outside the release artifact:

| Helper | Review purpose |
| --- | --- |
| `openqa/qubesos/main.pm`, `openqa/qubesos/lib/guixdom0distribution.pm` | openQA loader and dom0 serial-console glue for the local Guix template test module. |
| `scripts/diagnose-guix-postinstall-dom0.sh` | dom0-side diagnostic collector for failed `qvm-template` post-install or qrexec startup investigations. |
| `scripts/install-guix-foreign.sh` | Foreign-distribution Guix installer used by the fallback "Guix inside Debian/Fedora/Arch template" path, not by the native Guix System TemplateVM release path. |

## Non-Obvious Guix-Specific Decisions

- Qubes package sources use immutable upstream commits with Guix recursive
  hashes.  The build no longer depends on local Qubes source checkouts.
- The default root image size is 20G to match the Qubes builder template root
  size used by current Fedora-style templates.
- `/etc/config.scm` is installed inside the template and contains the local
  Qubes package, service, and system modules so `guix system reconfigure
  /etc/config.scm` does not depend on a custom site module.
- `/etc/guix/channels.scm` is installed from the selected pinned channel file.
  This gives all users a declarative default channel without baking an
  imperative per-user `guix pull` profile into the template image.
- `scripts/build-native-rootfs.sh` writes a generated `/sbin/init` wrapper
  because Qubes dom0 supplies the VM kernel and enters the guest root at
  `/sbin/init`, while Guix's `--no-bootloader` image build leaves the boot
  program under `/var/guix/profiles/system`.  The wrapper prepares early
  runtime mounts and Qubes runtime directories, exports `GUIX_NEW_SYSTEM`, and
  then executes the Guix boot program.
- Several stock Guix base services are deliberately omitted so the TemplateVM
  does not start independent console, login, networking, log-rotation, or
  sysctl policy that Qubes normally owns.  The exact omitted service list is in
  `ADAPTATION_INVENTORY.md`.
- The template RPM is intentionally a Qubes Template Manager payload, not a
  normal installable RPM: it contains split root image parts, template metadata,
  appmenu allowlists, ghost private/volatile images, and a `%pre` guard that
  rejects direct package-manager installation.
- `scripts/import-native-rootfs-dom0.sh` is test infrastructure for disposable
  nested dom0/root-image smoke runs.  Its direct file-pool `truncate` fallback
  is limited to a freshly created TemplateVM that the script has not started or
  imported into yet; the release path remains the `qvm-template` RPM package.
- `scripts/setup-openqa-guix-template-test.sh` is written for a dedicated
  review host.  It updates the local openQA test tree, worker configuration,
  API credentials, and HDD assets before scheduling the Guix job.
- Compatibility links under `/usr`, `/etc/qubes-rpc`, `/usr/lib/qubes`,
  `/run/qubes-service`, and `/var/run/qubes-service-environment` are deliberate.
  Upstream Qubes VM tools use fixed FHS-style paths, while Guix installs into
  immutable store paths.
- Some qrexec and GUI wrappers intentionally use
  `/run/current-system/profile/...` paths instead of direct store references.
  Direct store references made qrexec fragile across reconfiguration and reboot.
- QubesDB is patched to stay in the foreground because Shepherd supervises the
  process it starts; the upstream daemon mode would otherwise hide the real
  process from service supervision.
- The smaller VM-side packages build explicit upstream subdirectories instead
  of importing RPM/Deb packaging fragments: vchan, `linux-utils/qrexec-lib`,
  `linux-utils/qmemman`, and QubesDB daemon/client/bindings.  This keeps the
  Guix package outputs limited to guest runtime pieces and leaves service
  policy in the Guix system definition.
- qrexec PAM support is enabled with the upstream make variable instead of
  patching upstream PAM detection.
- PAM service files are provided through Guix `pam-root-service-type`, not by
  mutating `/etc/pam.d` at package build time.
- `/etc/fstab` is materialized at activation because Guix exposes it as an
  immutable store symlink, while Qubes `mount-dirs.sh` appends the private
  volume entry when needed.
- Qubes private storage follows the standard `/dev/xvdb -> /rw`,
  `/rw/home -> /home`, and `/rw/usrlocal -> /usr/local` model through upstream
  Qubes `mount-dirs.sh` and `bind-dirs.sh`.
- Swap is declared as `/dev/xvdc1` in the Guix operating-system record to match
  standard Qubes template behavior.
- `meminfo-writer` is packaged from Qubes `linux-utils/qmemman` and supervised
  by a Guix service with Qubes' usual threshold/delay defaults.  The service
  honors the `/run/qubes-service/meminfo-writer` flag.
- `qrexec-fork-server` is kept on the Qubes GUI/XDG autostart path because it
  daemonizes itself and is part of GUI session readiness, not a simple
  long-running Shepherd child.
- `qubes.PostInstall` feature reporting is adjusted for Shepherd: successful
  execution through qrexec is treated as the qrexec-active signal when systemd
  is absent.
- The updates proxy is a Qubes RPC forwarder to `qubes.UpdatesProxy`; it does
  not implement a new Guix updater policy.  The local listener is a
  Shepherd-managed `socat` process.  `socat EXEC:` gives each connection handler
  a stream socket on standard input/output, so the wrapper uses Qubes' current
  `qrexec-client-vm --use-stdin-socket '' qubes.UpdatesProxy` command and keeps
  the same bidirectional EOF behavior as the systemd socket unit.  The
  Shepherd service starts after `qubes-sysinit`, not after qrexec/network
  services, because Qubes enables the equivalent forwarder from service flags
  and a local socket even in interface-less TemplateVMs.  Guix-specific proxy
  setup is deliberately separate: it uses `guix-configuration` for daemon-side
  downloads and a generated `/run/qubes/bin/guix` wrapper for client-side Guix
  commands.
- The Builder-v2 adapter exposes `make prepare build-rootimg` and
  `make prepare build-rpm`, but it does not claim Builder v2 already supports
  `dist: guix` or automatically discovers the adapter.
- `builder-v2-template/` exposes the standard Builder v2 content-script shape
  for reviewers who prefer a `builder-guix` component over a template-plugin
  special case.  Its `01_install_core.sh` hook delegates to the same native
  Guix system build logic through `scripts/build-native-rootfs.sh
  --install-dir`.
- `config/qubes-builderv2-guix.example.patch` is a review artifact for the
  matching Builder v2 side: it adds `vm-guix` distribution support and points
  the template plugin at `builder-guix/builder-v2-template`.
- `config/qubes-release-configs-guix.example.patch` is the corresponding
  release-config sketch for `templates-community-testing`.

## Required Evidence Before Submission

- Clean public repository with signed commits or signed release tags.
- Maintainer name and GPG fingerprint.
- `make check`.
- `make check-qubes-pins`.
- `guix time-machine -C config/channels.scm -- describe`.
- Normal and minimal rootfs builds from a clean tree.
- Normal and minimal image inspection.
- Normal and minimal writable-root activation tests.
- Normal and minimal qvm-template-compatible RPMs with split
  `root.img.part.NN` payloads.
- Final signed-branch RPM-mode openQA reruns for both variants.
- `qvm-template --yes install --nogpgcheck` install, reinstall, remove,
  upgrade, and downgrade checks for both variants.  Recorded nested-dom0
  evidence covers install, reinstall, metadata checks, smoke, distinct-EVR
  upgrade, downgrade, and remove.
- TemplateVM and AppVM smoke results for QubesDB, qrexec, GUI/appmenus,
  shutdown, `/rw`, `/home`, `/usr/local`, `/dev/xvdc1` swap activation, and
  guest-side `meminfo-writer` startup.
- Default update-target proxying.
- A passing real Guix update-tooling proxy run through an Internet update
  target.  OpenQA job 31 verifies a controlled `guix download` through the
  generated wrapper and stock default-target policy using a temporary `sys-net`
  stub, but job 29 failed the real-network download gate with dom0 refusing
  `qubes.UpdatesProxy`.

## Still Not Upstream-Complete

The local repository can be reviewable without pretending the upstream process
is finished.  The unresolved external items are:

- A real public repository URL.
- A named maintainer and maintainer GPG fingerprint.
- Signed commits or tags.
- Accepted Builder v2 `dist: guix` support, or an accepted release-config
  component wiring that calls this repository's Builder-shaped targets.
- Fresh normal and minimal release evidence from a clean tree.
- Qubes maintainer review across the Builder, release-config, and template
  repository changes.
