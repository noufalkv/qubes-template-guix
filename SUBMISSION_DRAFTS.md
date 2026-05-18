# Submission Drafts

These drafts are intentionally not final upstream text.  Replace every
placeholder, refresh every validation result from the final public branch or
release object, and remove any claim that is not backed by `VALIDATION.md`
before submitting.  If a release gate is still missing, say so explicitly
instead of omitting it.

This repository may be used for a one-shot technical review prepared by an
autonomous AI coding agent, but that does not establish a Qubes community
template maintainer.  Leave release-owner metadata out of RFC/review requests
unless a real publication owner is ready to supply it.

## Current Review Links

These URLs document the current RFC/review surface.  They are not publication
metadata and should be replaced, adopted, or removed by the eventual release
owner before asking Qubes to publish a maintained template.

- Template review branch:
  `https://github.com/<owner>/qubes-template-guix/tree/upstream-review`
- Builder component review mirror:
  `https://github.com/<owner>/qubes-builder-guix`
- Builder v2 RFC PR:
  `https://github.com/QubesOS/qubes-builderv2/pull/245`
- Core-admin-linux vmupdate RFC PR:
  `https://github.com/QubesOS/qubes-core-admin-linux/pull/211`
- Release-config RFC PR:
  `https://github.com/QubesOS/qubes-release-configs/pull/19`
- Prior Guix discussion:
  `https://github.com/QubesOS/qubes-issues/issues/1908`
- Comparable NixOS template tracker:
  `https://github.com/QubesOS/qubes-issues/issues/7992`

## qubes-devel Design Thread

Subject:

```text
[RFC] Native GNU Guix System TemplateVM for Qubes OS R4.3
```

Body:

```text
I would like feedback on a proposed community template for GNU Guix System on
Qubes OS R4.3.

Repository:
  https://github.com/<OWNER>/<REPOSITORY>

Release owner for publication:
  <NAME or TBD for one-shot AI-submitted review>

Submission disclosure:
  This draft was prepared by an autonomous AI coding agent as shared one-shot
  work.  It does not claim maintainer status.  Release-owner metadata is
  intentionally deferred until a package-publication request.

Scope for the first review:
  - R4.3, x86_64, TemplateVM/AppVM use.
  - PVH, dom0-provided kernel, no guest bootloader.
  - qrexec, QubesDB, GUI/appmenus, shutdown, private volume persistence,
    updates proxy forwarding, standard Qubes swap, guest-side meminfo-writer,
    default privileged helpers, and Qubes-style passwordless sudo.
  - Two variants: guix and guix-minimal.

Non-goals for the first review:
  - NetVM/ProxyVM/firewall ownership.
  - Direct promotion to stable templates-community.
  - An opaque prebuilt image outside the Qubes Builder/release-config path.

The repository includes:
  - Native Guix package definitions for Qubes VM agents.
  - Shepherd service mappings for Qubes VM services.
  - qvm-template-compatible RPM packaging.
  - Builder-v2-shaped content scripts and adapter targets.
  - Example Builder v2 and release-config patches.
  - openQA and qvm-template lifecycle harnesses.
  - Review notes, adaptation inventory, validation evidence, and maintenance
    policy.
  - A maintainer handoff/removal policy for the community-template trust path.

Validation snapshot from the final public branch or release object:
  - <make check result>
  - <make guix-system-contract-check result>
  - <make check-qubes-pins result>
  - <guix time-machine -C config/channels.scm -- describe result>
  - <normal rootfs/RPM/openQA result>
  - <minimal rootfs/RPM/openQA result>
  - <qvm-template lifecycle result>
  - <TemplateVM/AppVM smoke result>
  - <Builder v2 focused test result>
  - <release-config YAML validation result>
  - <controlled updates-proxy stub download result>
  - <real Internet update-proxy Guix update/download result, or explicit
    missing-gate statement>
  - <dynamic memory-balloon pressure result>

Known remaining questions:
  - Preferred Builder v2 integration shape for dist: guix.
  - Whether Qubes reviewers prefer the Guix-specific source edits as separate
    patch files or as named Guix package phases with rationale.
  - Whether the handoff/removal policy is sufficient for a community template
    that depends on independently maintained builds.
  - Required promotion criteria from templates-community-testing to
    templates-community.
  - Required evidence for real Guix pull/substitute/download behavior through an
    Internet-capable Qubes update-proxy target.

This work was prepared with generative-AI assistance.  If this is submitted
directly as an autonomous AI one-shot contribution, it is a request for design
and technical review only.  A release owner must review the submitted changes,
supply the publication tag or commit, and accept maintenance responsibility
before Qubes publication is requested.
```

## qubes-issues Contribution Issue

Title:

```text
[Contribution] qubes-template-guix
```

Body:

```text
### Qubes OS release

R4.3

### Contribution type

Community template:
  - guix
  - guix-minimal

### Repository

https://github.com/<OWNER>/<REPOSITORY>

### Release Owner

Name: <NAME or TBD for one-shot AI-submitted review>
Publication tag or commit: <TAG_OR_COMMIT or TBD>
Maintenance handoff plan: see MAINTENANCE.md

If the issue is opened as an autonomous AI one-shot contribution, these
release-owner fields are intentionally placeholders.  Do not treat that as a
request to publish a maintained community template until a release owner
replaces them and supplies the publication tag or commit.

### Use case

Provide a native GNU Guix System TemplateVM for users who want Guix's
declarative system configuration, package management, rollbacks, and
reconfiguration model inside Qubes TemplateVM/AppVM workflows.

### Review map

Start with:
  - README.md
  - UPSTREAMING.md
  - REVIEW_NOTES.md
  - ADAPTATION_INVENTORY.md
  - SECURITY.md
  - TEMPLATE_PRECEDENTS.md
  - VALIDATION.md
  - MAINTENANCE.md
  - SUBMISSION_AUDIT.md

Related prior Qubes discussion:
  - QubesOS/qubes-issues#1908, "Port Guix for reproducible builds"

This issue is meant to be the concrete TemplateVM contribution tracker, not a
replacement for the older general Guix discussion.

### External changes needed

Builder v2:
  - See config/qubes-builderv2-guix.example.patch.
  - Adds a Guix distribution/template path or an equivalent maintainer-approved
    Builder v2 integration.

Core admin Linux:
  - See config/qubes-core-admin-linux-guix-vmupdate.example.patch.
  - Adds a Guix vmupdate backend so dom0's centralized updater can select
    Guix update commands instead of rejecting the template as an unsupported
    OS family.  This should be reviewed separately from Builder and
    release-config publication.

Release config:
  - See config/qubes-release-configs-guix.example.patch.
  - Adds builder-guix plus guix and guix-minimal entries for
    templates-community-testing.

### Validation evidence

Attach current evidence from the final public branch or release object:
  - make check
  - make guix-system-contract-check
  - make check-qubes-pins
  - guix time-machine -C config/channels.scm -- describe
  - normal and minimal rootfs builds
  - normal and minimal RPM builds
  - RPM-mode openQA for both variants
  - qvm-template install/reinstall/remove/upgrade/downgrade checks
  - TemplateVM/AppVM smoke for QubesDB, qrexec, GUI/appmenus, shutdown, /rw,
    /home, /usr/local, swap, and guest-side meminfo-writer startup
  - update proxy forwarding, generated Guix daemon/client proxy configuration,
    controlled Guix client download through the Qubes updates proxy, real Guix
    update/download through an Internet-capable update-proxy target, and dynamic
    memory-balloon resize behavior under dom0 pressure

Do not claim real Guix pull/substitute/download support until the Internet
update-proxy target gate passes from the final public branch or release object.
A controlled stub download is useful proxy-path evidence, but it is not
substitute-download or channel-update evidence.

### AI disclosure

This contribution was prepared by an autonomous AI coding agent as shared
one-shot work.  It does not claim to be the template maintainer.  A release
owner must review the code and documentation, replace the placeholders, supply
the publication tag or commit, and accept maintenance responsibility before
publication is requested.

### Test RPMs

Untrusted test RPMs for both variants can be attached for review convenience,
but reviewers should be able to reproduce them from the public branch.  From a
clean checkout with Guix and RPM tooling available, the pinned-channel build is:

```sh
./scripts/build-native-rootfs.sh --variant normal --output root.img && ./scripts/package-native-template-rpm.sh --root-image root.img --name guix --output-dir dist && ./scripts/build-native-rootfs.sh --variant minimal --output root-minimal.img && ./scripts/package-native-template-rpm.sh --root-image root-minimal.img --name guix-minimal --output-dir dist
```

Record the resulting RPM SHA256 sums in `VALIDATION.md` before asking anyone to
test them.
```

## Builder v2 Pull Request

Title:

```text
template: add Guix template distribution hook
```

Body:

```text
This PR adds the Builder v2 side needed for a proposed Guix community template.

It is paired with:
  - <template repository URL>
  - https://github.com/<owner>/qubes-builder-guix
  - <qubes-devel thread URL>
  - <qubes-issues contribution URL>

The template repository exposes standard content scripts under
builder-v2-template/ and adapter targets for prepare/build-rootimg/build-rpm.
The hosted builder-guix repository is a review mirror, not canonical release
metadata; Qubes maintainers or the eventual publication owner should adopt,
fork, or replace it before landing a release-config URL.
The release-config PR should not land until the Builder v2 path is accepted.

Validation:
  - python -m pytest tests/test_objects.py::test_dist_non_default_arch
  - python -m pytest tests/test_objects.py::test_dist_family
  - python -m pytest tests/test_objects.py::test_template_plugin_supports_guix
  - python -m pytest tests/test_objects.py::test_template_plugin_guix_parameters
  - make check in the hosted builder-guix component
  - <additional Builder v2 tests requested by maintainers>

Do not treat those focused tests as proof that the full Builder v2 suite or the
template release is accepted.  The release-config PR and template publication
remain separate review steps.
```

## Core-Admin-Linux Pull Request

Title:

```text
vmupdate: add Guix backend
```

Body:

```text
This PR adds a Guix backend to the VM updater agent so a Guix TemplateVM can
participate in Qubes' centralized update flow.

It is paired with:
  - <template repository URL>
  - <qubes-devel thread URL>
  - <qubes-issues contribution URL>
  - <Builder v2 PR URL>

Behavior:
  - Detects Guix from os-release metadata.
  - Runs guix time-machine --branch=master -- describe for refresh.
  - Runs guix time-machine --branch=master -- system reconfigure
    /etc/config.scm for the update action.
  - Reports the Guix System generation plus /run/current-system/profile
    manifest entries as package metadata in the normal dom0 update summary.
  - Converts Guix manifest tabs to a printable separator before Qubes'
    untrusted-output sanitizer runs, so dom0 gets clear package metadata
    instead of glued fields.
  - Uses vmupdate-scoped temporary HOME/XDG state for Guix time-machine so
    central updates do not mutate root or user Guix checkouts.
  - Captures Guix stderr in the normal vmupdate log/output path.
  - Uses the Qubes updates-proxy environment for update-client VMs:
    `http_proxy`, `https_proxy`, uppercase variants, and `ALL_PROXY`
    compatibility.
  - Does not proxy a VM that itself provides qubes-updates-proxy.
  - Does not treat root's Guix checkout/profile as package-manager state.
  - Does not install hidden requirements into the root Guix profile.
  - Does not collect garbage implicitly, preserving Guix generations for
    rollback.

Validation:
  - PYTHONPATH=<qubes-core-admin-client checkout>:. ./run-tests.sh
    (current checked-in patch recheck: 48 passed, 1 warning)
  - <current template-side generated proxy configuration evidence, including
    the caveat that Guix HTTPS downloads were observed to rely on
    https_proxy rather than ALL_PROXY alone>
  - Nested-dom0 central `qubes-vm-update` reached the Guix backend, parsed
    system-profile metadata into `name:output -> version store-path` records,
    used the proxy environment, and logged `guix time-machine: error: Git
    error: unexpected EOF`; this is not a passing update because the test setup
    had no usable Internet-capable Qubes update-proxy target.

Do not treat the unit tests alone as proof of working Guix updates.  The
template repository still needs release evidence for time-machine refresh,
system reconfiguration, or a real Guix download through an Internet-capable
Qubes update-proxy target.
```

## Release-Configs Pull Request

Title:

```text
R4.3: add Guix community template entries
```

Body:

```text
This PR adds R4.3 templates-community-testing entries for:
  - guix
  - guix-minimal

It depends on accepted Builder v2 support for the Guix template distribution.
If centralized updater support is part of the requested publication scope, it
also depends on an accepted or otherwise maintainers-approved
qubes-core-admin-linux Guix vmupdate path.

Release owner for publication:
  <NAME or TBD for one-shot AI-submitted review>
  Handoff/removal policy: see MAINTENANCE.md

If this PR draft is opened from the autonomous AI one-shot review path, the
release-owner fields must stay as placeholders and the PR should be treated as
a design/review request only.  Do not request publication until a release owner
replaces them and supplies the publication tag or commit.

Repository:
  https://github.com/<OWNER>/<REPOSITORY>

Builder component:
  https://github.com/<OWNER>/qubes-builder-guix

The existing hosted `<owner>/qubes-builder-guix` tree may be used for review
or as a starting point, but this release-config draft should keep the owner
placeholder until a publication owner or Qubes-maintained fork is selected.

Validation from the final public branch or release object:
  - <make check evidence>
  - <make guix-system-contract-check evidence>
  - <make check-qubes-pins evidence>
  - <normal variant evidence>
  - <minimal variant evidence>
  - <openQA evidence>
  - <qvm-template lifecycle evidence>
  - <controlled updates-proxy stub download evidence>
  - <real Internet update-proxy Guix update/download evidence>
  - <dynamic memory-balloon pressure evidence>

Do not request publication from this PR while handoff policy, Builder v2
support, or fresh release validation is missing.  Release-owner metadata is
deferred until an accepted publication request.
```
