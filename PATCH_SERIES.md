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
   - `tests/builder-hook-contract-check.sh`
   - `tests/builder-rpm-contract-check.sh`
   - `tests/rpm-layout-check.sh`
   - `scripts/test-template-rpm-lifecycle-dom0.sh`
   - `scripts/test-update-proxy-default-target-dom0.sh`
   - `scripts/test-guix-update-proxy-config-dom0.sh`
   - `scripts/test-guix-update-proxy-download-dom0.sh`
   - `scripts/test-guix-update-proxy-stub-download-dom0.sh`
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

## Suggested Public Review Series

If the branch is rewritten before submission, prefer a small signed series that
preserves the review boundaries below.  Each commit message should explain the
user-visible purpose, the Qubes expectation it satisfies, the validation that
covers it, and any remaining gate that must not be claimed yet.

1. `Add native Guix TemplateVM systems and Qubes VM packages`
   - Include `native/modules/qubes/packages/qubes-vm.scm`,
     `native/modules/qubes/services/qubes-vm.scm`,
     `native/modules/qubes/systems/guix-template.scm`,
     `native/qubes-guix.scm`, and `native/qubes-guix-minimal.scm`.
   - Explain the Guix-specific package phases, Shepherd service mapping,
     Qubes compatibility paths, standard swap, `meminfo-writer`, privileged
     helpers, and passwordless sudo behavior in the commit body.

2. `Add Guix rootfs and qvm-template RPM tooling`
   - Include root image build, inspection, activation, RPM packaging, and
     Builder adapter scripts.
   - State that the package output follows Qubes Template Manager layout and
     that generated images/RPMs are not committed.

3. `Add Builder-shaped template hooks for Guix`
   - Include `builder-v2-template/`, `Makefile.builder`, and the local
     Builder hook contract.
   - Explain why Guix keeps no-op compatibility hooks where Guix computes the
     system closure declaratively.

4. `Add Qubes Builder v2 and release-config review sketches`
   - Include `config/channels.scm`, `config/README.md`,
     `config/qubes-builderv2-guix.example.patch`,
     `config/qubes-os-r4.3-templates-community-guix.example.yml`, and
     `config/qubes-release-configs-guix.example.patch`.
   - Keep maintainer placeholders explicit and do not present the sketches as
     accepted upstream changes.

5. `Add local and nested-Qubes validation harnesses`
   - Include artifact-backed tests, lifecycle scripts, update-proxy checks,
     memory-balloon checks, and openQA assets.
   - Keep source-text and patch-shape checks out of the default test gate.

6. `Document review scope, adaptations, security, and maintenance`
   - Include `REVIEWER_GUIDE.md`, `REVIEW_NOTES.md`,
     `ADAPTATION_INVENTORY.md`, `SECURITY.md`, `TEMPLATE_PRECEDENTS.md`,
     `MAINTENANCE.md`, and `CONTRIBUTING.md`.
   - Keep non-goals and external blockers explicit.

7. `Record validation evidence and submission handoff`
   - Include `VALIDATION.md`, `SUBMISSION_AUDIT.md`, and
     `SUBMISSION_DRAFTS.md`.
   - Record only fresh evidence from the public branch, and keep failed or
     incomplete gates visible.

## Current Local History Map

The current `master` history through the implementation and evidence commits is
already scoped into review-oriented commits, but it has not been signed or
published by a maintainer.  This documentation section is intentionally not
listed in its own table.  If the branch is rewritten before submission, preserve
the same separation of concerns:

| Commit | Purpose |
| --- | --- |
| `912d9bc` | Introduce the native Guix TemplateVM scaffold, package definitions, service mapping, image tooling, RPM packager, Builder-shaped hooks, and initial documentation. |
| `197425e` through `a32c69b` | Replace prose-only confidence with artifact-backed validation, rootfs/RPM checks, Builder/release-config sketch evidence, and the prompt-to-artifact audit. |
| `eecd56f`, `4d62762`, `05ed2bf`, `7206de0` | Add and document the opt-in real Guix updates-proxy download gate, including the negative nested-openQA result where dom0 refused `qubes.UpdatesProxy`. |
| `d5b003f`, `853980f`, `e9b0ec4`, `71e77e0`, `f69fc2d`, `e7c40aa`, `616a0c5`, `96b87b8` | Tighten review notes around package-test policy, GUI scope, Builder environment reproducibility, remaining service adaptations, and artifact-based test policy. |
| `e072163`, `c2f2609` | Add the controlled `sys-net` stub proxy download gate and fix the harness by shutting down the source template before cloning the stub target. |
| `7c2668b` | Record the controlled proxy evidence and document that local tests must exercise artifacts and Qubes-visible contracts. |
| `de41010`, `e22d6a8` | Document the community-template maintainer trust path, handoff/removal policy, complete release-evidence checklist, and remaining maintainer identity blocker. |
| `b0c426a` | Tighten submission drafts so copied upstream text keeps proxy, memory-balloon, maintainer handoff, and final-release gates explicit. |
| `7829b5a` | Clarify the non-obvious no-op bootloader closure behavior and the normal/minimal appmenu package split. |
| `fee9ade` | Add this local history map so reviewers can see the current commit grouping before any public rewrite. |
| `1bc7aab`, `a66b2d5`, `51c0d69`, `411e482` | Refresh pin freshness, completion-audit, local contract-check, and upstream sketch evidence against the current review tree. |
| `ba1010d`, `3899a26` | Remove stale test names and review wording so local checks are presented as Builder hook, Builder RPM, and template RPM contracts rather than source-only checks. |
| `221a2cf`, `011e18f`, `d4055e2`, `119ccf7`, `090fe88` | Anchor current template precedent sources, refresh forum precedent around Builder v2 and template-service scope, tighten the adaptation inventory against the actual Scheme/build implementation, and normalize upstream-facing hook terminology. |
| `d017cab`, `aa3d497`, `13b7c85`, `d3c6c67`, `f4cfeb6`, `e21a5ec`, `30acbd4`, `f21deb1`, `ffbe2e0`, `8f9cf69` | Rework review hygiene around placeholders, remove source-shape test gates, record the artifact-backed test inventory, refresh non-obvious-change and placeholder-hygiene audit coverage, ignore current test work directories, document generated-artifact hygiene, and tone down validation proof language. |

The public submission branch may squash or reorder these, but it should not lose
the traceability between implementation, validation evidence, upstream process
mapping, and remaining blockers.
