# Patch Series Guide

This file describes the intended human review order.  It is not a substitute for
Qubes maintainer review, signed commits, or the external Builder/release-config
changes.

## Review Chunks

1. Native Guix TemplateVM implementation:
   - `native/modules/qubes/packages/qubes-vm.scm`
   - `native/modules/qubes/services/qubes-vm.scm`
   - `native/modules/qubes/systems/guix-template.scm`
   - `native/qubes-guix.scm`
   - `native/qubes-guix-minimal.scm`

2. Root image and RPM tooling:
   - `scripts/build-native-rootfs.sh`
   - `scripts/inspect-native-rootfs.sh`
   - `scripts/test-native-rootfs-activation.sh`
   - `scripts/package-native-template-rpm.sh`
   - `scripts/builder-v2-template-adapter.sh`

3. Builder-shaped template content:
   - `builder-v2-template/`
   - `Makefile.builder`
   - `config/qubes-builderv2-guix.example.patch`

4. Release-config and publication sketch:
   - `config/qubes-os-r4.3-templates-community-guix.example.yml`
   - `config/qubes-release-configs-guix.example.patch`
   - `config/README.md`

5. Validation and lifecycle harnesses:
   - `tests/builder-content-check.sh`
   - `tests/builder-rpm-contract-check.sh`
   - `tests/rpm-layout-check.sh`
   - `scripts/test-template-rpm-lifecycle-dom0.sh`
   - `scripts/test-update-proxy-default-target-dom0.sh`
   - `scripts/test-guix-update-proxy-config-dom0.sh`
   - `scripts/diagnose-update-proxy-dom0.sh`
   - `scripts/test-memory-balloon-dom0.sh`
   - `openqa/qubesos/`

6. Pin freshness hygiene, not upstream-facing test evidence:
   - `scripts/check-qubes-pins.sh`

7. Human-review documentation:
   - `README.md`
   - `REVIEWER_GUIDE.md`
   - `UPSTREAMING.md`
   - `REVIEW_NOTES.md`
   - `ADAPTATION_INVENTORY.md`
   - `SECURITY.md`
   - `TEMPLATE_PRECEDENTS.md`
   - `MAINTENANCE.md`
   - `CONTRIBUTING.md`
   - `SUBMISSION_AUDIT.md`
   - `SUBMISSION_DRAFTS.md`
   - `VALIDATION.md`

## Multi-Repo Submission Order

1. Publish the template repository with a named maintainer and signed release
   tag.
2. Start the `qubes-devel` design thread with the scope, non-goals, validation
   evidence, and maintainer/update story.  `SUBMISSION_DRAFTS.md` has a draft
   thread body to edit after placeholders and validation evidence are current.
3. Submit or discuss the Builder v2 `dist: guix` path using
   `config/qubes-builderv2-guix.example.patch` as the review sketch.
4. Submit release-config entries only after the Builder path is accepted and the
   maintainer fingerprint is known.  Use the release-config draft only after
   replacing maintainer placeholders and refreshing the release evidence.
5. Run fresh RPM-mode openQA and `qvm-template` lifecycle tests from the final
   signed public branch before asking for publication in
   `templates-community-testing`.

## History Expectations

Before public submission, publish only the cleaned review branch.  Keep any
local backup refs private, and do not ask Qubes reviewers to review generated
artifacts or obsolete experimental history.
