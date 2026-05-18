# Upstreaming Status

This repository is a native GNU Guix System TemplateVM prototype for Qubes OS.
The current goal is to make it reviewable as a Qubes community template, not
just locally installable.
`REVIEW_NOTES.md` explains the non-obvious Qubes/Guix compatibility decisions
and the intended review order for the patch set.
`VALIDATION.md` records the latest local and remote Guix builder evidence without
treating current nested-dom0/openQA results as Qubes acceptance or final
publication release proof.
`SUBMISSION_AUDIT.md` maps the upstreamability objective to concrete artifacts
and explicitly lists what still cannot be claimed.
`ADAPTATION_INVENTORY.md` maps Guix-specific source, packaging, activation, and
service adaptations to their rationale and validation status.
`SECURITY.md` summarizes trust boundaries, source integrity controls,
privileged guest behavior, and unproven runtime security gates.
`TEMPLATE_PRECEDENTS.md` maps the Guix Builder hooks and release-config sketch
to existing Qubes template-builder precedent.
`CONTRIBUTING.md` captures the expected publication signing, testing, release
evidence, and multi-repo contribution workflow for future changes.
`SUBMISSION_DRAFTS.md` contains editable drafts for the `qubes-devel` RFC,
`[Contribution]` issue, Builder v2 PR, and release-config PR, with placeholders
and validation gaps left explicit.

RFC PRs are open for the separated upstream components:
QubesOS/qubes-builderv2#245, QubesOS/qubes-core-admin-linux#211, and
QubesOS/qubes-release-configs#19.  These are draft review surfaces only; they
do not mean Qubes has accepted the template or agreed to publish it.  Live PR
checks on May 19, 2026 found no submitted reviews and no maintainer requests
newer than the Builder v2 request for a template build log; a fresh
`guix-minimal` build log from template source head
`2f209a4403652937678c1fd76bc9b71919e05236` was posted in response.  Later
template-branch amendments refreshed Qubes pins, no-shrink RPM packaging, and
central-update openQA harness behavior, so that build log is retained as prior
evidence rather than current-head release evidence.  Builder v2 head `f9ec921` has
Qubes code-signing and GitLab CI success, release-config head `fb356bd` has
Qubes code-signing success, and the public core-admin Linux PR head `182199c`
has Qubes code-signing and GitLab CI success with `maintainer-tag` still
pending.  The release-config PR branch was simplified to remove
maintainer fingerprint metadata from the RFC sketch, and its current head now
matches the checked-in review artifact.

## Current Local State

The repository license is GPLv3-or-later, matching the current template RPM
metadata and Qubes Builder v2's template RPM spec convention.  The license text
is in `COPYING`, and code/config entry points carry SPDX license identifiers.
Guix package definitions still record the upstream Qubes component licenses
individually.

The local artifact contract check for this clean review branch is:

```sh
make check
```

The Guix system contract check runs on a Guix-capable builder; final
publication reruns are still required:

```sh
make guix-system-contract-check
```

The default check suite executes the Builder hooks against a temporary
install tree and builds/extracts real template RPM layout tests for both `guix`
and `guix-minimal`.  It fails when required RPM/image tooling is missing; the
upstream-facing test story is based on generated artifacts and Qubes-visible
contracts, not text-only source inspection.  Do not carry source-only or
patch-shape tests in the upstream patch series.
The Guix system contract check is separate because it requires Guix in `PATH`.
It instantiates both operating-system variants and verifies Qubes-visible
defaults that reviewers asked to preserve: `/dev/xvdc1` swap, the standard
`user` account and Qubes group membership, default privileged programs,
passwordless sudo, required Qubes services, and `meminfo-writer` defaults.

Qubes VM component sources are pinned to immutable upstream commits and Guix
recursive content hashes.  The pinned R4.3 components are:

- `qubes-core-vchan-xen` `v4.2.8`
- `qubes-linux-utils` `v4.3.17`
- `qubes-core-qubesdb` `v4.3.2`
- `qubes-core-qrexec` `v4.3.12`
- `qubes-core-agent-linux` `v4.3.43`
- `qubes-gui-common` `v4.3.1`
- `qubes-gui-agent-linux` `v4.3.16`

The root image build defaults to `config/channels.scm`, which pins the Guix
channel commit used for release-quality builds.  Builders can still override
the channel with `GUIX_CHANNELS_FILE`, or bypass time-machine with
`GUIX_TIME_MACHINE=0` for local development.
The selected channel file is also installed as `/etc/guix/channels.scm` inside
the template, giving users a visible release-build channel reference without
baking an imperative per-user `guix pull` profile into the image.
The pinned channel currently resolves on the remote Guix builder with
`guix time-machine -C config/channels.scm -- describe`; see `VALIDATION.md` for
the exact commit output.

Maintainers can check whether the Qubes VM component pins are still current for
their pinned release series with:

```sh
make check-qubes-pins
```

This check is intentionally networked and is not part of the default offline
`make check` contract tests.

The repository also exposes a Guix-specific build contract that a Builder v2
integration can call:

```sh
make prepare build-rootimg
make prepare build-rpm
```

Those targets are a local adapter around the current Guix root image and RPM
packaging scripts.  They do not by themselves make Builder v2 understand
`dist: guix`; the upstream builder still needs a Guix distribution/template
plugin path or an accepted component wiring that calls these targets.  Current
Builder v2 template code calls its own template `Makefile` and distribution
content scripts such as `00_prepare.sh`, `01_install_core.sh`,
`04_install_qubes.sh`, and `09_cleanup.sh`; it does not discover this
repository's `Makefile.builder` by itself.
This repository now includes `builder-v2-template/` with that standard content
script contract, backed by `scripts/build-native-rootfs.sh --install-dir`.
That gives reviewers a concrete `builder-guix` component shape to evaluate,
even though Qubes Builder v2 still needs a Guix distribution entry that points
`TEMPLATE_CONTENT_DIR` at those scripts.
`config/qubes-builderv2-guix.example.patch` sketches the corresponding
Builder v2 change against the current upstream code shape.
The repository also includes a small `Makefile.builder` shim for the legacy
Builder-style review surface and an example R4.3 release-config fragment in
`config/qubes-os-r4.3-templates-community-guix.example.yml` so the remaining
Builder and release-config work has an explicit review target.
`config/qubes-release-configs-guix.example.patch` shows the same entries as a
patch against the current R4.3 community template config.
`config/README.md` maps each multi-repo review artifact to its target upstream
repository and current sanity checks.

## GNU Guix System Alignment

The native template is intentionally expressed as Guix package definitions,
Guix operating-system records, and Shepherd service types rather than as an
imperative image customization script.  Qubes runtime behavior that is normally
provided by distribution packages and systemd units is mapped to named Guix
package phases and Shepherd services, with the non-obvious adaptations listed
in `ADAPTATION_INVENTORY.md`.

Release-quality builds use immutable Qubes source commits and recursive Guix
hashes, plus `config/channels.scm` for the Guix channel.  The installed
`/etc/config.scm` keeps later `guix system reconfigure /etc/config.scm` work
self-contained instead of relying on a builder checkout.  The Qubes
central-updater RFC path uses `guix time-machine --branch=master -- system
reconfigure /etc/config.scm`, so vmupdate changes the Guix System generation
rather than root's Guix checkout/profile.

Mutable runtime state is limited to Qubes integration points that must be
mutable in a TemplateVM/AppVM, such as `/rw`, `/home`, `/usr/local`, Qubes
runtime directories, and Qubes compatibility links into the current system
profile.  Source-changing adaptations are named by Guix phase and documented;
if reviewers prefer standalone patch files, the source-edit rows in
`ADAPTATION_INVENTORY.md` are the conversion map.

## Online Source Crosswalk

This is a targeted review of Qubes' authoritative docs, current Builder and
release-config code, forum precedent, and the closest comparable issue/PRs.
It was last spot-refreshed on 2026-05-18.  It is not a claim that every Qubes pull
request or issue has been exhaustively reviewed.

- Qubes package contribution docs:
  `https://doc.qubes-os.org/en/latest/developer/general/package-contributions.html`
  Expectation: a contributed package must preserve Qubes security, be
  open-source, be tested, have a clear use case, avoid undue review burden, be
  signed, and expose build scripts, dependencies, hashes, RPM/DEB scripts,
  Makefiles, and reproducibility for review.
  Local response: `COPYING`, SPDX headers, `README.md`, `REVIEW_NOTES.md`,
  `ADAPTATION_INVENTORY.md`, `VALIDATION.md`, `scripts/check-qubes-pins.sh`,
  and this audit-oriented document set.
- Qubes contribution and AI policy:
  `https://doc.qubes-os.org/en/latest/introduction/contributing.html`
  Expectation: significant work should be discussed first, and
  generative-AI-assisted contributions must be disclosed and manually owned by
  the contributor.
  Local response: `REVIEW_NOTES.md` and `SUBMISSION_AUDIT.md` make AI
  disclosure explicit while deferring release-owner metadata to publication.
- Qubes issue-tracking guidance:
  `https://doc.qubes-os.org/en/latest/introduction/issue-tracking.html`
  Expectation: contributors should search existing issues first, include
  relevant documentation and issue links, and independently check any
  AI-assisted reports against official documentation before maintainers spend
  review time on them.
  Local response: this crosswalk names the closest comparable Qubes issues,
  PRs, docs, and forum precedents; `SUBMISSION_DRAFTS.md` leaves the
  `[Contribution]` issue text as a human-owned draft instead of treating this
  branch as a ready-to-file upstream report.
- Qubes Builder v2 docs:
  `https://doc.qubes-os.org/en/latest/developer/building/qubes-builder-v2.html`
  Expectation: build and release stages are expected to run through Builder v2,
  with source/build work isolated and release stages explicit.
  Local response: `Makefile`, `Makefile.builder`, `builder-v2-template/`, and
  `scripts/builder-v2-template-adapter.sh` expose reviewable `prepare`,
  `build-rootimg`, and `build-rpm` entry points.
- Qubes issue `QubesOS/qubes-issues#8774`, Builder environment distribution:
  `https://github.com/QubesOS/qubes-issues/issues/8774`
  Expectation: Builder setup and version alignment are themselves review and
  reproducibility concerns; a template contribution should not depend on an
  undocumented local builder state.
  Local response: `config/channels.scm`, `config/README.md`,
  `builder-v2-template/`, `Makefile.builder`, and `VALIDATION.md` record the
  current known-good build inputs, remote builder path, and Builder/release-config
  sketch checks.  Publication still needs Builder reproduction from the final
  public branch or release object.
- Qubes Builder v2 template plugin:
  `https://github.com/QubesOS/qubes-builderv2/blob/main/qubesbuilder/plugins/template/__init__.py`
  Expectation: the template plugin has explicit `prep`, `build`, `sign`,
  `publish`, and `upload` stages and only supports existing template
  distribution families.
  Local response: `config/qubes-builderv2-guix.example.patch` adds a Guix
  distribution/template path instead of pretending local scripts are sufficient
  upstream integration.
- Qubes Builder v2 distribution model:
  `https://github.com/QubesOS/qubes-builderv2/blob/main/qubesbuilder/distribution.py`
  Expectation: current distribution recognition covers Fedora/CentOS,
  Debian/Ubuntu, Arch Linux, Gentoo, and Windows; `guix` is not currently
  accepted.
  Local response: `config/qubes-builderv2-guix.example.patch` isolates the
  required `vm-guix` distribution addition.
- Qubes R4.3 community release config:
  `https://github.com/QubesOS/qubes-release-configs/blob/main/R4.3/qubes-os-r4.3-templates-community.yml`
  Expectation: community templates are declared as Builder components plus
  template entries and publish first to `templates-community-testing`;
  release-owner metadata belongs to the publication request.
  Local response: `config/qubes-os-r4.3-templates-community-guix.example.yml`
  and `config/qubes-release-configs-guix.example.patch` provide the matching
  `builder-guix`, `guix`, and `guix-minimal` skeletons while leaving
  release-owner metadata out of the RFC sketch.
- Qubes template documentation:
  `https://doc.qubes-os.org/en/latest/user/templates/templates.html`
  Expectation: community templates are not updated by the Qubes Project in the
  same way as official templates; users trust the template maintainer as part of
  the template trust path.
  Local response: `MAINTENANCE.md` records the update cadence, security rebuild
  inputs, and handoff/removal policy, while leaving release-owner identity and
  signing metadata for the publication request.
- Qubes Forum, "New packages and templates for Qubes":
  `https://forum.qubes-os.org/t/new-packages-and-templates-for-qubes/26565`
  Expectation: unofficial package/template repositories can be useful review
  and testing surfaces, but users are explicitly trusting the publisher; the
  cited examples are built with Qubes Builder v2 and signed with the publisher's
  Qubes OS signing key.
  Local response: this repository keeps the Guix template work in RFC/review
  branches, keeps maintainer identity and release signing out of the generic
  review artifacts, and documents that publication needs a real release owner,
  signing process, update cadence, and removal/handoff policy.
- Qubes Forum, "Building F42 template in R4.3":
  `https://forum.qubes-os.org/t/building-f42-template-in-r4-3/40176`
  Expectation: current R4.3 template-build practice uses Builder v2 with a
  release-config YAML, runs `template fetch prep build`, produces a
  Qubes-sized root image, and then imports/tests it as a TemplateVM.
  Local response: the Guix tree keeps the same Builder v2/release-config split,
  uses the same 20G root image convention as the Builder v2 default used by
  standard Fedora/Debian template entries, and keeps import/runtime validation
  in `VALIDATION.md` instead of treating a local root image build as enough.
- Qubes Forum, "Dev : Using Qubes Builder v2":
  `https://forum.qubes-os.org/t/dev-using-qubes-builder-v2/35032`
  Expectation: Builder v2 work should be reproducible from a builder
  configuration, use explicit components/distributions/templates, and inspect
  the resulting template RPM metadata and payload before installing with
  `qvm-template`.
  Local response: `config/`, `builder-v2-template/`,
  `scripts/package-native-template-rpm.sh`,
  `tests/build-native-rootfs-policy-check.sh`, and
  `tests/rpm-layout-check.sh` make the Guix builder inputs, pinned-channel
  release-build policy, and resulting RPM contract inspectable.
- Qubes Forum, "How to make a template":
  `https://forum.qubes-os.org/t/how-to-make-a-template/34320`
  Expectation: the right template-building path depends on the target OS and
  which services the template needs to provide.  HVM templates, AppVM-capable
  templates, and templates that provide inter-qube services have different
  difficulty levels; current readers should also be careful with older
  BuilderPlugins-era guidance now that Builder v2 is the documented path.
  Local response: `REVIEW_NOTES.md`, `ADAPTATION_INVENTORY.md`, and
  `SECURITY.md` keep the first Guix scope limited to TemplateVM/AppVM behavior,
  qrexec, QubesDB, GUI/appmenus, private persistence, updates proxy, swap, and
  memory ballooning.  `config/` and `builder-v2-template/` intentionally follow
  the current Builder v2/release-config model rather than relying on the old
  BuilderPlugins API.
- Qubes Forum, "Building a TemplateVM for a new OS":
  `https://forum.qubes-os.org/t/building-a-templatevm-for-a-new-os/18972`
  Expectation: new OS templates should start from Builder scripts, adapt the
  standard template hooks, package the Qubes VM agents, and prove qrexec plus GUI
  readiness.
  Local response: `builder-v2-template/` implements the standard hook shape;
  `native/modules/qubes/packages/qubes-vm.scm` packages the VM agents; and
  `VALIDATION.md` separates build, `qvm-template` lifecycle,
  RPM-mode openQA, update-proxy, and dynamic memory-pressure evidence from
  final publication reruns.  The RPM-mode openQA path now has a passing
  rebuilt minimal job for the Guix-specific daemon/client proxy verifier and a
  later passing controlled `guix download` through a temporary `sys-net` stub;
  openQA job 44 remains the controlled-path proof and verifies that the source
  TemplateVM had no direct default route.  OpenQA job 129 is the current
  central-updater proof: it passed RPM import, TemplateVM/AppVM smoke,
  generated Guix proxy configuration, standard Debian `sys-net` update-target
  bootstrap, raw `qubes.UpdatesProxy` probing, and a full `qubes-vm-update`
  path that ran `guix time-machine --branch=master`, reconfigured
  `/etc/config.scm`, emitted package metadata, and exited the update agent with
  status 0.  OpenQA job 133 reran the same path with the corrected log harness
  and longer openQA job limit; it reached Guix through the Qubes update proxy
  but failed refresh on a transient upstream Git HTTP 504, which is logged as an
  external fetch failure rather than a Qubes qrexec/policy failure.  Earlier
  jobs 29 and 40 reached the opt-in public-network download gate but hit
  nested-environment update-proxy refusal.
  The opt-in
  `scripts/test-guix-update-proxy-download-dom0.sh` gate is the intended check
  for a real `guix download` through Qubes updates proxy when the review
  environment has an allowed update target with working Internet access.
- Qubes Forum, Gentoo template maintenance infrastructure:
  `https://forum.qubes-os.org/t/new-gentoo-templates-and-maintenance-infrastructure/961`
  Expectation: source-style community templates need maintained build
  infrastructure and automated validation beyond ordinary CI, with openQA as
  part of the path.
  Local response: `openqa/`, `scripts/run-openqa-template-rpm.sh`, and
  `scripts/test-template-rpm-lifecycle-dom0.sh` are present.  Nested dom0
  lifecycle and TemplateVM/AppVM smoke evidence exists for
  install/reinstall/remove, and RPM-mode openQA is green for the 2026051602
  RPMs.  `SUBMISSION_AUDIT.md` still blocks upstream claims until final
  publication evidence and release-owner pieces exist.
- Qubes Forum, "Gentoo template missing?":
  `https://forum.qubes-os.org/t/gentoo-template-missing/39654`
  Expectation: when a community template loses active maintenance, users may no
  longer find it through Template Manager and may be directed to rebuild it
  themselves.
  Local response: `MAINTENANCE.md` requires a handoff plan and explicitly says
  to stop promotion or ask Qubes maintainers to remove/hide the template if no
  replacement maintainer is available.
- Existing Guix issue:
  `https://github.com/QubesOS/qubes-issues/issues/1908`
  Expectation: Guix has been discussed in Qubes before, mainly around
  reproducible builds, transactional package management, and the list of Qubes
  packages/services needed for a usable VM.
  Local response: any future `[Contribution] qubes-template-guix` issue should
  link that older discussion instead of appearing as a disconnected duplicate,
  while keeping this work scoped to a native Guix System TemplateVM and the
  concrete Qubes TemplateVM/AppVM service contracts.
- Comparable NixOS contribution issue and PRs:
  `https://github.com/QubesOS/qubes-issues/issues/7992`,
  `https://github.com/QubesOS/qubes-core-admin-linux/pull/168`, and
  `https://github.com/QubesOS/qubes-core-agent-linux/pull/481`
  Expectation: declarative/non-FHS templates need complete Qubes package
  coverage, distro metadata, update integration, signed/rebased reviewable
  changes, continuity across rebuilds, and openQA/integration evidence for
  behavior that depends on dom0 rather than ordinary unit-test-only coverage.
  Maintainer and triage comments also distinguish issue tracking from support
  discussion, and point distro update integration toward persistent
  package-manager configuration rather than asking the user for an ad hoc long
  update command every time.
  Local response: `REVIEW_NOTES.md`, `MAINTENANCE.md`,
  `ADAPTATION_INVENTORY.md`, the Builder/release-config sketches, and
  `config/qubes-core-admin-linux-guix-vmupdate.example.patch` keep those
  expectations visible instead of hiding them behind a local RPM build.  The
  vmupdate sketch is intentionally in the Qubes central updater path: it adds a
  Guix backend for `guix time-machine --branch=master -- describe` refresh and
  `guix time-machine --branch=master -- system reconfigure /etc/config.scm`
  through the Qubes updates-proxy environment, with per-output system profile
  manifest entries reported to dom0 through the normal updater package-summary
  format after preserving manifest columns before Qubes output sanitization.
  The reconfigure path is anchored on `/etc/config.scm`, not on per-update
  user-supplied command text.
- Comparable update/proxy PRs:
  `https://github.com/QubesOS/qubes-core-admin-linux/pull/192` and
  `https://github.com/QubesOS/qubes-core-agent-linux/pull/604`
  Expectation: new update backends and update-proxy integrations are reviewed
  as component-specific changes, need to survive current upstream refactors, and
  should keep behavior simple while documenting operational rough edges instead
  of adding hidden restart or hook policy.
  Local response: `config/qubes-core-admin-linux-guix-vmupdate.example.patch`
  keeps the Guix updater change isolated in `qubes-core-admin-linux`,
  `scripts/test-guix-central-vmupdate-dom0.sh` now requires the generated Guix
  proxy wrapper, raw-probes the Qubes updates proxy to the Guix channel host,
  rejects direct-route TemplateVM proof, forces both refresh and reconfigure,
  and checks the expected Guix log markers before accepting central-updater
  evidence.  The documented update gates distinguish controlled proxy checks
  from real Internet
  `guix time-machine`/substitute proof.
- Related Qubes update-proxy issue threads:
  `https://github.com/QubesOS/qubes-issues/issues/6274`,
  `https://github.com/QubesOS/qubes-issues/issues/9070`,
  `https://github.com/QubesOS/qubes-issues/issues/10513`,
  `https://github.com/QubesOS/qubes-issues/issues/4096`, and
  `https://github.com/QubesOS/qubes-issues/issues/3412`
  Expectation: update-proxy behavior depends on Qubes global update settings,
  policy target selection, the update target existing and running, and the
  target actually providing the `qubes.UpdatesProxy` service.  Custom or
  disposable update targets are especially sensitive to service state and
  policy defaults.
  Local response: `scripts/test-guix-central-vmupdate-dom0.sh` logs
  `updatevm`, matching `qubes.UpdatesProxy` policy entries, and the
  standard `sys-net` target state before accepting any central updater proof.
  `scripts/setup-openqa-guix-template-test.sh` warns when the central vmupdate
  openQA gate is scheduled that a controlled/stub updates-proxy target is not
  sufficient proof.  This keeps the Guix work aligned with Qubes' existing
  update-proxy model instead of hiding a missing update target behind Guix
  tooling.

## Qubes Review Norms

The Qubes package contribution process says accepted packages must not weaken
Qubes security, must be open-source licensed, must follow coding guidelines,
must be thoroughly tested, must have a clear Qubes use case, and must not be
unduly burdensome to review.  It recommends discussing serious package work on
`qubes-devel` before submission, publishing the code on GitHub, signing the
code, and opening a `[Contribution] ...` issue with the repository link and use
case.  The review focuses especially on package dependencies, build scripts,
downloaded components with static hashes, RPM/DEB scripts, Makefiles, and
reproducibility.
Qubes' contribution guidance also covers generative-AI-assisted work.  Because
this repository has AI-assisted history, the upstream discussion should disclose
that fact, and whoever asks for publication should own the reviewed release
state they are asking Qubes to publish.

Qubes Forum discussion around contributed packages reinforces that contribution
packages are a community maintenance effort and that authors are expected to
help maintain or fix build issues.  The Gentoo template announcement is the
closest precedent for a new source-style template: it started in
`qubes-templates-community-testing`, required automated build testing beyond
normal CI capacity, used openQA as part of validation, and later moved toward
stable community templates after repeated successful infrastructure work.
The template documentation and later Gentoo availability discussion also make
maintainer continuity a release property, not only a social detail: users trust
the community template maintainer, and a template that no longer has an active
maintainer may disappear from Template Manager rather than remain a supported
download.

For Guix, the practical implication is that an upstream submission should lead
with build/test infrastructure and maintainer commitments, not only with a
working root image.

The comparable Alpine and Flatpak update PR discussions reinforce the same
review shape for the update path: keep the updater or proxy change in the
component that owns it, expect rebase work when the shared updater code changes,
document limitations that need a template restart or a later user action, and
avoid inventing hidden auto-restart policy just to make a demo pass.
The related update-proxy issues add a practical release-test requirement: the
central Guix update gate must run in a Qubes setup where the configured update
target exists, starts correctly, and provides `qubes.UpdatesProxy`.  A
temporary stub remains useful for deterministic qrexec coverage, but it is not
substitute evidence for the real update target path.

Qubes Forum guidance for building a TemplateVM for a new OS starts from Qubes
builder scripts for the target OS, using Fedora/Debian/Arch scripts as models.
That matches the remaining Guix gap: this repository now exposes Builder-v2
shaped targets for a Guix-aware integration and the standard content-script
shape under `builder-v2-template/`.  Upstream still needs Qubes Builder v2 to
recognize `dist: guix` and point `TEMPLATE_CONTENT_DIR` at those scripts, or a
small Builder v2 template-plugin change that calls this repository's
`make prepare build-rootimg` and `make prepare build-rpm` adapter directly.
The example patch in `config/qubes-builderv2-guix.example.patch` takes the
content-script route.
In both cases Qubes Builder must be able to fetch, build, sign, publish, and
upload the resulting template RPM through its normal stages.

Forum discussion around adding a new OS template also emphasizes that the hard
part is not naming a template, but making the target OS fit the Qubes builder
and agent model.  For Guix that means the submission should be framed as a
`builder-guix` or `qubes-template-guix` component with test evidence, not as a
request for Qubes to host an opaque prebuilt image.

## Hosted Builder Component

A review mirror of the Builder component is available at:

```text
https://github.com/<owner>/qubes-builder-guix
```

That URL is intentionally not baked into the release-config snippets below.
It is a concrete source tree for reviewers to inspect and test.  The eventual
publication owner or Qubes maintainers should adopt, fork, or replace it and
then substitute the accepted owner URL in release config.

## Implemented Review Cleanups

- The package source path no longer depends on local Qubes source checkouts.
  Sources use `git-fetch`, explicit commits, and recursive Guix hashes.
- Runtime Guix configuration is self-contained in `/etc/config.scm` inside the
  template image.
- The release channel pin is installed in `/etc/guix/channels.scm` instead of
  baking an imperative `guix pull` profile into the image.
- Qubes swap is declared with Guix `swap-devices` for `/dev/xvdc1`.
- PAM entries are provided through `pam-root-service-type`, not package-time
  mutation of `/etc/pam.d`.
- Qubes meminfo writer is packaged and started through a configurable Shepherd
  service.
- Normal and minimal Guix system records have an executable contract check for
  standard swap, the standard `user` account and Qubes group membership,
  default privileged programs, passwordless sudo, required Qubes services, and
  `meminfo-writer` defaults.
- Disabled upstream package tests include local rationale in the package
  definitions.
- Qubes VM component freshness is checkable with an explicit maintainer command
  that compares upstream release tags by peeled commit.
- Builder-v2-shaped `prepare`, `build-rootimg`, and `build-rpm` targets are
  present as an adapter around the existing native Guix scripts.
- The local RPM layout test no longer uses fragile pipelines under `pipefail`;
  it extracts template RPMs through an intermediate cpio file.
- A separate `qubes-builder-guix` component repository now carries only the
  Builder-facing hooks, Guix system definitions, pinned channel, RPM packaging,
  and behavior tests.  It deliberately omits cloud/nested-dom0 setup, generated
  artifacts, logs, and signing keys.

## Release-Config Sketch

Do not treat this block as publishable release metadata.  The current RFC keeps
release ownership out of the review gate; final publication metadata has to
come from whoever owns the accepted release.
The same sketch is available as
`config/qubes-os-r4.3-templates-community-guix.example.yml`, and as a patch
sketch in `config/qubes-release-configs-guix.example.patch`.

```yaml
components:
  - builder-guix:
      packages: False
      fetch-versions-only: false
      branch: main
      url: https://github.com/<OWNER>/qubes-builder-guix

templates:
  - guix:
      dist: guix
      timeout: 21600
  - guix-minimal:
      dist: guix
      flavor: minimal
      timeout: 21600
```

The current R4.3 community template config publishes templates to
`templates-community-testing` first, and existing rolling/source-style examples
such as Arch Linux and Gentoo are represented as Builder components plus
template entries.  Guix should follow that model rather than shipping only an
ad hoc RPM script.

## Release Evidence Checklist

Record fresh evidence from a clean tree before opening the Qubes contribution
issue.  The current partial evidence snapshot is in `VALIDATION.md`.

- `git status --short` with no unrelated source dirt in the submitted tree.
- Public review repository URL.
- Release-owner signing metadata only when asking for publication.
- `make check`.
- `make check-qubes-pins`.
- `guix time-machine -C config/channels.scm -- describe`.
- Normal root image build, image inspection, writable-root activation test,
  template RPM build with `root.img.part.NN` payloads, and RPM-mode openQA
  result.
- Minimal root image build, image inspection, writable-root activation test,
  template RPM build with `root.img.part.NN` payloads, and RPM-mode openQA
  result.
- `qvm-template --yes install --nogpgcheck` install, reinstall, remove,
  upgrade, and downgrade checks for both variants.  Current nested-dom0
  evidence covers install, reinstall, metadata checks, smoke, distinct-EVR
  upgrade, downgrade, and remove; final release evidence must rerun them from
  the publication branch or release object.
- TemplateVM and AppVM smoke results for QubesDB, qrexec, GUI/appmenus,
  shutdown, `/rw`, `/home`, `/usr/local`, `/dev/xvdc1` swap activation, and
  guest-side `meminfo-writer` startup.  Current nested-dom0 evidence covers
  these basic smoke gates for both variants; final release evidence must rerun
  them from the publication branch or release object.
- Dynamic memory-balloon resize behavior under dom0 pressure.  Current
  nested-dom0 evidence shows a Guix AppVM growing from 400 MiB to 698 MiB
  under guest allocation pressure; final release evidence must rerun it from
  the publication branch or release object.
- Real Guix update/download behavior through an Internet-capable Qubes update
  proxy target.  Current evidence verifies Qubes forwarding, generated Guix
  proxy configuration, service state, and a controlled `guix download` through a
  temporary `sys-net` stub; openQA job 44 remains the controlled-path proof and
  includes the no-direct-default-route guard.  OpenQA job 129 passed the central
  update path through a standard Debian `sys-net` update target and produced
  Guix system package metadata with agent exit status 0.  OpenQA job 133
  reached the same path but failed on `guix time-machine` receiving HTTP 504
  from the upstream Git fetch.  Final publication evidence should still rerun
  the same gate from the exact publication branch or release object, because
  public network and substitute availability are external variables.
- Optional Qubes dom0 integration results for `qubes.tests.integ.qrexec` and
  `qubes.tests.integ.vm_qrexec_gui`, with any nested-virtualization host limits
  called out separately.

## Compatibility Exceptions

Some Qubes runtime wrappers intentionally use
`/run/current-system/profile/bin/sh` and profile-visible Qubes binaries instead
of direct store references.  Directly replacing those paths with store
references was tested and broke qrexec after reboot.  For those wrappers, the
mutable profile path is part of the Qubes runtime compatibility contract rather
than an accidental impurity.

## Remaining Upstreaming Work

1. Keep the public review branch clean and reproducible; signed release tags
   can be added by the eventual release owner when publication is actually
   requested.
2. Start a `qubes-devel` design thread before asking for merge.  Include the
   repository link, threat model, build pipeline, release scope, and openQA
   evidence.
3. Resolve upstream PR policy state or keep the PRs explicitly RFC-only:
   Qubes code-signing and CI are green on the current heads, but core-admin
   Linux still needs maintainer tagging.
4. Decide the final Qubes Builder v2 integration shape.  Current builder
   template support covers established distributions by calling the standard
   template Makefile plus distribution content scripts.  Guix likely needs
   either a Guix-aware distribution/template plugin path that calls this
   repository's adapter targets, or a `builder-guix` component that points
   `TEMPLATE_CONTENT_DIR` at `builder-v2-template/`.  The example Builder v2
   patch in `config/qubes-builderv2-guix.example.patch` documents the latter.
5. Add release-config-ready metadata for `guix` and `guix-minimal`, including
   component names, template names, and upload target.  Maintainer/signing
   metadata is left out of the current review gate and becomes a publication
   gate for whoever owns a real release.
6. Convert invasive source substitutions into either small patch files or
   clearly grouped build phases with rationale, threat model, and tests.
7. Run fresh release evidence from a clean tree for both variants:
   rootfs build, image inspection, activation test, RPM layout, RPM packaging,
   `qvm-template` upgrade/downgrade, TemplateVM smoke, AppVM smoke,
   update-proxy forwarding, Guix daemon/client proxy configuration,
   dynamic memory-balloon pressure behavior, and RPM-mode openQA.
   Re-run install/reinstall/remove as part of final release evidence even
   though the current nested-dom0 snapshot passed those gates.
8. Keep `MAINTENANCE.md` current with the release cadence, update sources, Guix
   reconfiguration expectations, rollback procedure, and eventual release
   ownership.

Until those items are complete, this should be treated as a working prototype
with local validation, not as a publishable Qubes community template.

## Source References

- Qubes package contributions:
  `https://doc.qubes-os.org/en/latest/developer/general/package-contributions.html`
- Qubes contribution guide, including GenAI-assisted contribution policy:
  `https://doc.qubes-os.org/en/latest/introduction/contributing.html`
- Qubes Template Manager package format:
  `https://doc.qubes-os.org/en/latest/developer/system/template-manager.html`
- Qubes template trust and update model:
  `https://doc.qubes-os.org/en/latest/user/templates/templates.html`
- Qubes `qvm-template` command reference:
  `https://dev.qubes-os.org/projects/core-admin-client/en/latest/manpages/qvm-template.html`
- Qubes Builder v2 template plugin:
  `https://raw.githubusercontent.com/QubesOS/qubes-builderv2/main/qubesbuilder/plugins/template/__init__.py`
- Qubes Builder v2 distribution model:
  `https://raw.githubusercontent.com/QubesOS/qubes-builderv2/main/qubesbuilder/distribution.py`
- Qubes issue for Builder environment reproducibility:
  `https://github.com/QubesOS/qubes-issues/issues/8774`
- Qubes R4.3 community template release config:
  `https://raw.githubusercontent.com/QubesOS/qubes-release-configs/main/R4.3/qubes-os-r4.3-templates-community.yml`
- Qubes Forum, "Building a TemplateVM for a new OS":
  `https://forum.qubes-os.org/t/building-a-templatevm-for-a-new-os/18972`
- Qubes Forum, "New Gentoo templates and maintenance infrastructure":
  `https://forum.qubes-os.org/t/new-gentoo-templates-and-maintenance-infrastructure/961`
- Qubes Forum, maintainer availability affecting Gentoo template visibility:
  `https://forum.qubes-os.org/t/gentoo-template-missing/39654`
- Qubes issue, prior Guix discussion:
  `https://github.com/QubesOS/qubes-issues/issues/1908`
- Qubes issue, comparable NixOS template contribution tracker:
  `https://github.com/QubesOS/qubes-issues/issues/7992`
- Qubes PR, comparable NixOS update integration:
  `https://github.com/QubesOS/qubes-core-admin-linux/pull/168`
- Qubes PR, comparable Alpine `vmupdate` backend:
  `https://github.com/QubesOS/qubes-core-admin-linux/pull/192`
- Qubes PR, comparable Flatpak update-proxy integration:
  `https://github.com/QubesOS/qubes-core-agent-linux/pull/604`
- Qubes issue, updates proxy support for UpdateVM:
  `https://github.com/QubesOS/qubes-issues/issues/6274`
- Qubes issue, custom update proxy service state:
  `https://github.com/QubesOS/qubes-issues/issues/9070`
- Qubes issue, global default update proxy settings:
  `https://github.com/QubesOS/qubes-issues/issues/10513`
- Qubes issue, update proxy VM startup:
  `https://github.com/QubesOS/qubes-issues/issues/4096`
- Qubes issue, UpdateVM setting presentation:
  `https://github.com/QubesOS/qubes-issues/issues/3412`
- Local review sketch for the analogous Guix vmupdate backend:
  `config/qubes-core-admin-linux-guix-vmupdate.example.patch`
- Qubes PR, guest distribution metadata reported to dom0:
  `https://github.com/QubesOS/qubes-core-agent-linux/pull/481`
- GNU Guix manual, using the configuration system:
  `https://guix.gnu.org/manual/devel/en/html_node/Using-the-Configuration-System.html`
- GNU Guix manual, packaging guidelines:
  `https://guix.gnu.org/manual/devel/en/html_node/Packaging-Guidelines.html`
- GNU Guix manual, submitting patches:
  `https://guix.gnu.org/manual/devel/en/html_node/Submitting-Patches.html`
- GNU Shepherd manual, declarative service definitions:
  `https://www.gnu.org/software/shepherd/manual/shepherd.html`
