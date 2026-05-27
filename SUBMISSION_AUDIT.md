# Submission Audit

This is the human-review checklist for deciding whether the repository is ready
to ask Qubes maintainers for upstream review.  It is intentionally stricter than
`make check`: local executable checks are evidence, not proof that the upstream
process is complete.

## Objective Mapping

| Requirement | Evidence | Status |
| --- | --- | --- |
| Human-reviewable patch set | `git log --oneline`, `REVIEWER_GUIDE.md`, `PATCH_SERIES.md`, `REVIEW_NOTES.md`, this file | Mostly present; the review branch is one signed commit over `master`, the public branch is updated, and release-owner signing is deferred to publication |
| Qubes contribution expectations | `UPSTREAMING.md`, `REVIEW_NOTES.md`, `COPYING` | Mapped to source-backed expectations |
| Online PR/issue/forum review | `UPSTREAMING.md`, `REVIEW_NOTES.md` | Targeted to authoritative docs, current Builder/release-config code, current R4.3 Builder v2 forum guidance, new-template forum precedent, unofficial-package/template repository precedent, Gentoo template precedent, comparable NixOS issue/PRs, the Alpine `vmupdate` PR, the Flatpak update-proxy PR, and update-proxy issue threads covering UpdateVM support, target service state, global update-proxy defaults, target startup, and user-visible UpdateVM settings; spot-refreshed against those comparable issue/PR paths, the Builder environment issue, the new packages/templates forum thread, and the three open Guix RFC PR threads on May 18, 2026; exhaustive review of every Qubes PR/issue is not claimed |
| Clear use case | `README.md`, `UPSTREAMING.md` | Present: native Guix System TemplateVM for Qubes R4.3 |
| Open-source license | `COPYING`, SPDX markers in code files, `scripts/package-native-template-rpm.sh` | Present: GPLv3-or-later repository metadata |
| Low review burden | `REVIEWER_GUIDE.md`, `REVIEW_NOTES.md` review order, review matrix, non-goals | Present, with remaining gates called out |
| Security-review framing | `SECURITY.md`, `ADAPTATION_INVENTORY.md`, `REVIEW_NOTES.md` | Guest trust boundaries and review-sensitive adaptations are documented; nested-dom0 smoke, dynamic memory-pressure evidence, default update-target proxy evidence, RPM-mode openQA evidence, runtime evidence of generated Guix proxy configuration, and controlled Guix client proxy-download evidence exist; real Internet update-target Guix proxy use and final publication reruns remain |
| GenAI-assisted contribution handling | `UPSTREAMING.md`, `REVIEW_NOTES.md` | Present as a disclosure requirement; release ownership must be settled before publication |
| GNU Guix System alignment | `UPSTREAMING.md`, `ADAPTATION_INVENTORY.md`, `config.scm` | Guix package definitions, operating-system records, Shepherd service types, pinned channels, immutable source hashes, and named phases are used; mutable state is limited to Qubes runtime compatibility needs |
| Non-obvious compatibility changes explained | `REVIEW_NOTES.md`, `ADAPTATION_INVENTORY.md` | Present |
| Maintainer/update story | `MAINTENANCE.md`, `UPSTREAMING.md` | Present as a policy artifact, including handoff/removal policy for an unmaintained community template; release-owner identity is deferred |
| Contribution workflow | `CONTRIBUTING.md`, `PATCH_SERIES.md` | Review hygiene, publication signing preflight, testing, placeholder, release evidence, and multi-repo flow rules documented |
| Submission handoff | `SUBMISSION_DRAFTS.md`, `PATCH_SERIES.md` | Drafts present; placeholders and final evidence must be replaced before use |
| Generated artifact hygiene | `.gitignore`, `git ls-files`, `git status --short` | Generated images, RPMs, tarballs, caches, dist output, and current test work directories are ignored; no generated artifacts are tracked |
| Tracked-file publication hygiene | `git grep`, `git ls-files` | A tracked-file scan on May 18, 2026 found no GitHub credential, cloud-provider setup, provider instance or zone, generated RPM/image/dist/work artifact, or host-local path.  Remaining intentional hits are the hygiene-command example in `CONTRIBUTING.md` and standard Qubes in-guest user-home diagnostic log paths. |
| Immutable Qubes source pins and hashes | `config.scm` | Present |
| Pin freshness check | `scripts/check-qubes-pins.sh`, `make check-qubes-pins`, `VALIDATION.md` | Present; passed locally again on May 19, 2026 after the centralized update proof hardening; current output includes `qubes-core-agent-linux v4.3.43` and all pinned Qubes VM component tags matched |
| Guix channel reproducibility | `config/channels.scm`, `VALIDATION.md` | Present; `guix time-machine -- describe` passed on a remote Guix builder, and the rootfs builder now fails instead of defaulting to an unpinned branch when no pinned channels file is available.  The pin is not installed as user/root channel state. |
| Template RPM format | `scripts/package-native-template-rpm.sh`, `tests/rpm-layout-check.sh` | Locally tested for normal and minimal variants |
| Executable build contracts | `tests/builder-rpm-contract-check.sh`, `tests/rpm-layout-check.sh`, `make check` | Present; local run builds template RPM artifacts through the Builder RPM adapter and native packager, validates qvm-template metadata, extracts the payload, and reassembles the split root image |
| Runtime and generated-system contracts | `scripts/test-native-rootfs-activation.sh`, `scripts/test-template-rpm-lifecycle-dom0.sh`, `openqa/`, `VALIDATION.md` | Present as recorded evidence; final publication reruns still need fresh rootfs builds, TemplateVM/AppVM smoke, qvm-template lifecycle, and openQA |
| Builder v2 content-script shape | `builder-v2-template/`, `scripts/build-native-rootfs.sh --install-dir` | Present as a reviewable component shape |
| Existing template precedent mapping | `TEMPLATE_PRECEDENTS.md`, `builder-v2-template/` | Guix hook mapping is documented against the Qubes template-builder model |
| Builder v2 multi-repo change | `config/README.md`, `config/qubes-builderv2-guix.example.patch`, QubesOS/qubes-builderv2#245 | Draft RFC PR opened; the branch is resquashed into one signed review commit at `f9ec921`, Qubes code-signing is green, the four focused Guix distribution/template-plugin tests pass locally, and upstream GitLab CI is green at the May 19 check; the change is not accepted upstream |
| Release-config multi-repo change | `config/README.md`, `config/qubes-release-configs-guix.example.patch`, QubesOS/qubes-release-configs#19 | Draft RFC PR opened; Qubes code-signing is green; release metadata remains a publication gate, not a blocker for review |
| Central updater multi-repo change | `config/README.md`, `config/qubes-core-admin-linux-guix-vmupdate.example.patch`, QubesOS/qubes-core-admin-linux#211 | Draft RFC PR opened; public head `182199c` has Qubes code-signing and GitLab CI success with `maintainer-tag` pending at the May 19 check; vmupdate tests pass in that branch, including the Guix proxy environment, shared no-progress contract, time-machine refresh/reconfigure commands, realtime streaming for those commands, sanitized manifest parsing, vmupdate-scoped temporary time-machine state, and per-output system profile metadata for the dom0 package summary; the dom0 harness raw-probes the Qubes proxy to the Guix channel host, logs `qubes.UpdatesProxy` policy and `sys-net` target context, rejects direct-route TemplateVM proof, forces both refresh and upgrade, and checks for Guix refresh/reconfigure log markers before accepting central-updater evidence; not accepted upstream; RPM-mode openQA job 129 passed the central update path through a standard Debian `sys-net` target with agent exit status 0, while job 133 reached the same path and failed on an upstream Git HTTP 504 during Guix refresh |
| Runtime validation snapshot | `VALIDATION.md` | Partial; dated normal/minimal rootfs/RPM plus nested-dom0 qvm-template lifecycle, upgrade/downgrade, TemplateVM/AppVM smoke, dynamic memory-pressure, default update-target proxy, and RPM-mode openQA evidence present, including swap activation, `meminfo-writer` startup, memory growth under pressure, `127.0.0.1:8082` forwarding through stock Qubes policy, openQA jobs 8/9, rebuilt minimal openQA job 27 with generated Guix daemon/client proxy verification, job 31 with controlled `guix download` through a temporary `sys-net` stub, job 38 with the rebuilt minimal RPM passing the same controlled download gate, job 41 repeating that controlled gate after adding the no-direct-default-route proof guard, job 44 repeating that controlled gate from commit `d508939`, and job 129 passing standard update-target bootstrap, raw proxy probing, `guix time-machine --branch=master`, system reconfigure, package metadata reporting, and agent exit status 0; final publication reruns remain open |
| openQA and qvm-template lifecycle evidence | `openqa/`, `scripts/run-openqa-template-rpm.sh`, `scripts/test-template-rpm-lifecycle-dom0.sh`, `scripts/test-guix-update-proxy-config-dom0.sh`, `scripts/test-guix-update-proxy-download-dom0.sh`, `scripts/test-guix-update-proxy-stub-download-dom0.sh`, `scripts/test-guix-central-vmupdate-dom0.sh`, `VALIDATION.md` | qvm-template install/reinstall/remove/upgrade/downgrade and smoke passed for both variants in nested dom0; RPM-mode openQA jobs 8 and 9 passed for normal and minimal 2026051602 RPMs; rebuilt minimal openQA job 27 passed generated Guix daemon/client proxy verification; openQA jobs 38, 41, and 44 passed RPM install, postinstall diagnostics, TemplateVM/AppVM smoke, generated proxy configuration, raw proxy probing, and a controlled `guix download` through stock default-target policy and a temporary `sys-net` stub; jobs 41 and 44 additionally verified the source TemplateVM had no direct default route before counting the run as proxy evidence; job 129 passed the central update path through a standard Debian `sys-net` target; job 133 reran the corrected central harness and reached Guix through the same proxy path before an upstream Git HTTP 504 |

## Prompt-To-Artifact Checklist

| Objective phrase | Concrete artifact or evidence | Coverage |
| --- | --- | --- |
| Easily reviewable by humans | `README.md`, `REVIEWER_GUIDE.md`, `REVIEW_NOTES.md`, `ADAPTATION_INVENTORY.md`, this audit | Review path, scope, non-goals, and adaptation rationale are documented |
| Conform to Qubes maintainer expectations | `UPSTREAMING.md`, `REVIEW_NOTES.md`, `COPYING`, `config/README.md` | Expected contribution process is mapped; acceptance still requires external review |
| Preserve GNU Guix System principles | `UPSTREAMING.md`, `config.scm`, `config/channels.scm` | Native implementation is declarative Guix package/service/system code with pinned channels and source hashes; mutable state is scoped to Qubes compatibility |
| Inspect maintainer expectations online | `UPSTREAMING.md`, `REVIEW_NOTES.md` | Targeted review captured and spot-refreshed against comparable NixOS, Alpine `vmupdate`, Flatpak update-proxy, UpdateVM/update-proxy setting and service-state issues, and Builder-environment issue/PR material; exhaustive review of every Qubes issue/PR remains unclaimed |
| Upstream process may span multiple repos | `config/qubes-builderv2-guix.example.patch`, `config/qubes-release-configs-guix.example.patch`, `config/qubes-core-admin-linux-guix-vmupdate.example.patch`, `config/README.md` | Builder v2, release-config, and central updater targets are separated and named |
| Clear commit history | `git log --oneline`, `PATCH_SERIES.md` | Clean review branch present; `PATCH_SERIES.md` now has a one-to-one subject map against `git log --reverse`; publication signing is deferred |
| Every non-obvious change explained | `REVIEW_NOTES.md`, `ADAPTATION_INVENTORY.md`, `MAINTENANCE.md` | Package phases, VM-side component package splits, services, update model, 20G root image sizing, installed reconfiguration inputs, generated `/sbin/init` entrypoint, dom0 root-image import helper safety boundary, openQA host setup scope, nested-dom0 system-test default-NetVM compatibility hook, no-op bootloader closure handling, normal/minimal appmenu split, the root-owned Xorg/default-user `-ac` access-control caveat, and review-sensitive choices are documented |
| Checks should exercise real contracts | `tests/builder-rpm-contract-check.sh`, `tests/rpm-layout-check.sh`, rootfs activation, qvm-template lifecycle, openQA, and `VALIDATION.md` | Default local checks build and unpack RPM artifacts instead of scanning source. Runtime evidence comes from rootfs activation, qvm-template lifecycle, openQA, and live TemplateVM/AppVM smoke. |

## Current Completion Audit

This audit treats the requested upstreamability goal as these concrete
deliverables:

- A human-reviewable source tree with a clean public history.
- A source-backed map from Qubes maintainer expectations to local artifacts.
- Clear separation of local implementation, Builder v2 changes, and
  release-config changes.
- Rationale for every non-obvious Guix/Qubes compatibility decision.
- Executable checks that exercise build or packaging behavior and externally
  visible metadata.
- An explicit list of remaining gates that cannot honestly be claimed yet.

Inspected evidence in the current tree:

| Check | Evidence |
| --- | --- |
| Clean review branch history | `git log --oneline --decorate --max-count=5` shows one scoped local review commit on `upstream-review`; `PATCH_SERIES.md` maps that commit to review purpose. |
| Signing/release ownership state | `CONTRIBUTING.md` now separates RFC review from publication signing.  The template branch is signed with the one-shot contribution key, the release-config RFC head was amended to remove maintainer metadata from the review sketch, and the latest checked Qubes code-signing status was green on the three RFC PR heads.  Release ownership, maintainer review, and publication approval remain unresolved gates. |
| Default checks exercise build contracts | `make check` runs `tests/builder-rpm-contract-check.sh` and `tests/rpm-layout-check.sh`. |
| Check inventory is contract-backed | The default local suite is limited to RPM artifact generation, metadata validation, payload extraction, and root-image reassembly. Runtime confidence still comes from rootfs activation, qvm-template lifecycle, openQA, and live TemplateVM/AppVM smoke. |
| Working tree clean | The review branches contain only tracked review commits; local untracked artifacts such as `czf` and `.coverage` are intentionally left untracked and are not part of the review branches. |
| Generated artifacts stay out of review | `.gitignore` covers root images, RPMs, tarballs, cache/dist output, and current test work directories; `git ls-files` does not list generated RPM/image artifacts. |
| License/SPDX hygiene | `COPYING` is tracked; code and build entry points under `Makefile*`, `scripts/`, `tests/`, `builder-v2-template/`, `config.scm`, and `config/*.scm` carry SPDX headers, excluding data-only appmenu allowlists and `template.conf`. |
| Placeholder hygiene | `rg '<[A-Z][A-Z0-9_]*>'` finds placeholders only in draft/config/review-process files: `config/`, `SUBMISSION_DRAFTS.md`, `MAINTENANCE.md`, `UPSTREAMING.md`, and `CONTRIBUTING.md`. |
| Qubes source pins are fresh | Current local `./scripts/check-qubes-pins.sh` run passed for all pinned Qubes VM components on May 19, 2026. |
| Prompt-to-artifact checklist exists | This file maps objective phrases to artifacts and marks incomplete external gates. |
| Online expectations are traceable | `UPSTREAMING.md` contains an online source crosswalk for Qubes docs, Builder v2, release-configs, forum precedent, and comparable NixOS issue/PRs. |
| Non-obvious changes are explained | `REVIEW_NOTES.md`, `ADAPTATION_INVENTORY.md`, and `MAINTENANCE.md` explain package phases, VM-side component package splits, omitted Guix base services, Shepherd services, FHS compatibility paths, update model, 20G root image sizing, installed reconfiguration inputs, generated `/sbin/init` entrypoint, dom0 root-image import helper safety boundary, openQA host setup scope, nested-dom0 system-test default-NetVM compatibility hook, Template Manager RPM payload shape, swap, guest-side memory ballooning plumbing, no-op bootloader closure handling, normal/minimal appmenu differences, root-owned Xorg/default-user `-ac` access-control compatibility, maintainer handoff, and review-sensitive source edits. |
| Security-sensitive scope is explicit | `SECURITY.md` separates dom0 trust boundaries, guest privileged behavior, source integrity, and unproven runtime gates. |
| Template-builder precedent is explicit | `TEMPLATE_PRECEDENTS.md` maps Guix hooks to the standard Qubes template hook responsibilities and release-config model. |
| Guix System alignment is explicit | `UPSTREAMING.md` explains how the implementation stays in Guix package definitions, operating-system records, Shepherd services, pinned channels, immutable source hashes, and named phases while limiting mutable runtime state to Qubes compatibility requirements. |
| Contributor workflow is explicit | `CONTRIBUTING.md` lists required checks, release evidence, review rules, and multi-repo ordering. |
| Auxiliary helpers are mapped | `REVIEW_NOTES.md` names the openQA loader glue, dom0 postinstall diagnostic helper, and foreign-template installer as support tools outside the native release artifact. |
| Local checks cover real artifacts | `make check` passed locally on May 26, 2026 after the KISS cleanup removed fake Qubes command harnesses, parser-only openQA stubs, source-shape guards, mocked Builder adapter checks, source-extracted repo-query helper checks, and generated-system string checks. The current local suite runs `tests/builder-rpm-contract-check.sh` and `tests/rpm-layout-check.sh`, which build normal/minimal RPM artifacts, validate qvm-template metadata, extract the payload, and reassemble the root image. |
| Runtime contracts require runtime gates | Rootfs activation, qvm-template lifecycle, openQA, and live TemplateVM/AppVM smoke are the gates that prove the generated system behavior. |
| Builder v2 sketch has focused tests | A clean recheck clone with the checked-in `config/qubes-builderv2-guix.example.patch` applied passed the four Guix distribution/template-plugin tests: `4 passed`.  The checked-in neutral-header example patch also passed `git diff --check HEAD`. |
| Release-config sketch parses after apply | A clean recheck clone with the checked-in `config/qubes-release-configs-guix.example.patch` applied parsed the resulting R4.3 community template YAML and confirmed `builder-guix`, `guix`, and `guix-minimal`.  The checked-in neutral-header example patch also passed `git diff --check HEAD`. |
| Central updater sketch has focused tests | The active `qubes-core-admin-linux` PR branch passed `./run-tests.sh` with `PYTHONPATH` pointing at a matching `qubes-core-admin-client` checkout: `52 passed, 1 warning`, including the Guix vmupdate backend tests, proxy-environment coverage, time-machine refresh/reconfigure commands, realtime streaming for those commands, Guix manifest-column preservation before Qubes output sanitization, vmupdate-scoped temporary time-machine state, per-output system profile package metadata, dom0-visible package summary output, shared `PROGRESS_REPORTING` contract, and parser fallback edge cases added after Codecov flagged missing patch coverage. |
| Submission drafts exist | `SUBMISSION_DRAFTS.md` provides editable `qubes-devel`, `[Contribution]`, Builder v2 PR, and release-config PR drafts with placeholder, maintainer handoff, controlled-vs-real proxy, and validation warnings. |
| Multi-repo PR staging is separated | Temporary clean recheck clones outside this repository applied the checked-in Builder v2, release-configs, and core-admin-linux patch sketches on May 18, 2026 against upstream heads `8059f1d`, `e7ad66d`, and `32a14bb`; all three patches still apply, and RFC PRs are open as QubesOS/qubes-builderv2#245, QubesOS/qubes-core-admin-linux#211, and QubesOS/qubes-release-configs#19.  Those temporary paths are not material to commit into this repository. |
| Provider-specific test setup is excluded | A May 17, 2026 scan of the PR staging folders found no provider instance, zone, or local provider setup strings in the contribution material; matches were limited to generic nested-dom0 helper defaults and upstream project data such as mailing-list addresses and test keys. |
| Tracked repository hygiene is explicit | A May 18, 2026 tracked-file scan found no GitHub credential, cloud-provider setup, provider instance or zone, generated RPM/image/dist/work artifact, or host-local path.  The only remaining matches were the intentional example hygiene command in `CONTRIBUTING.md` and standard Qubes in-guest user-home log paths used by the dom0 smoke diagnostics. |
| Live PR text hygiene is explicit | GitHub API scans on May 17-18, 2026 | The bodies and issue comments for QubesOS/qubes-builderv2#245, QubesOS/qubes-core-admin-linux#211, and QubesOS/qubes-release-configs#19 had no `/home/`, `/tmp/`, cloud-provider, instance/zone, GitHub PAT, or token-pattern hits after replacing local validation commands with generic checkout-relative forms.  On May 18, the core-admin Linux PR text and commit message were refreshed to the then-current system-only semantics and test summary; the Builder v2 and release-config comments were edited in place to describe current signed single-commit heads without tag claims. |
| Current remote central update evidence | OpenQA job 129 passed RPM import, TemplateVM/AppVM smoke, generated Guix proxy configuration, standard Debian `sys-net` update-target bootstrap, raw `qubes.UpdatesProxy` probing, `guix time-machine --branch=master`, `/etc/config.scm` reconfigure, package metadata reporting, and agent exit status 0.  Job 133 reran the corrected central log harness with a longer openQA limit and reached Guix through the same Qubes update-proxy path, then failed on an upstream Git HTTP 504 during refresh.  This proves the current review artifact's central path, but final publication-branch or release-tag reruns remain required and public network availability remains an external release variable. |
| Live upstream PR policy state | GitHub issue/PR API and CI status checks on May 19, 2026 | QubesOS/qubes-builderv2#245, QubesOS/qubes-core-admin-linux#211, and QubesOS/qubes-release-configs#19 are open draft RFC PRs with no submitted reviews.  Builder v2 public head `f9ec921` passes Qubes code-signing and GitLab CI, core-admin Linux public head `182199c` passes Qubes code-signing and GitLab CI with `maintainer-tag` pending, and release-config public head `fb356bd` passes Qubes code-signing.  The only maintainer comment present asked for a template build log on the Builder v2 RFC; a fresh `guix-minimal` build log from template source head `2f209a4403652937678c1fd76bc9b71919e05236` was posted in response.  Later template-branch amendments changed Qubes pins, no-shrink RPM packaging, and central-update openQA harness behavior, so that build log is retained as prior evidence rather than current-head release evidence.  The release-config PR body and current head omit maintainer fingerprint metadata from the RFC sketch. |
| External PR commit signatures verify locally | `git verify-commit` on the Builder v2, core-admin-linux, and release-config PR branch commits | Every commit on the three external RFC PR branches verified locally with the one-shot contribution key at the latest check.  This is signature evidence only; it does not replace maintainer ownership or publication signing. |

This still does not prove Qubes acceptance or runtime release quality.  The
status remains "reviewable prototype" until the blockers in "Do Not Claim Yet"
are removed.

## Latest Evidence

Verification evidence includes the local artifact suite, runtime/openQA
records, and the targeted Builder/release-config sketch checks.  The
pinned-channel rootfs-builder policy still needs current runtime-build evidence
after the checkout-backed refresh simplification:

```sh
make check
make check-qubes-pins
PYTHONPATH=<qubes-builderv2 checkout> python -m pytest <qubes-builderv2 checkout>/tests/test_objects.py::test_dist_non_default_arch <qubes-builderv2 checkout>/tests/test_objects.py::test_dist_family <qubes-builderv2 checkout>/tests/test_objects.py::test_template_plugin_supports_guix <qubes-builderv2 checkout>/tests/test_objects.py::test_template_plugin_guix_parameters
# release-config YAML validation in a clean qubes-release-configs checkout; see VALIDATION.md
PYTHONPATH=../qubes-core-admin-client:. ./run-tests.sh
# in the active PR branch; 52 passed, 1 warning
```

Most recent review-state refresh on May 19, 2026:

- The template review branch is kept as one signed local commit on
  `upstream-review`; stale template `signed_tag_for_*` refs were removed.
- `make check`, `make check-qubes-pins`, and `git diff --check` passed after
  the centralized update harness, no-shrink RPM packaging, openQA timeout, and
  Qubes VM component pin refresh.
- The core-admin review branch is one signed commit at
  `182199ca9e91535c5386f13a26ea8b6cf0e57610`; its checked-in example patch was
  regenerated from that branch after the system-only update amend and the public
  PR head now matches.
- The core-admin review branch passed
  `PYTHONPATH=<qubes-core-admin-client checkout>:. ./run-tests.sh vmupdate/tests/test_agent_guix.py`
  with
  `52 passed, 1 warning`.
- QubesOS/qubes-builderv2#245, QubesOS/qubes-core-admin-linux#211, and
  QubesOS/qubes-release-configs#19 are open draft RFC PRs with no submitted
  reviews at the May 19 check.  Builder v2 public head `f9ec921` passes Qubes
  code-signing and GitLab CI; core-admin Linux public head `182199c` passes
  Qubes code-signing and GitLab CI with the expected `maintainer-tag` policy
  status pending; release-config public head `fb356bd` passes Qubes
  code-signing.
- Public PR comments were edited in place to describe current signed
  single-commit heads without stale tag claims.  The Builder v2 build-log
  comment records the exact build source head; later template branch amends
  changed Qubes pins, no-shrink RPM packaging, and central-update openQA harness
  behavior, so the build log is prior evidence rather than current-head release
  evidence.
- A public-text scan across the three RFC PR comments found no PAT,
  token-pattern, local-home path, cloud-specific setup, instance, or zone hits
  in author-controlled comments.  The only personal-repository URL hit is a
  maintainer comment pointing readers to the current review repository.
- A tracked-file scan of the template branch found no GitHub credential,
  cloud-provider setup, provider instance or zone, generated RPM/image/dist/work
  artifact, or host-local path.  The intentional remaining hit is the hygiene
  command example in `CONTRIBUTING.md`.
- The split `qubes-builder-guix` review component remains one signed commit at
  `d864b22` and previously passed `make check`.
- A clean remote clone at review head `d106c27` passed the then-current
  artifact checks. Later cleanup removed the Guix-only system-record/string
  checker from the repository test surface; generated-system behavior should be
  validated through rootfs activation, qvm-template lifecycle, openQA, and live
  VM smoke.

These current-head checks are local review evidence only.  They do not replace
nested-dom0/openQA runtime evidence or the still-missing publication reruns.

No source-only checker is present or counted here as validation evidence.
Static source-shape and patch-shape scripts are intentionally excluded from the
repository test suite, `make` targets, validation logs, and upstream patch
series.  Formatting, parser-only, inventory, and pin-freshness commands are
manual maintainer chores or provenance checks; they are not substitutes for
 artifact, rootfs activation, dom0, or openQA evidence and should not be
submitted as upstream tests.

The review source tree was also copied to the remote Guix builder as
`~/guix-review-current`.  There, `./scripts/check-qubes-pins.sh` passed against
the live Qubes GitHub tags, and the pinned Guix channel resolved with
`guix time-machine -C config/channels.scm -- describe`.

An earlier synced review tree also loaded both `normal` and `minimal`
operating-system variants with real Guix on the remote Guix builder and printed the
expected `qubes-vm-core` package version, `4.3.42`.  That was the then-pinned
component version; the current pin is `4.3.43`. A later rebuilt-image boot
test in RPM-mode openQA job 27 also
verified the generated Guix client wrapper, updates-proxy forwarder, and
`guix-daemon` service state for `guix-minimal`.  Later job 129 proved the
central `guix time-machine` and system reconfigure path through the Qubes proxy
for the current review artifact.

The same remote source tree also produced a fresh `guix-minimal` 20G root image,
passed image inspection and activation, and built:

```text
/tmp/guix-review-release-minimal-202605152142/rpmbuild/RPMS/noarch/qubes-template-guix-minimal-4.3.0-202605152142.noarch.rpm
```

with SHA256:

```text
398a265293eb8a5eb893da83d0b3ebbf10b7c60574aeac695a7b3dff700d8629
```

It also produced a fresh `guix` 20G root image, passed image inspection and
activation, and built:

```text
/tmp/guix-review-release-normal-202605152143/rpmbuild/RPMS/noarch/qubes-template-guix-4.3.0-202605152143.noarch.rpm
```

with SHA256:

```text
942a7d892f28cb565f5acfdb7df50282ada0c9ded2abef91219d41038ec01955
```

The nested dom0 then mounted `/tmp/qubes-guix-dom0-data.img` read-only and
ran the patched lifecycle harness against both RPMs.  `guix-minimal` passed
install, Template Manager metadata checks, TemplateVM/AppVM smoke, reinstall,
repeated smoke, and final remove with:

```sh
/tmp/t -r /tmp/m.rpm -e guix-minimal -R -s
```

`guix` passed the same lifecycle with:

```sh
/tmp/t -r /tmp/g.rpm -e guix -R -s
```

The smoke harness covered TemplateVM boot/qrexec, AppVM qrexec, QubesDB
identity values, `/rw`, `/home`, `/usr/local`, `/dev/xvdb`, command and
desktop-file availability, `qubes.WaitForSession`, shutdown, and AppVM home
persistence across restart.

A follow-up nested-dom0 run used `/tmp/qubes-guix-dom0-upgrade-data.img` with
distinct-EVR RPMs and passed upgrade plus downgrade for both variants:

```text
6081f6630294c90420e1d7767775287f41102930e0870f3a8662062d2e8851b5  qubes-template-guix-minimal-4.3.0-202605152141.noarch.rpm
b17780fa49ff065a7c06f80d1742b2e59e8165ef91cc49c5bc9a5e0758a46e5c  qubes-template-guix-minimal-4.3.0-202605152143.noarch.rpm
24cff6b506a72002a161ecee6e396d7e1d05974095f5c9099d48a41ad1d03fe2  qubes-template-guix-4.3.0-202605152142.noarch.rpm
3bbeddc1b7348fc4b66987a1cf7bb0aaf4ab3fbad8574171e27ac5d48acd244c  qubes-template-guix-4.3.0-202605152144.noarch.rpm
```

The minimal run used:

```sh
/tmp/t -r /m/rpms/base-minimal.rpm \
  -u /m/rpms/upgrade-minimal.rpm \
  -d /m/rpms/downgrade-minimal.rpm \
  -e guix-minimal -R -s
```

The normal run used `.rpm` symlinks to the same read-only data-disk RPMs:

```sh
/tmp/t -r /tmp/b.rpm -u /tmp/u.rpm -d /tmp/d.rpm -e guix -R -s
```

Both ended with `qvm-template lifecycle check passed for ...` after install,
smoke, reinstall, repeated smoke, upgrade, downgrade, and final remove.

RPM-mode openQA also passed for the 2026051602 RPMs on the openQA host:

```text
job 8:  BUILD=guix-normal-rpm-2026051602-inline-marker   TEST=guix_template   result=passed
job 9:  BUILD=guix-minimal-rpm-2026051602-inline-marker  TEST=guix_template   result=passed
```

Those jobs exercised the RPM asset path, `qvm-template --yes install
--nogpgcheck`, postinstall failure checks, and the dom0 TemplateVM/AppVM smoke
harness.  They are review evidence for this prototype, not a replacement for
final reruns from the publication branch or release object.

After the Guix update-proxy service change, RPM-mode openQA job 27 passed for a
rebuilt `guix-minimal` RPM:

```text
job 27: BUILD=guix-minimal-rpm-r202605162304-proxyfix-202605162312 TEST=guix_template result=passed
```

That job covered `qvm-template` install, postinstall diagnostics, log scanning,
TemplateVM/AppVM smoke, standard `/dev/xvdc1` swap, guest-side
`meminfo-writer`, qrexec, `qubes.WaitForSession`, the generated Guix
updates-proxy forwarder, and `guix-daemon` service-state checks.  It is still
review evidence from the current remote/openQA tree, not final publication
evidence.

OpenQA job 29 then enabled `GUIX_RUN_PROXY_DOWNLOAD_TEST=1` for the same
rebuilt minimal RPM.  It passed the earlier install, postinstall, smoke, and
Guix proxy-configuration steps, then failed the opt-in real-download step with
`Request refused` from `qrexec-client-vm` and a `socat` child exit status 126.
That is negative evidence: the public-network download verifier is wired and
strict, but the current nested openQA environment did not provide an
allowed/default `qubes.UpdatesProxy` target for a real Internet Guix download.

OpenQA job 31 enabled `GUIX_RUN_PROXY_STUB_DOWNLOAD_TEST=1` for the same
rebuilt minimal RPM.  It passed the earlier install, postinstall, smoke, and
Guix proxy-configuration steps, then created a temporary `sys-net` stub target
and passed a controlled `guix download` through the generated Guix wrapper and
stock Qubes default-target updates-proxy policy:

```text
job 31: BUILD=guix-minimal-rpm-r202605162304-stubdownload-fix-202605170229 TEST=guix_template result=passed
```

The archived serial log showed `downloaded 2 bytes`, `guix update proxy
download check passed`, `guix update proxy stub download check passed:
guix-minimal -> sys-net`, and `OPENQA_RC_000012_0`.  This is deterministic
proxy-path evidence; it is not evidence of public Internet substitute downloads
or `guix time-machine`.

OpenQA job 38 repeated the controlled stub-download path with the then-current
rebuilt `guix-minimal` RPM after the openQA console-readiness fixes:

```text
job 38: BUILD=guix-minimal-rpm-r202605171259-updatepath-stub-consolefix2-202605171431 TEST=guix_template result=passed
```

Its serial log showed RPM install, postinstall diagnostics, TemplateVM/AppVM
smoke, generated Guix proxy configuration, raw proxy probing, and controlled
`guix download` markers.  The meaningful update-path markers were
`raw proxy probe passed: HTTP/1.1 200 OK`, `downloaded 2 bytes`,
`guix update proxy download check passed`, and
`guix update proxy stub download check passed: guix-minimal -> sys-net`.

OpenQA job 41 repeated that controlled path after the verifier started
rejecting source TemplateVMs with direct IPv4 or IPv6 default routes:

```text
job 41: BUILD=guix-minimal-rpm-r202605171259-stub-nodirect-e7566e7-202605171704 TEST=guix_template result=passed
```

Its update-path markers included `checking source TemplateVM has no direct
default route`, `raw proxy probe passed: HTTP/1.1 200 OK`, `downloaded 2
bytes`, `guix update proxy download check passed`, and
`guix update proxy stub download check passed: guix-minimal -> sys-net`.  This
is controlled update-target proof for the rebuilt minimal artifact, later
repeated by job 44.  It still does not prove public Internet downloads,
substitutes, `guix time-machine --branch=master`, or refresh-enabled central
`qubes-vm-update`.

OpenQA job 44 repeated the controlled path from then-current commit `d508939`
after the runtime path setup cleanup:

```text
job 44: BUILD=guix-minimal-rpm-current-d508939stub-24g TEST=guix_template result=passed
```

Its update-path markers included `checking source TemplateVM has no direct
default route`, `raw proxy probe passed: HTTP/1.1 200 OK`, `downloaded 2
bytes`, `guix update proxy download check passed`, and
`guix update proxy stub download check passed: guix-minimal -> sys-net`.
That RPM SHA256 was
`7e092e73681286e4111779282657e7fe6b0d370c1e66b5ea7561cb8d04afc52a`, and a
targeted archived-log scan found no `ln: failed` markers from runtime path
setup.

OpenQA job 40 then reran the rebuilt minimal RPM with
`GUIX_RUN_PROXY_DOWNLOAD_TEST=1` and a lower openQA RAM setting so the current
worker could start QEMU:

```text
job 40: BUILD=guix-minimal-rpm-r202605171259-realproxy-24g-202605171610 TEST=guix_template result=failed
```

It passed RPM install, postinstall diagnostics, log scanning, TemplateVM/AppVM
smoke, and generated Guix proxy configuration.  The failing marker was
`OPENQA_RC_000012_1`; the download script reported `raw proxy probe did not
return HTTP success`, `Request refused`, and that dom0 refused
`qubes.UpdatesProxy`.  This reconfirms that the real-network verifier is wired
into openQA and reaches the Qubes proxy boundary, but the current nested remote
still does not provide a valid Internet-capable updates-proxy target.

## Do Not Claim Yet

Do not claim that:

- Publication-owner signing metadata or a signed release branch/tag exists.
  The current public review branch intentionally does not satisfy that
  publication gate.
- Qubes Builder v2 accepts `dist: guix`.
- `qubes-release-configs` accepts the Guix community-template entries.
- The opened upstream PRs are reviewed or accepted.  They are draft RFCs with
  no maintainer reviews yet, and core-admin Linux still has the maintainer-tag
  policy status pending at the latest checked policy snapshot.
- Exhaustive review of every Qubes pull request or issue has been performed.
  The current online review is intentionally targeted to sources most relevant
  to template contribution expectations.
- Final publication-branch or release-tag evidence has been rerun, including
  RPM-mode openQA.
- End-to-end Guix update tooling is release-green from a publication branch or
  tag.  Job 129 proves the current review artifact can run the central Guix
  update path through a standard Qubes update target, and job 133 proves the
  corrected harness reaches the same path and reports external Git HTTP
  failures distinctly.  A publication-object rerun is still required, and the
  standalone public-network `guix download` gate remains separate release
  evidence.
- Qubes maintainers have reviewed or accepted the template.

Until those items are complete, the correct upstream status is: reviewable
prototype with local, remote build, and nested-dom0 lifecycle evidence, not
publishable community template.
