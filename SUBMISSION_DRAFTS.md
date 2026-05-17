# Submission Drafts

These drafts are intentionally not final upstream text.  Replace every
placeholder, refresh every validation result from the signed public branch, and
remove any claim that is not backed by `VALIDATION.md` before submitting.

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

Maintainer:
  <NAME>
  <GPG_FINGERPRINT>

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

Validation snapshot from the signed public branch:
  - <make check result>
  - <make guix-system-contract-check result>
  - <make check-qubes-pins result>
  - <guix time-machine -C config/channels.scm -- describe result>
  - <normal rootfs/RPM/openQA result>
  - <minimal rootfs/RPM/openQA result>
  - <qvm-template lifecycle result>
  - <TemplateVM/AppVM smoke result>
  - <controlled updates-proxy stub download result>
  - <dynamic memory-balloon pressure result>

Known remaining questions:
  - Preferred Builder v2 integration shape for dist: guix.
  - Whether Qubes reviewers prefer the Guix-specific source edits as separate
    patch files or as named Guix package phases with rationale.
  - Whether the maintainer handoff/removal policy is sufficient for a community
    template that depends on maintainer-owned builds.
  - Required promotion criteria from templates-community-testing to
    templates-community.
  - Required evidence for real Guix pull/substitute/download behavior through an
    Internet-capable Qubes update-proxy target.

This work was assisted by generative AI.  I have manually reviewed the submitted
changes, will maintain the package, and will take responsibility for fixing
review and build issues.
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

### Maintainer

Name: <NAME>
GPG fingerprint: <GPG_FINGERPRINT>
Signed tag or signed commit: <TAG_OR_COMMIT>
Maintenance handoff plan: see MAINTENANCE.md

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

### External changes needed

Builder v2:
  - See config/qubes-builderv2-guix.example.patch.
  - Adds a Guix distribution/template path or an equivalent maintainer-approved
    Builder v2 integration.

Release config:
  - See config/qubes-release-configs-guix.example.patch.
  - Adds builder-guix plus guix and guix-minimal entries for
    templates-community-testing.

### Validation evidence

Attach current evidence from the signed public branch:
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
update-proxy target gate passes from the signed public branch.  A controlled
stub download is useful proxy-path evidence, but it is not substitute-download
or channel-update evidence.

### AI disclosure

This contribution was prepared with generative-AI assistance.  The maintainer
has manually reviewed the code and documentation and accepts maintenance
responsibility.
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
  - <qubes-devel thread URL>
  - <qubes-issues contribution URL>

The template repository exposes standard content scripts under
builder-v2-template/ and adapter targets for prepare/build-rootimg/build-rpm.
The release-config PR should not land until the Builder v2 path is accepted.

Validation:
  - python -m pytest tests/test_objects.py::test_dist
  - python -m pytest tests/test_objects.py::test_dist_family
  - python -m pytest tests/test_objects.py::test_template_plugin_supports_guix
  - <additional Builder v2 tests requested by maintainers>
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

Maintainer:
  <NAME>
  <GPG_FINGERPRINT>
  Handoff/removal policy: see MAINTENANCE.md

Repository:
  https://github.com/<OWNER>/<REPOSITORY>

Validation from the signed public branch:
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

Do not merge this PR while maintainer identity, signing, maintainer handoff
policy, Builder v2 support, or fresh release validation is missing.
```
