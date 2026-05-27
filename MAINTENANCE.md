# Maintainer and Update Story

This file documents the intended maintenance model for a native GNU Guix System
Qubes TemplateVM.  It is part of the review surface for Qubes maintainers; it
does not make the current RFC branches a publishable release.

Community template maintenance is part of the user trust path.  Qubes
documentation says community templates are not updated by the Qubes Project in
the same way official templates are; users also trust the community template
maintainer.  Recent Gentoo template availability discussion shows the practical
failure mode: if the template is no longer maintained, users may need to build it
themselves or use an unofficial source instead of finding it in Template Manager.

## Release Ownership

The template should be proposed as a community-maintained template first, not as
an official Qubes template.  Before stable publication, a release owner should
supply:

- a public repository URL;
- whatever signing metadata Qubes accepts for that release request;
- fresh build and runtime evidence for both `guix` and `guix-minimal`;
- a clear handoff plan if the maintainer stops publishing updates.

The current RFC/review PRs intentionally skip release-owner identity and
fingerprint metadata.

## Maintainer Handoff

If the maintainer can no longer publish timely updates, the expected handoff is:

1. announce the maintenance gap on the original `qubes-devel` or contribution
   issue thread;
2. stop requesting promotion or stable publication until a replacement
   maintainer is identified;
3. transfer the public repository or publish a final signed tag that documents
   the last known-good release evidence;
4. submit a release-config update with the replacement release-owner metadata,
   or ask Qubes maintainers to remove or hide the template if no replacement is
   available;
5. keep the previous signing key documented so users can distinguish an
   intentional maintainer change from an unexpected release source change.

The release-config release-owner metadata is part of the trust path.  It should
not be changed silently.

This handoff policy is a publication gate.  If no replacement maintainer exists,
the responsible action is to keep the template out of stable community
publication or ask Qubes maintainers to hide/remove it until maintenance resumes.

## Release Inputs

Template releases are built from pinned inputs:

- Qubes VM components are pinned in `config.scm` by upstream tag, commit, and
  recursive Guix hash.
- The Guix channel used by release builds is pinned in `config/channels.scm`.
- The release-config and Builder v2 integration sketches are in `config/`.

Release builds must not default to an unpinned Guix branch.
`scripts/build-native-rootfs.sh` uses `config/channels.scm` by default and
fails if no pinned channel file is available.  `GUIX_BRANCH` is an explicit
developer-only override, not a release-build default.  Builders may override
channels deliberately, but the published template release should record the
channel commit used to build it.

## Updating Qubes Components

For each Qubes R4.3 component bump:

1. Run `./scripts/check-qubes-pins.sh` to compare the pinned commit against
   the currently tagged upstream release.
2. Update the component tag and commit in `%qubes-source-components`.
3. Recompute the Guix recursive hash for that source.
4. Load the Guix modules on a system with Guix installed so package versions
   are checked against the pinned table rather than duplicated manually.
5. Run the local executable checks with `make check`, then rebuild and test both
   variants before publishing.

Version strings passed to Qubes component builds are derived from the pinned
source table.  Maintainers should not hand-edit duplicate package versions.

## Updating Guix

`config/channels.scm` pins the Guix checkout used to generate template root
images.  The installed TemplateVM keeps normal user/root `guix pull` state
unpinned.  The release process for a new Guix base should be:

1. update `config/channels.scm` to the desired Guix commit;
2. build with the default `GUIX_PULL_BEFORE_BUILD=1` path so
   `scripts/build-native-rootfs.sh` refreshes a cached Guix Git checkout with
   command-line `git`, then runs authenticated `guix pull` into a temporary
   build profile from that local checkout;
3. rebuild `guix` and `guix-minimal` root images;
4. inspect and activate both images;
5. package both RPMs;
6. run RPM-mode openQA and `qvm-template` lifecycle tests.

The template should not run `guix pull` automatically during boot or image
activation.  Users may run Guix commands inside a TemplateVM deliberately, but
published template updates should remain reproducible from the pinned channel
file and source table.

## Qubes Updates Proxy

Guix network traffic should use the Qubes updates proxy path, not a separate
network policy.  The implementation provides a Guix-facing forwarder to
`qubes.UpdatesProxy` and keeps `guix-daemon` unproxied for ordinary AppVM use.
Guix update operations that must use the Qubes proxy should run with an
explicit `http_proxy`/`https_proxy` environment when `updates-proxy-setup` is
enabled.  The `qubes-core-admin-linux` RFC backend keeps central updates
system-only:
refresh is intentionally a no-op, and upgrade uses the installed system Guix
for `guix system reconfigure /etc/config.scm`
instead of updating root or user Guix profiles as package-manager state.  The
backend reports the current Guix System generation and per-output
`/run/current-system/profile` manifest entries to the normal Qubes updater
package summary, preserving Guix manifest columns before Qubes output
sanitization, using vmupdate-scoped temporary time-machine state, and streaming
Guix refresh/reconfigure output through the normal vmupdate log path.
RPM-mode openQA job 27 validated the then-current generated Guix proxy wrapper,
updates-proxy forwarder, and `guix-daemon` service state in a rebuilt `guix-minimal`
TemplateVM.  OpenQA jobs 38, 41, and 44 repeated that path on rebuilt minimal
RPMs and passed a controlled `guix download` through stock Qubes default-target
policy with a temporary update-target stub; jobs 41 and 44 also verified that
the source TemplateVM had no direct default route before counting the run as
proxy evidence.  OpenQA jobs 29 and 40 reached the real-download verifier, but
dom0 refused `qubes.UpdatesProxy` in the nested test environment.  A passing
real Guix update/download command through an Internet-capable update-proxy
target remains a release gate before submission.

## Rollback

Rollback has two layers:

- Qubes template package rollback: reinstall or downgrade the
  `qubes-template-guix*` RPM through `qvm-template` once published through Qubes
  repositories.
- Guix system rollback inside a TemplateVM: Guix system generations can be
  rolled back from the TemplateVM when the user deliberately reconfigures the
  system.

Both layers need runtime tests before publication.  The current local checks do
not prove rollback behavior in dom0.

## Security Cadence

The maintainer should publish a rebuilt template when either of these changes:

- a pinned Qubes VM component receives a relevant R4.3 update;
- the pinned Guix channel needs security or compatibility updates.

Each security rebuild should record:

- source commit and signed tag;
- Guix channel commit;
- Qubes component pins and hashes;
- normal and minimal RPM hashes;
- openQA and `qvm-template` lifecycle results.

## Release Evidence Required

Before asking Qubes to merge release-config entries, collect fresh evidence from
a clean tree:

- `make check` as local executable build/package evidence;
- Guix module load with Guix available;
- `./scripts/check-qubes-pins.sh`;
- normal and minimal rootfs builds;
- image inspection and activation tests for both variants;
- normal and minimal template RPM builds;
- `qvm-template` install, reinstall, remove, upgrade, and downgrade with
  `scripts/test-template-rpm-lifecycle-dom0.sh`;
- TemplateVM and AppVM qrexec, QubesDB, GUI, appmenu, shutdown, and private
  volume persistence smoke tests;
- standard Qubes `/dev/xvdc1` swap activation and guest-side
  `meminfo-writer` startup;
- update proxy forwarding and generated Guix daemon/client proxy
  configuration;
- controlled Guix client download through the Qubes updates proxy in
  disposable/nested review environments;
- real Guix update/download behavior through an Internet-capable Qubes
  update-proxy target;
- dynamic memory-balloon resize behavior under dom0 pressure;
- RPM-mode openQA for both variants.
