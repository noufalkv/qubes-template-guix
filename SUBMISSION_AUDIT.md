# Submission Audit

This is the human-review checklist for deciding whether the repository is ready
to ask Qubes maintainers for upstream review.  It is intentionally stricter than
`make check`: local tests are evidence, not proof that the upstream process is
complete.

## Objective Mapping

| Requirement | Evidence | Status |
| --- | --- | --- |
| Human-reviewable patch set | `git log --oneline`, `REVIEWER_GUIDE.md`, `PATCH_SERIES.md`, `REVIEW_NOTES.md`, this file | Mostly present; signed public history still missing |
| Qubes contribution expectations | `UPSTREAMING.md`, `REVIEW_NOTES.md`, `COPYING` | Mapped to source-backed expectations |
| Online PR/issue/forum review | `UPSTREAMING.md`, `REVIEW_NOTES.md` | Targeted to authoritative docs, current Builder/release-config code, current R4.3 Builder v2 forum guidance, new-template forum precedent, Gentoo template precedent, and comparable NixOS issue/PRs; exhaustive review of every Qubes PR/issue is not claimed |
| Clear use case | `README.md`, `UPSTREAMING.md` | Present: native Guix System TemplateVM for Qubes R4.3 |
| Open-source license | `COPYING`, SPDX markers in code files, `scripts/package-native-template-rpm.sh` | Present: GPLv3-or-later repository metadata |
| Low review burden | `REVIEWER_GUIDE.md`, `REVIEW_NOTES.md` review order, review matrix, non-goals | Present, with remaining gates called out |
| Security-review framing | `SECURITY.md`, `ADAPTATION_INVENTORY.md`, `REVIEW_NOTES.md` | Guest trust boundaries and review-sensitive adaptations are documented; nested-dom0 smoke, dynamic memory-pressure evidence, default update-target proxy evidence, RPM-mode openQA evidence, and runtime proof of generated Guix proxy configuration exist; real Guix update-tooling proxy use and final signed-branch reruns remain |
| GenAI-assisted contribution handling | `UPSTREAMING.md`, `REVIEW_NOTES.md` | Present as a disclosure requirement; human maintainer must own submission |
| Non-obvious compatibility changes explained | `REVIEW_NOTES.md`, `ADAPTATION_INVENTORY.md` | Present |
| Maintainer/update story | `MAINTENANCE.md`, `UPSTREAMING.md` | Present as a policy artifact; actual maintainer identity still missing |
| Contribution workflow | `CONTRIBUTING.md`, `PATCH_SERIES.md` | Signed-history, testing, placeholder, release evidence, and multi-repo flow rules documented |
| Submission handoff | `SUBMISSION_DRAFTS.md`, `PATCH_SERIES.md` | Drafts present; placeholders and final evidence must be replaced before use |
| Immutable Qubes source pins and hashes | `native/modules/qubes/packages/qubes-vm.scm` | Present |
| Pin freshness check | `scripts/check-qubes-pins.sh`, `make check-qubes-pins` | Present; passed on GCP against live tags |
| Guix channel reproducibility | `config/channels.scm`, installed `/etc/guix/channels.scm`, `VALIDATION.md` | Present; `guix time-machine -- describe` passed on GCP |
| Template RPM format | `scripts/package-native-template-rpm.sh`, `tests/rpm-layout-check.sh` | Locally tested for normal and minimal variants |
| Executable build contracts | `tests/builder-content-check.sh`, `tests/builder-rpm-contract-check.sh`, `tests/rpm-layout-check.sh`, `make check` | Present; local run passes and exercises generated install content, Builder adapter RPM output, and real template RPM layout |
| Builder v2 content-script shape | `builder-v2-template/`, `scripts/build-native-rootfs.sh --install-dir` | Present as a reviewable component shape |
| Existing template precedent mapping | `TEMPLATE_PRECEDENTS.md`, `builder-v2-template/` | Guix hook mapping is documented against the Qubes template-builder model |
| Builder v2 multi-repo change | `config/README.md`, `config/qubes-builderv2-guix.example.patch` | Patch sketch only; not accepted upstream |
| Release-config multi-repo change | `config/README.md`, `config/qubes-release-configs-guix.example.patch` | Patch sketch only; maintainer identity placeholders remain |
| Runtime validation snapshot | `VALIDATION.md` | Partial; current normal/minimal rootfs/RPM plus nested-dom0 qvm-template lifecycle, upgrade/downgrade, TemplateVM/AppVM smoke, dynamic memory-pressure, default update-target proxy, and RPM-mode openQA evidence present, including swap activation, `meminfo-writer` startup, memory growth under pressure, `127.0.0.1:8082` forwarding through stock Qubes policy, openQA jobs 8/9, and rebuilt minimal openQA job 27 with generated Guix daemon/client proxy verification; openQA job 29 reached the opt-in real-download gate but failed on dom0 `qubes.UpdatesProxy` refusal, so real Guix update-tooling proxy use and final signed-branch reruns remain open |
| openQA and qvm-template lifecycle evidence | `openqa/`, `scripts/run-openqa-template-rpm.sh`, `scripts/test-template-rpm-lifecycle-dom0.sh`, `scripts/test-guix-update-proxy-config-dom0.sh`, `scripts/test-guix-update-proxy-download-dom0.sh`, `VALIDATION.md` | qvm-template install/reinstall/remove/upgrade/downgrade and smoke passed for both variants in nested dom0; RPM-mode openQA jobs 8 and 9 passed for normal and minimal 2026051602 RPMs; rebuilt minimal RPM-mode openQA job 27 passed generated Guix daemon/client proxy verification; openQA job 29 proved the real-download gate is wired and strict, but it failed on dom0 updates-proxy policy/default-target refusal and is not a passing download run |

## Prompt-To-Artifact Checklist

| Objective phrase | Concrete artifact or evidence | Coverage |
| --- | --- | --- |
| Easily reviewable by humans | `README.md`, `REVIEWER_GUIDE.md`, `REVIEW_NOTES.md`, `ADAPTATION_INVENTORY.md`, this audit | Review path, scope, non-goals, and adaptation rationale are documented |
| Conform to Qubes maintainer expectations | `UPSTREAMING.md`, `REVIEW_NOTES.md`, `COPYING`, `config/README.md` | Expected contribution process is mapped; acceptance still requires external review |
| Inspect maintainer expectations online | `UPSTREAMING.md`, `REVIEW_NOTES.md` | Targeted review captured; exhaustive review of every Qubes issue/PR remains unclaimed |
| Upstream process may span multiple repos | `config/qubes-builderv2-guix.example.patch`, `config/qubes-release-configs-guix.example.patch`, `config/README.md` | Builder v2 and release-config targets are separated and named |
| Clear commit history | `git log --oneline`, `PATCH_SERIES.md` | Clean review branch present; final public branch still needs maintainer signing |
| Every non-obvious change explained | `REVIEW_NOTES.md`, `ADAPTATION_INVENTORY.md`, `MAINTENANCE.md` | Package phases, services, update model, and review-sensitive choices are documented |
| Tests should exercise real contracts | `tests/builder-content-check.sh`, `tests/builder-rpm-contract-check.sh`, `tests/rpm-layout-check.sh`, `VALIDATION.md` | Default local checks execute Builder content hooks, feed generated images through the Builder RPM adapter, build/extract/reassemble RPM layouts, and validate RPM lifecycle metadata; missing RPM/image tooling is a hard failure, not a false pass |
| No static/source-pattern test substitute | `CONTRIBUTING.md`, `README.md`, `ADAPTATION_INVENTORY.md`, `tests/` | Contributor policy rejects source-pattern or patch-shape checks as upstream evidence; current local tests build or inspect generated artifacts, and package-time test disabling is documented as a runtime-environment limitation rather than papered over with static checks |

## Current Completion Audit

This audit treats the requested upstreamability goal as these concrete
deliverables:

- A human-reviewable source tree with a clean public history.
- A source-backed map from Qubes maintainer expectations to local artifacts.
- Clear separation of local implementation, Builder v2 changes, and
  release-config changes.
- Rationale for every non-obvious Guix/Qubes compatibility decision.
- Contract tests that exercise build or packaging behavior and externally
  visible metadata.
- An explicit list of remaining gates that cannot honestly be claimed yet.

Inspected evidence in the current tree:

| Check | Evidence |
| --- | --- |
| Clean public branch history | `git log --oneline --decorate --max-count=5` shows only scoped review commits on `master`. |
| Tracked tests exercise build contracts | `make check` runs `tests/builder-content-check.sh`, `tests/builder-rpm-contract-check.sh`, and `tests/rpm-layout-check.sh`. |
| Static-check harness is absent | `git ls-files tests` lists only the Builder content, Builder RPM contract, and RPM layout checks; contributor guidance rejects source-pattern checks as upstream evidence. |
| Working tree clean | `git status --short` has no output. |
| Qubes source pins are fresh | Current local `./scripts/check-qubes-pins.sh` passed for all pinned Qubes VM components. |
| Prompt-to-artifact checklist exists | This file maps objective phrases to artifacts and marks incomplete external gates. |
| Online expectations are traceable | `UPSTREAMING.md` contains an online source crosswalk for Qubes docs, Builder v2, release-configs, forum precedent, and comparable NixOS issue/PRs. |
| Non-obvious changes are explained | `REVIEW_NOTES.md`, `ADAPTATION_INVENTORY.md`, and `MAINTENANCE.md` explain package phases, Shepherd services, FHS compatibility paths, update model, swap, guest-side memory ballooning plumbing, and review-sensitive source edits. |
| Security-sensitive scope is explicit | `SECURITY.md` separates dom0 trust boundaries, guest privileged behavior, source integrity, and unproven runtime gates. |
| Template-builder precedent is explicit | `TEMPLATE_PRECEDENTS.md` maps Guix hooks to the standard Qubes template hook responsibilities and release-config model. |
| Contributor workflow is explicit | `CONTRIBUTING.md` lists required checks, release evidence, review rules, and multi-repo ordering. |
| Local tests cover real contracts | `make check` runs `tests/builder-content-check.sh`, `tests/builder-rpm-contract-check.sh`, and `tests/rpm-layout-check.sh`; these execute Builder content hooks, package generated normal and minimal root images through the Builder adapter, build/extract/reassemble normal and minimal template RPM layouts, and validate the RPM metadata path through the dom0 lifecycle harness in metadata-only mode. |
| Builder v2 sketch has focused tests | Fresh patched checkout `/tmp/qubes-builderv2-current` at upstream `ff36320` passed distribution and template-plugin support tests for `vm-guix`. |
| Release-config sketch parses after apply | Fresh patched checkout `/tmp/qubes-release-configs-current` at upstream `e7ad66d` parsed the resulting R4.3 community template YAML and confirmed `builder-guix`, `guix`, and `guix-minimal`. |
| Submission drafts exist | `SUBMISSION_DRAFTS.md` provides editable `qubes-devel`, `[Contribution]`, Builder v2 PR, and release-config PR drafts with placeholder and validation warnings. |

This still does not prove Qubes acceptance or runtime release quality.  The
status remains "reviewable prototype" until the blockers in "Do Not Claim Yet"
are removed.

## Latest Evidence

Verification evidence includes the latest local pass plus earlier targeted
Builder/release-config checks:

```sh
bash -n scripts/test-native-guix-template-dom0.sh
bash -n scripts/test-update-proxy-default-target-dom0.sh
bash -n scripts/test-guix-update-proxy-config-dom0.sh
bash -n scripts/test-guix-update-proxy-download-dom0.sh
bash -n scripts/test-memory-balloon-dom0.sh
make check
git diff --check
git status --short
./scripts/check-qubes-pins.sh
PYTHONPATH=/tmp/qubes-builderv2-current python -m pytest /tmp/qubes-builderv2-current/tests/test_objects.py::test_dist /tmp/qubes-builderv2-current/tests/test_objects.py::test_dist_family /tmp/qubes-builderv2-current/tests/test_objects.py::test_template_plugin_supports_guix
# release-config YAML validation in /tmp/qubes-release-configs-current; see VALIDATION.md
```

The review source tree was also copied to the GCP builder as
`~/guix-review-current`.  There, `./scripts/check-qubes-pins.sh` passed against
the live Qubes GitHub tags, and the pinned Guix channel resolved with
`guix time-machine -C config/channels.scm -- describe`.

After adding the Guix-specific updates-proxy configuration service, the synced
current tree also loaded both `normal` and `minimal` operating-system variants
with real Guix on the GCP builder.  This checks the Scheme service graph.  A
later rebuilt-image boot test in RPM-mode openQA job 27 also verified the
generated Guix client wrapper, updates-proxy forwarder, and `guix-daemon`
service state for `guix-minimal`.  That still does not prove real `guix pull`
or substitute downloads using the Qubes proxy.

The same GCP source tree also produced a fresh `guix-minimal` 20G root image,
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

The GCP nested dom0 then mounted `/tmp/qubes-guix-dom0-data.img` read-only and
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

RPM-mode openQA also passed for the 2026051602 RPMs on the GCP openQA host:

```text
job 8:  BUILD=guix-normal-rpm-2026051602-inline-marker   TEST=guix_template   result=passed
job 9:  BUILD=guix-minimal-rpm-2026051602-inline-marker  TEST=guix_template   result=passed
```

Those jobs exercised the RPM asset path, `qvm-template --yes install
--nogpgcheck`, postinstall failure checks, and the dom0 TemplateVM/AppVM smoke
harness.  They are current review evidence, not a replacement for final reruns
from the signed public branch.

After the Guix update-proxy service change, RPM-mode openQA job 27 passed for a
rebuilt `guix-minimal` RPM:

```text
job 27: BUILD=guix-minimal-rpm-r202605162304-proxyfix-202605162312 TEST=guix_template result=passed
```

That job covered `qvm-template` install, postinstall diagnostics, log scanning,
TemplateVM/AppVM smoke, standard `/dev/xvdc1` swap, guest-side
`meminfo-writer`, qrexec, `qubes.WaitForSession`, the generated Guix
updates-proxy forwarder, and `guix-daemon` service-state checks.  It is still
review evidence from the current GCP/openQA tree, not final signed-branch
release evidence.

OpenQA job 29 then enabled `GUIX_RUN_PROXY_DOWNLOAD_TEST=1` for the same
rebuilt minimal RPM.  It passed the earlier install, postinstall, smoke, and
Guix proxy-configuration steps, then failed the opt-in real-download step with
`Request refused` from `qrexec-client-vm` and a `socat` child exit status 126.
That is negative evidence: the download verifier is wired and strict, but the
current nested openQA environment did not provide an allowed/default
`qubes.UpdatesProxy` target for a real Guix download.

## Do Not Claim Yet

Do not claim that:

- A public maintainer repository exists.
- A maintainer name and GPG fingerprint are known.
- Commits or release tags are signed.
- Qubes Builder v2 accepts `dist: guix`.
- `qubes-release-configs` accepts the Guix community-template entries.
- Exhaustive review of every Qubes pull request or issue has been performed.
  The current online review is intentionally targeted to sources most relevant
  to template contribution expectations.
- Final signed-branch or signed-tag release evidence has been rerun, including
  RPM-mode openQA.
- End-to-end Guix update tooling is freshly green through the Qubes update
  proxy.  The current evidence proves the default `qubes.UpdatesProxy` HTTP
  forwarding path through stock Qubes policy, and the source now configures
  Guix daemon/client proxy use.  RPM-mode openQA job 27 passed the generated
  daemon/client proxy verifier, and job 29 reached the real-download verifier,
  but it failed on dom0 updates-proxy refusal.  The tree still does not prove
  `guix pull`, `guix download`, or substitute downloads using that proxy.
- Qubes maintainers have reviewed or accepted the template.

Until those items are complete, the correct upstream status is: reviewable
prototype with local, GCP build, and nested-dom0 lifecycle evidence, not
publishable community template.
