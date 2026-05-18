# Patch Series

This branch is intentionally kept short for human review.  The local
`upstream-review` branch has one signed commit on top of `master`.  The commit
contains the template implementation, the review notes, and the multi-repo
patch sketches needed to evaluate the RFC without following a local validation
environment.

## Template Repository

1. `Add native Guix Qubes template review harness`

   Adds the functional TemplateVM work and review surface:

   - Guix package and Shepherd service definitions for the Qubes VM-side stack.
   - Native rootfs, qvm-template RPM, and Builder adapter scripts.
   - openQA scheduling and dom0 smoke-test helpers.
   - Contract tests for script CLIs, rootfs policy, Builder hooks, RPM layout,
     and the centralized vmupdate harness.
   - Adaptation inventory and reviewer guide.
   - Maintenance, security, contribution, and upstreaming notes.
   - Validation and submission audit records.
   - Example Builder v2, core-admin-linux, and release-config patch sketches.

   Review focus:

   - Clearly separate proven local evidence from remaining release gates.
   - Keep maintainer ownership and release metadata as placeholders.
   - Avoid embedding local paths, cloud instance details, tokens, or generated
     build outputs.

## Split Component Repositories

The Qubes project spans multiple repositories, so the review work is also split
where upstream ownership naturally lands:

- `QubesOS/qubes-builderv2#245`: one signed commit adding `dist: guix`
  recognition and tests for Guix template metadata.
- `QubesOS/qubes-core-admin-linux#211`: one signed commit adding the Guix
  vmupdate backend and focused tests for system-only Guix update behavior.
- `QubesOS/qubes-release-configs#19`: one signed RFC commit sketching
  placeholder community-template entries for `guix` and `guix-minimal`.
- `<owner>/qubes-builder-guix`: one signed commit containing the Builder-facing
  component mirror.  It is hosted as review/proof material, not as hardcoded
  canonical release metadata.

## Current Validation Summary

- Template repo: `make check` passed after the history cleanup.
- Template repo: `make check-qubes-pins` passed against current Qubes R4.3
  component tags.
- Split `qubes-builder-guix`: `make check` passed at signed head `d864b22`.
- `qubes-core-admin-linux`: focused Guix backend tests passed locally; upstream
  CI remains the authoritative full-suite gate.
- Centralized update proof exists for the current review artifact: RPM-mode
  openQA job 129 ran `guix time-machine --branch=master` and
  `guix system reconfigure` through a standard Debian `sys-net` update target
  with agent exit status 0.  Job 133 reran the corrected harness and reached
  Guix through the same proxy path before an upstream Git HTTP 504.  A final
  publication-object rerun is still required.

## Reviewer Commands

```sh
git log --oneline --show-signature master..upstream-review
make check
make check-qubes-pins
```

For the split component:

```sh
cd ../qubes-builder-guix
git log --oneline --show-signature -1
make check
```
