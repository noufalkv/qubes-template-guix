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
- whatever release-owner metadata Qubes accepts for that release request;
- fresh build and runtime evidence for both `guix` and `guix-minimal`;
- a clear handoff plan if the maintainer stops publishing updates.

The current RFC/review PRs intentionally skip release-owner identity metadata.

## Maintainer Handoff

If the maintainer can no longer publish timely updates, the expected handoff is:

1. announce the maintenance gap on the original `qubes-devel` or contribution
   issue thread;
2. stop requesting promotion or stable publication until a replacement
   maintainer is identified;
3. transfer the public repository or publish a final tag that documents the
   last known-good release evidence;
4. submit a release-config update with the replacement release-owner metadata,
   or ask Qubes maintainers to remove or hide the template if no replacement is
   available;
5. keep the previous release source documented so users can distinguish an
   intentional maintainer change from an unexpected source change.

The release-config release-owner metadata is part of the trust path.  It should
not be changed silently.

This handoff policy is a publication gate.  If no replacement maintainer exists,
the responsible action is to keep the template out of stable community
publication or ask Qubes maintainers to hide/remove it until maintenance resumes.

## Release Inputs

Template releases are built from pinned inputs:

- Qubes VM components are pinned in `modules/qubes/packages.scm` by upstream tag, commit,
  and recursive Guix hash.
- The Guix channel used by release builds is pinned in `config/channels.scm`.
- The release-config and Builder v2 integration sketches are in `config/`.

Release builds must not default to an unpinned Guix branch.
`scripts/build-native-rootfs.sh` uses `config/channels.scm` directly and fails
if that pinned channel file is missing.  To change the Guix input for a release,
update `config/channels.scm` in the source tree so the channel commit is part of
the reviewed build input.

## Updating Qubes Components

For each Qubes R4.3 component bump:

1. Run `./scripts/check-qubes-pins.sh` to compare the pinned commit against
   the currently tagged upstream release.
2. Update the component tag and commit in `%qubes-source-components` in
   `modules/qubes/packages.scm`.
3. Recompute the Guix recursive hash for that source.
4. Run the local artifact contract with `make check`, then rebuild and test
   both variants before publishing.

Version strings passed to Qubes component builds are derived from the pinned
source table.  Maintainers should not hand-edit duplicate package versions.

## Updating Guix

`config/channels.scm` pins the Guix commit used to generate template root
images.  The installed TemplateVM keeps normal user/root `guix pull` state
unpinned.  The release process for a new Guix base should be:

1. update `config/channels.scm` to the desired Guix commit;
2. build normally so `scripts/build-native-rootfs.sh` runs authenticated
   `guix pull -p <temporary-profile> --allow-downgrades -C
   config/channels.scm` against Guix's official Codeberg channel URL and builds
   with the freshly pulled Guix command;
3. rebuild `guix` and `guix-minimal` root images;
4. inspect and activate both images;
5. package both RPMs;
6. run RPM-mode openQA and `qvm-template` lifecycle tests.

The template should not run `guix pull` automatically during boot or image
activation.  Users may run Guix commands inside a TemplateVM deliberately, but
published template updates should remain reproducible from the pinned channel
file and source table.  The installed `/etc/qubes-guix-channel` copy is this
repository's Qubes VM channel module, not root or user `guix pull` state.

## Channel Authentication and User Updates

The repository is an authenticated Guix channel.  `.guix-authorizations` lists
the OpenPGP fingerprints allowed to sign channel commits, and the signer's
public key lives on the `keyring` branch as `<FINGERPRINT>.key`.  Every commit
from the channel introduction onward must be signed by an authorized key, or
`guix pull` rejects it.  The channel introduction (the first commit carrying
`.guix-authorizations`) and the signer fingerprint are recorded in both
`config/guix-channels.scm` and `config/qubes-system.tmpl`.

The installed image carries `/etc/guix/channels.scm` (from
`config/guix-channels.scm`) so a user can `guix pull` the Qubes channel and
update the modules the idiomatic way; it pins no commit so pulls track the
branch.  When adding a new signer or rotating the key, update
`.guix-authorizations`, add the key to the `keyring` branch, and refresh the
introduction in `config/guix-channels.scm` and `config/qubes-system.tmpl` if the
introduction commit changes.  For publication, change the channel `url` in those
two files from the development GitHub mirror to the Qubes-hosted URL.

## Qubes Updates Proxy

Guix network traffic should use the Qubes updates proxy path, not a separate
network policy.  The implementation provides a Guix-facing forwarder to
`qubes.UpdatesProxy` and keeps `guix-daemon` unproxied for ordinary AppVM use.
Guix update operations that must use the Qubes proxy should run with an
explicit `http_proxy`/`https_proxy` environment when `updates-proxy-setup` is
enabled.  `scripts/test-guix-update-proxy-dom0.sh --pull` exercises that path
with a temporary profile and the official Guix channel, without writing root or
user Guix pull state.  The `qubes-core-admin-linux` RFC backend keeps central
updates system-only: refresh is intentionally a no-op, and upgrade uses the
installed system Guix for
`guix system -L /etc/qubes-guix-channel/modules reconfigure --no-bootloader --allow-downgrades /etc/config.scm`
instead of updating root or user Guix profiles as package-manager state.  The
backend reports the current Guix System generation and per-output
`/run/current-system/profile` manifest entries to the normal Qubes updater
package summary, preserving Guix manifest columns before Qubes output
sanitization, and streaming Guix reconfigure output through the normal vmupdate
log path without a separate `guix time-machine` refresh step.
The release gate is a real Guix update/download command through an
Internet-capable Qubes update-proxy target.  Generated proxy configuration by
itself is not enough.

## Rollback

Rollback has two layers:

- Qubes template package rollback: reinstall or downgrade the
  `qubes-template-guix*` RPM through `qvm-template` once published through Qubes
  repositories.
- Guix system rollback inside a TemplateVM: Guix system generations can be
  rolled back from the TemplateVM when the user deliberately reconfigures the
  system.

Both layers need runtime tests before publication.  The current local checks do
not cover rollback behavior in dom0.

## Security Cadence

The maintainer should publish a rebuilt template when either of these changes:

- a pinned Qubes VM component receives a relevant R4.3 update;
- the pinned Guix channel needs security or compatibility updates.

Each security rebuild should record:

- source commit or tag;
- Guix channel commit;
- Qubes component pins and hashes;
- normal and minimal RPM hashes;
- openQA and `qvm-template` lifecycle results.

## Release Evidence Required

Before asking Qubes to merge release-config entries, refresh the evidence in
`VALIDATION.md` from a clean public tree.  Maintenance docs should record who is
responsible for updates and rollback, not duplicate the release checklist.
