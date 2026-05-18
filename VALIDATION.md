# Validation Snapshot

This file records accumulated validation evidence for the native GNU Guix
System Qubes TemplateVM prototype.  It is evidence for review discussion, not
proof that Qubes has accepted or published the template.

Command snippets use `$REPO` for this repository checkout and
`$REMOTE_REVIEW_TREE` for a clean checkout on a Guix-capable review builder.

## Evidence Scope

The normal/minimal rootfs and RPM evidence below is a release-build snapshot
from May 15, 2026.  It shows the build path has worked for this review effort,
but it is not a substitute for fresh release evidence from the final publication
branch or release object.  Later commits may update review documentation,
Builder/release-config sketches, or package metadata, so the final submission
must rerun the release gates from the exact branch or tag that Qubes reviewers
are asked to evaluate.

The `qvm-template` install/reinstall/remove/upgrade/downgrade gate,
nested-dom0 TemplateVM/AppVM smoke gate, and RPM-mode openQA gate have passing
evidence for both variants.  The nested-dom0 and openQA evidence includes
standard Qubes swap activation and guest-side `meminfo-writer` startup.  A
controlled update-proxy qrexec forwarding smoke also passed in nested dom0, and
the default update-target path later passed through the stock Qubes
`@type:TemplateVM -> @default target=sys-net` policy using a temporary
`sys-net` stub.  The current source contains a Guix-specific proxy
configuration service, and a rebuilt `guix-minimal` RPM-mode openQA job passed
the generated Guix client wrapper, updates-proxy forwarder, and `guix-daemon`
service-state verifier.  Later RPM-mode openQA runs passed a controlled
`guix download` through the generated wrapper and stock Qubes default-target
policy using a temporary `sys-net` stub; job 44 also checked that the source
TemplateVM had no direct IPv4 or IPv6 default route before counting the download
as update-proxy evidence, and it verified the runtime path setup cleanup did not
emit the previous `ln: failed` proxy-log noise.  Final publication reruns and
real Guix update tooling through an Internet update target still remain open.

## Current HEAD Contract Checks

The clean `upstream-review` branch exposes the following current contract
checks.  Final publication reruns are still required before publication.

Current-head local recheck after review-history cleanup on May 18, 2026:

- `make check` passed from the squashed `upstream-review` branch after the
  placeholder cleanup, regenerated core-admin example patch, and validation
  wording refresh.  This reran the script CLI, rootfs policy, Builder hook,
  Builder adapter, Builder RPM, central vmupdate harness, and normal plus
  minimal RPM layout checks.
- `make check-qubes-pins` passed against live Qubes upstream tags.  The
  checked pins remain current for `qubes-core-vchan-xen` v4.2.8,
  `qubes-linux-utils` v4.3.17, `qubes-core-qubesdb` v4.3.2,
  `qubes-core-qrexec` v4.3.12, `qubes-core-agent-linux` v4.3.43,
  `qubes-gui-common` v4.3.1, and `qubes-gui-agent-linux` v4.3.16.
- `git diff --check` passed for the template branch and for the paired
  `qubes-core-admin-linux` vmupdate PR branch.
- Public review text and tracked template files were scanned for PATs, local
  home paths, cloud-specific names, and temporary hosted-owner references.  The
  only remaining personal-repository reference found in the public PR comments
  is a maintainer comment pointing readers at the current review repository.
- A fresh Guix-capable clean clone of an earlier template review head
  `2f209a4403652937678c1fd76bc9b71919e05236` built, inspected, activated, and
  packaged `guix-minimal` for the maintainer-requested build log.  Since that
  build, the template review branch has changed review documentation,
  placeholder wording, checked-in patch-sketch metadata, Qubes pins, no-shrink
  RPM packaging, and openQA/dom0 harness reliability code.  The output RPM was
  `qubes-template-guix-minimal-4.3.0-202605181520.noarch.rpm` with SHA256
  `eb0d9603739a5695c4698dde8dd81d04b27c6d48f6d507482b5de687fcaa61ec`.  The
  sanitized build-log comment in QubesOS/qubes-builderv2#245 is retained as
  prior evidence, not as current-head release evidence.
- The checked-in core-admin Linux vmupdate patch was regenerated from the live
  QubesOS/qubes-core-admin-linux#211 PR branch after its streaming-output
  amend.  In that paired checkout,
  `PYTHONPATH=../qubes-core-admin-client:. ./run-tests.sh` reported
  `52 passed, 1 warning`.
- The local shell used for this recheck did not have `guix` in `PATH`, so
  `make guix-system-contract-check` was not refreshed locally; the last
  Guix-enabled system-contract evidence remains the clean remote run recorded
  below.
- `make check-qubes-pins` passed again at commit `96a0c82` against live Qubes
  tags.
- The split `qubes-builder-guix` review component also passed
  `make check` at signed commit `d864b22`, covering its script CLI, rootfs policy,
  Builder hook, Builder adapter, Builder RPM, and normal plus minimal RPM
  layout checks.
- `make check` and `make check-qubes-pins` passed again in this repository
  after recording the split component validation refresh.
- A clean remote clone of `origin/upstream-review` at commit `d106c27` passed
  `make check` and `make guix-system-contract-check` after the central
  vmupdate probe URL was plumbed through the openQA scheduler.  Later local
  rechecks passed `make check` and `make check-qubes-pins`; the Guix-only
  system-contract check was not refreshed after the latest documentation and
  openQA harness amendments.  This is contract evidence only; it is not a
  passing real Internet update-target run.
- `make check` passed at commit `b0446b0`.
- `make check-qubes-pins` passed at commit `b0446b0` against live Qubes tags,
  confirming the pinned R4.3 VM component tags are still current for this
  review branch.
- The checked-in multi-repo patch sketches still applied to current upstream
  heads: Builder v2 `8059f1d`, release-configs `e7ad66d`, and
  core-admin-linux `32a14bb`.

Current-head recheck after centralized update proof hardening on May 19, 2026:

- Local `git diff --check`, shell syntax checks, `make check`, and
  `make check-qubes-pins` passed after the centralized update harness, openQA
  timeout, no-shrink RPM packaging, and Qubes VM component pin refresh.
- `make check-qubes-pins` confirmed the current Qubes R4.3 pins including
  `qubes-core-agent-linux v4.3.43`.
- The local paired `qubes-core-admin-linux` review branch at `182199c` passed
  `PYTHONPATH=<qubes-core-admin-client checkout>:. ./run-tests.sh vmupdate/tests/test_agent_guix.py`
  with `52 passed, 1 warning`; the public PR head now matches.
- Read-only GitHub API checks on May 19 found the three split-component PRs
  still open and draft, with no submitted reviews.  Builder v2 head `f9ec921`
  has Qubes code-signing and GitLab CI success, core-admin Linux public head
  `182199c` has Qubes code-signing and GitLab CI success with maintainer-tag
  pending, and release-config head `fb356bd` has Qubes code-signing success.
- RPM-mode openQA job 129 ran `guix-minimal` from a no-shrink qvm-template RPM
  with a standard Debian `sys-net` update target.  It passed TemplateVM/AppVM
  smoke, generated Guix update-proxy configuration, update-target bootstrap,
  raw `qubes.UpdatesProxy` probing, `guix time-machine --branch=master`
  refresh, `guix system reconfigure --no-bootloader /etc/config.scm`, package
  metadata reporting, and `agent exit code: 0`.
- RPM-mode openQA job 133 reran the same path with the corrected log-evidence
  harness and an explicit `MAX_JOB_TIME=21600`.  It passed the same pre-update
  gates and reached Guix through the Qubes update proxy, but Guix refresh failed
  with `guix time-machine: error: Git error: unexpected http status code: 504`.
  This is useful negative evidence: the central harness now distinguishes a
  real upstream Git/proxy fetch failure from qrexec, Qubes policy, or unsupported
  OS-family dispatch failures.

Latest clean-branch validation run on May 17, 2026:

- Local shell syntax plus artifact contracts:
  `bash -n scripts/*.sh builder-v2-template/*.sh tests/*.sh && make check`
  passed.
- Local live Qubes pin freshness: `make check-qubes-pins` passed for every
  pinned Qubes VM component.
- Remote Guix-capable builder from a clean `git archive HEAD`:
  `./tests/guix-system-contract-check.sh` passed, then
  `./scripts/check-qubes-pins.sh` passed against live Qubes tags.
- Fresh upstream Builder/release sketch checks:
  `config/qubes-builderv2-guix.example.patch` applied to upstream `ff36320`
  and its four focused `test_objects.py` tests passed;
  `config/qubes-release-configs-guix.example.patch` applied to upstream
  `e7ad66d` and the resulting R4.3 community-template YAML parsed with the
  expected `builder-guix`, `guix`, and `guix-minimal` entries.

Current-HEAD local recheck after review-material cleanup on May 17, 2026:

- `make check` passed after this review-material refresh.
- The stored Builder v2, release-configs, and core-admin-linux patch sketches
  each applied cleanly to their corresponding clean `origin/main` worktree.
- The external core-admin-linux patch bundle replayed with `git am --3way
  --keep-cr`, and the patch bundle `SHA256SUMS` check passed.
- The real-network Guix update-proxy download gate now first probes the raw
  Qubes proxy path through `127.0.0.1:8082`, then runs `guix download` through
  the generated wrapper.  This is a stricter diagnostic gate, not new passing
  Internet-target evidence.
- The real-network and controlled-stub Guix download gate now refuses to count
  a run as Qubes updates-proxy proof if the source TemplateVM has a direct IPv4
  or IPv6 default route.
- `scripts/qubes-nested-dom0-host.sh put-file` now sends serial payloads with
  explicit heredoc delimiters and keeps the decoded-file SHA-256 check; `make
  check` passed after this helper change.  A subsequent remote nested-dom0
  restart did not reach serial login or SSH before timeout, so no new remote
  update-proxy runtime evidence was produced by that recheck.

Current-HEAD local recheck after patch-artifact and branch-history hygiene
updates on May 18, 2026:

- `make check` passed at commit `b965a89`.
- This reran the script CLI, rootfs policy, Builder hook, Builder adapter,
  Builder RPM, and native template RPM layout contract checks for both normal
  and minimal variants at that review head.

Current-HEAD recheck after runtime path setup cleanup on May 18, 2026:

- Local `make check` passed at commit `d508939`.
- A clean remote checkout of `origin/upstream-review` at `d508939` passed
  `make guix-system-contract-check` and `make check`.
- The remote checkout built, inspected, activated, and packaged a fresh
  `guix-minimal` root image/RPM pair:
  `root-minimal-rd508939stub.img` and
  `dist/qubes-template-guix-minimal-20260518-d508939stub.noarch.rpm`.
- The RPM SHA256 was
  `7e092e73681286e4111779282657e7fe6b0d370c1e66b5ea7561cb8d04afc52a`.
- RPM-mode openQA job 44 passed against that current-head artifact with
  `GUIX_RUN_PROXY_STUB_DOWNLOAD_TEST=1`, `GUIX_RUN_PROXY_DOWNLOAD_TEST=0`, and
  `QEMURAM=24576`.

Current-HEAD local and remote recheck after central updater proof-script
tightening on May 18, 2026:

- `scripts/test-guix-central-vmupdate-dom0.sh` now invokes
  `qubes-vm-update` with both `--force-update` and `--force-upgrade`, then
  refuses to count the run as passing unless the updater output contains the
  Guix refresh marker and the Guix System reconfigure marker.
- The same central updater harness now refuses to count a run as Qubes
  updates-proxy evidence when the source TemplateVM has a direct default route,
  and it raw-probes the Qubes updates proxy against the Guix channel host
  before invoking `qubes-vm-update`.
- `tests/central-vmupdate-harness-check.sh` now covers that behavior with fake
  dom0 commands in the default `make check` suite: it verifies the forced
  updater flags and rejects missing Guix reconfigure output.
- `tests/script-cli-check.sh` covers the new central updater
  `--proxy-probe-url` option's missing-value behavior.
- Local `make check` passed after this harness and test change.
- A clean remote checkout of `origin/upstream-review` at the then-pushed head
  passed `make guix-system-contract-check` and `make check`.

Current recheck after openQA console-readiness and central preflight diagnostic
tightening on May 18, 2026:

- Local `make check` passed at commit `15ec5cf`.
- RPM-mode openQA job 49 ran `guix-minimal` at commit `023cfa2` with
  `GUIX_RUN_CENTRAL_VMUPDATE_TEST=1` and `QEMURAM=24576`.
- Job 49 passed nested dom0 root-console readiness, Template Manager RPM
  install, postinstall diagnostics, postinstall log scanning, TemplateVM/AppVM
  smoke, and generated Guix update-proxy configuration.
- The same run failed the central updater gate before invoking
  `qubes-vm-update`: the raw `127.0.0.1:8082` updates-proxy preflight returned
  no HTTP response, the TemplateVM forwarder logged `Request refused`, and dom0
  reported `updatevm: <unset>`.  This is current evidence that the
  nested openQA environment still lacks a usable Internet-capable Qubes updates
  proxy target; it is not evidence of a TemplateVM qrexec, RPM import, smoke, or
  generated Guix proxy configuration failure.
- Commit `15ec5cf` only adds clearer central-preflight diagnostics for this
  Qubes policy/target refusal and does not change the template image.

Separate Builder component split on May 18, 2026:

- A new `qubes-builder-guix` review component was split from the template
  prototype so Builder-owned code can be reviewed separately from the template
  repository.
- The release-config examples in this repository still use
  `https://github.com/<OWNER>/qubes-builder-guix`; the review mirror is not
  treated as canonical publication metadata.
- The component contains the Builder hooks, native Guix system definitions,
  pinned channel file, rootfs/RPM scripts, appmenu/template metadata, and
  behavior tests only.  It does not contain cloud test setup, nested-dom0
  helpers, generated RPMs, generated images, logs, caches, or signing keys.
- `make check` passed in the split component at signed commit `d864b22`.  The default
  check covered CLI argument contracts, pinned-channel rootfs policy, Builder
  hook behavior, Builder adapter root-image artifacts, Builder adapter RPM
  output, and normal plus minimal qvm-template RPM layout
  extraction/reassembly.
- `./tests/guix-system-contract-check.sh` was not run locally because `guix`
  was not in `PATH` in this shell.  It remains an optional check for a
  Guix-capable review builder.

Core-admin vmupdate refresh on May 17, 2026:

- The clean `qubes-core-admin-linux` PR branch was refreshed so the Guix backend
  declares `PROGRESS_REPORTING = False`, which the shared updater entrypoint
  reads after every update run.
- The generated Guix wrapper and the staged core-admin backend now export
  `all_proxy` and `ALL_PROXY` in addition to the HTTP/HTTPS proxy variables,
  matching Qubes' existing update-proxy wrapper shape for tools that consume a
  generic proxy environment.
- A fresh `git archive` of this branch after the proxy-environment change was
  unpacked on the remote Guix-capable review builder; both
  `make guix-system-contract-check` and `./scripts/check-qubes-pins.sh`
  passed there.
- A remote Guix 1.5.0 proxy probe showed `guix download` honors
  `https_proxy` for HTTPS downloads, while `ALL_PROXY` alone did not force that
  path through the proxy.  The `ALL_PROXY` addition is therefore
  Qubes-wrapper compatibility, not proof that public Guix time-machine,
  substitute, or download traffic is fully proven through the Qubes proxy.
- A bounded nested-dom0 recheck on the remote host started QEMU with
  `QUBES_NESTED_MEMORY=24576`; SSH did not become reachable, but the serial
  console did.  `qvm-ls --raw-list` still showed only `dom0` and `guix`,
  `qvm-check sys-net` reported no `sys-net`, and QEMU was stopped afterward.
  This environment still cannot prove a real Internet update-proxy target.
- `PYTHONPATH=../qubes-core-admin-client:. ./run-tests.sh` passed in the
  patched `qubes-core-admin-linux` checkout:
  `52 passed, 1 warning`.  The Guix backend coverage now includes converting
  Guix manifest tabs to a printable separator before Qubes'
  untrusted-output sanitizer runs, per-output `/run/current-system/profile`
  metadata parsing, fallback to the system generation if the manifest cannot be
  listed, vmupdate-scoped temporary `HOME`/XDG state for `guix time-machine`,
  explicit refresh/reconfigure log lines, realtime streaming for those
  time-machine commands, and the shared dom0-visible package change summary.
  Additional parser fallback tests were added after Codecov flagged missing
  patch coverage; the refreshed core-admin PR head now reports all modified
  coverable lines covered.
- The same nested-dom0 run reached the current Guix backend through
  `qubes-vm-update --targets guix --force-update --force-upgrade
  --show-output --no-progress --no-cleanup --log DEBUG`.  The latest
  `update-guix.log` run showed system-profile metadata collection, used
  `HOME=/tmp` with vmupdate-specific `XDG_CONFIG_HOME` and `XDG_CACHE_HOME`,
  and logged the real Guix failure:
  `guix time-machine: error: Git error: unexpected EOF`.  A direct root
  backend probe in the guest printed clear records such as
  `bash:out -> 5.2.37 /gnu/store/...-bash-5.2.37` and
  `guix-system -> /gnu/store/...-system`.  This is evidence that central
  dispatch, metadata, proxy environment, and logging work; it is not a passing
  public-network update because this nested setup still has only `dom0` and
  `guix`, with no usable Internet-capable Qubes update-proxy target.

Local artifact check:

```sh
make check
```

Remote Guix system-contract check:

```sh
make guix-system-contract-check
```

`make check` currently runs `tests/script-cli-check.sh`,
`tests/build-native-rootfs-policy-check.sh`,
`tests/builder-hook-contract-check.sh`,
`tests/builder-adapter-contract-check.sh`,
`tests/builder-rpm-contract-check.sh`,
`tests/central-vmupdate-harness-check.sh`, and
`tests/rpm-layout-check.sh`.
The default suite does not include source-text, patch-shape, or
release-config-fragment checks as substitute evidence.  Tests in this suite
must exercise generated artifacts or Qubes-visible contracts.
The script CLI check executes public build/package/runtime validation scripts
with missing required option values and asserts useful errors before external
commands or side effects.  The native rootfs policy check executes
`scripts/build-native-rootfs.sh` from a
temporary repository without `config/channels.scm` and asserts that it fails
before fake `guix`, `sudo`, or `mountpoint` commands can run or image/mount
artifacts can be created.  The Builder hook contract check executes the
Builder v2 hooks against a temporary install tree.  The Builder RPM contract
check feeds generated ext4 root images through
`scripts/builder-v2-template-adapter.sh build-rpm`, validates the resulting
`qubes-template-*` metadata with
`scripts/test-template-rpm-lifecycle-dom0.sh --metadata-only`, extracts the
payload, and reads marker files back from the reassembled root images.  The RPM
layout test builds real normal and minimal `qubes-template-*` RPMs from a
generated ext4 `root.img`, extracts the payload, checks the Qubes Template
Manager layout, reassembles the split root image, reads the marker file from
the extracted filesystem, and validates the RPM-to-template metadata through
`scripts/test-template-rpm-lifecycle-dom0.sh` via a symlinked runner using the
short option form.

The optional `make guix-system-contract-check` gate requires Guix.  It was run
on the remote Guix review builder and passed with:

```text
./tests/guix-system-contract-check.sh
Guix system contract check passed
```

That check instantiates the normal and minimal `operating-system` records with
real Guix and asserts standard Qubes/Guix system contracts: `/dev/xvdc1` swap,
the standard `user` account with Qubes group membership, unchanged Guix default
privileged programs, passwordless `wheel` and `user` sudo, required Qubes
services including the updates-proxy forwarder, and default `meminfo-writer`
configuration.

No source-only checker is part of the validation evidence or the repository
test suite.  Static source-shape and patch-shape scripts are not release gates
and should not be submitted as repository tests or substitutes for artifact,
Guix system-record, dom0, or openQA evidence.  Formatting, parser-only, and
inventory commands may be useful local preparation chores, but they are not
recorded here as proof that the template works.

Earlier targeted Scheme-load evidence is kept here for traceability.  After
aligning the updates-proxy wrapper with Qubes' current
`--use-stdin-socket` command, the touched Scheme file was synced to the remote
Guix builder checkout and loaded with real Guix:

```sh
cd "$REMOTE_REVIEW_TREE"
guix repl -L "$REMOTE_REVIEW_TREE/native/modules" -- /dev/stdin
```

The REPL loaded `(qubes packages qubes-vm)`, `(qubes services qubes-vm)`, and
`native/qubes-guix.scm`, then printed the expected `qubes-vm-core` package
version:

```text
4.3.42
```

After adding `qubes-guix-update-proxy-service-type`, the then-current tree was
synced to the same remote Guix builder and both operating-system variants were
constructed with real Guix:

```sh
cd "$REMOTE_REVIEW_TREE"
guix repl -L native/modules -- /dev/stdin <<'EOF'
(use-modules (guix packages)
             (qubes packages qubes-vm)
             (qubes systems guix-template))
(display (package-version qubes-vm-core))
(newline)
(qubes-template-operating-system #:variant 'normal)
(qubes-template-operating-system #:variant 'minimal)
(display "loaded normal and minimal systems")
(newline)
EOF
```

Observed result:

```text
4.3.42
loaded normal and minimal systems
```

The newer `make guix-system-contract-check` gate above supersedes this REPL
load as the executable Guix system-record check for the current review branch.

## Builder And Release Sketch Checks

The focused Builder v2 distribution tests also passed after applying the
Builder patch in a fresh shallow checkout.  The latest refresh used current
upstream `qubes-builderv2` sources on May 17, 2026, at commit `ff36320`:

```sh
rm -rf /tmp/qubes-builderv2-current
git clone --depth 1 https://github.com/QubesOS/qubes-builderv2.git \
  /tmp/qubes-builderv2-current
git -C /tmp/qubes-builderv2-current apply \
  "$REPO/config/qubes-builderv2-guix.example.patch"
PYTHONPATH=/tmp/qubes-builderv2-current \
  python -m pytest \
    /tmp/qubes-builderv2-current/tests/test_objects.py::test_dist_non_default_arch \
    /tmp/qubes-builderv2-current/tests/test_objects.py::test_dist_family \
    /tmp/qubes-builderv2-current/tests/test_objects.py::test_template_plugin_supports_guix \
    /tmp/qubes-builderv2-current/tests/test_objects.py::test_template_plugin_guix_parameters
```

Result:

```text
4 passed
```

After upstream `qubes-builderv2` moved to commit `8059f1d`, the live Builder v2
RFC branch was rebased, then resquashed into one signed review commit at head
`f9ec921` so the commit message matches the checked-in patch artifact's current
four-test validation.  The checked-in
`config/qubes-builderv2-guix.example.patch` still applies against that upstream
base, and the same focused tests passed again locally:

```sh
PYTHONPATH=<qubes-builderv2 checkout> python -m pytest -q \
  <qubes-builderv2 checkout>/tests/test_objects.py::test_dist_non_default_arch \
  <qubes-builderv2 checkout>/tests/test_objects.py::test_dist_family \
  <qubes-builderv2 checkout>/tests/test_objects.py::test_template_plugin_supports_guix \
  <qubes-builderv2 checkout>/tests/test_objects.py::test_template_plugin_guix_parameters
```

```text
4 passed
```

Qubes code-signing is green on `f9ec921`, and the Builder v2 CI status is
green for that resquashed head.

The release-config sketch also passed an applied-config YAML validation in a
fresh shallow checkout.  The latest refresh used current upstream
`qubes-release-configs` sources on May 17, 2026, at commit `e7ad66d`:

```sh
rm -rf /tmp/qubes-release-configs-current
git clone --depth 1 https://github.com/QubesOS/qubes-release-configs.git \
  /tmp/qubes-release-configs-current
git -C /tmp/qubes-release-configs-current apply \
  "$REPO/config/qubes-release-configs-guix.example.patch"
python3 - <<'PY'
from pathlib import Path
import yaml
path = Path('/tmp/qubes-release-configs-current/R4.3/qubes-os-r4.3-templates-community.yml')
data = yaml.safe_load(path.read_text())
components = {next(iter(item)): next(iter(item.values())) for item in data.get('components', []) if isinstance(item, dict) and item}
templates = {next(iter(item)): next(iter(item.values())) for item in data.get('templates', []) if isinstance(item, dict) and item}
assert 'builder-guix' in components
assert components['builder-guix']['packages'] is False
assert components['builder-guix']['branch'] == 'main'
assert templates['guix']['dist'] == 'guix'
assert templates['guix-minimal']['dist'] == 'guix'
assert templates['guix-minimal']['flavor'] == 'minimal'
print('release-config guix entries parsed')
PY
```

Result:

```text
release-config guix entries parsed
```

The review source tree was also copied to the remote Guix builder as
`~/guix-review-current`.  On May 17, 2026, both the current local review tree
and the synced remote review checkout passed the network-dependent Qubes pin
freshness check:

```sh
./scripts/check-qubes-pins.sh
```

```text
ok: qubes-core-vchan-xen v4.2.8 a1337c282ffefcfc13a570683c57bc04813038db
ok: qubes-linux-utils v4.3.17 ee1e61f487f57d6b5d3ff96dbd8d6b50bd474656
ok: qubes-core-qubesdb v4.3.2 7d294b2ab922708b552fb2715f6a0333fbc52fcd
ok: qubes-core-qrexec v4.3.12 cc801b8f630a65dfb2855b829bfc070f6e82f26a
ok: qubes-core-agent-linux v4.3.42 37dd9cd76aa74669b80b849a650f35b982d922ec
ok: qubes-gui-common v4.3.1 66b879e36d6cd2a01271fc8d4c2c0f3be85d0029
ok: qubes-gui-agent-linux v4.3.16 bd8c395df20e64845ac4b3324552aebca32fea96
```

The block above records the May 17 pin state for traceability; the current
May 19 pin check is `qubes-core-agent-linux v4.3.43` as recorded near the top
of this file.

The pinned Guix channel in `config/channels.scm` was resolved on the remote Guix builder
with:

```text
guix 520785e
  repository URL: https://git.guix.gnu.org/guix.git
  branch: master
  commit: 520785e315eddbe47199ac557e88e60eca3ae97c
```

The rootfs builder's pinned-channel policy was also checked locally: a temporary
repo copy without `config/channels.scm` and with a fake `guix` in `PATH` failed
before mount/image work with:

```text
error: missing pinned Guix channels file: .../config/channels.scm; set GUIX_CHANNELS_FILE or explicit developer-only GUIX_BRANCH
```

This verifies that release builds no longer silently fall back to an unpinned
Guix branch when the pinned channel file is absent.

## Latest Remote Minimal Release Build Snapshot

- Date: 2026-05-15.
- Remote builder: remote Guix-capable review builder.
- Remote source tree: `~/guix-review-current`.
- Artifact directory:
  `/tmp/guix-review-release-minimal-202605152142`.
- Template name: `guix-minimal`.
- Template version/release: `4.3.0-202605152142`.
- Guix system profile:
  `/gnu/store/rfnzf2lr7ch5fni408ddmnl41h6kbpkd-system`.

The minimal root image was built as a 20G image with:

```sh
sudo env \
  ARTIFACTS_DIR=/tmp/guix-review-release-minimal-202605152142 \
  TEMPLATE_NAME=guix-minimal \
  TEMPLATE_FLAVOR=minimal \
  TEMPLATE_ROOT_SIZE=20G \
  make prepare build-rootimg
```

The resulting image passed inspection and activation:

```sh
sudo env ./scripts/inspect-native-rootfs.sh \
  --image /tmp/guix-review-release-minimal-202605152142/qubeized_images/guix-minimal/root.img \
  --expect-command xterm \
  --expect-command Xorg \
  --expect-desktop xterm.desktop

sudo env ./scripts/test-native-rootfs-activation.sh \
  --image /tmp/guix-review-release-minimal-202605152142/qubeized_images/guix-minimal/root.img
```

RPM packaging passed with:

```sh
sudo env \
  ARTIFACTS_DIR=/tmp/guix-review-release-minimal-202605152142 \
  TEMPLATE_NAME=guix-minimal \
  TEMPLATE_FLAVOR=minimal \
  TEMPLATE_VERSION=4.3.0 \
  TEMPLATE_TIMESTAMP=202605152142 \
  make prepare build-rpm
```

Produced RPM:

```text
/tmp/guix-review-release-minimal-202605152142/rpmbuild/RPMS/noarch/qubes-template-guix-minimal-4.3.0-202605152142.noarch.rpm
```

RPM SHA256:

```text
398a265293eb8a5eb893da83d0b3ebbf10b7c60574aeac695a7b3dff700d8629
```

RPM size:

```text
661M
```

Root image disk usage after packaging:

```text
2.3G
```

## Latest Remote Normal Release Build Snapshot

- Date: 2026-05-15.
- Remote builder: remote Guix-capable review builder.
- Remote source tree: `~/guix-review-current`.
- Artifact directory:
  `/tmp/guix-review-release-normal-202605152143`.
- Template name: `guix`.
- Template version/release: `4.3.0-202605152143`.
- Guix system profile:
  `/gnu/store/miv78shhkv5r2hnxhcdyail787swzf43-system`.

The normal root image was built as a 20G image with:

```sh
sudo env \
  ARTIFACTS_DIR=/tmp/guix-review-release-normal-202605152143 \
  TEMPLATE_NAME=guix \
  TEMPLATE_ROOT_SIZE=20G \
  make prepare build-rootimg
```

The resulting image passed inspection and activation:

```sh
sudo env ./scripts/inspect-native-rootfs.sh \
  --image /tmp/guix-review-release-normal-202605152143/qubeized_images/guix/root.img \
  --expect-command xfce4-terminal \
  --expect-command Xorg \
  --expect-desktop xfce4-terminal.desktop

sudo env ./scripts/test-native-rootfs-activation.sh \
  --image /tmp/guix-review-release-normal-202605152143/qubeized_images/guix/root.img
```

RPM packaging passed with:

```sh
sudo env \
  ARTIFACTS_DIR=/tmp/guix-review-release-normal-202605152143 \
  TEMPLATE_NAME=guix \
  TEMPLATE_VERSION=4.3.0 \
  TEMPLATE_TIMESTAMP=202605152143 \
  make prepare build-rpm
```

Produced RPM:

```text
/tmp/guix-review-release-normal-202605152143/rpmbuild/RPMS/noarch/qubes-template-guix-4.3.0-202605152143.noarch.rpm
```

RPM SHA256:

```text
942a7d892f28cb565f5acfdb7df50282ada0c9ded2abef91219d41038ec01955
```

RPM size:

```text
818M
```

Root image disk usage after packaging:

```text
2.7G
```

## Latest Nested Dom0 qvm-template Lifecycle And Smoke Snapshot

- Date: 2026-05-16.
- Remote builder: remote Guix-capable review builder.
- Nested dom0: Qubes R4.3.0, booted from the configured
  `$QUBES_NESTED_WORKDIR/vm/qubes-r4.3.0.qcow2` disk.
- Data shuttle images: `/tmp/qubes-guix-dom0-data.img` for the original
  install/reinstall smoke run and `/tmp/qubes-guix-dom0-upgrade-data.img` for
  the distinct-EVR upgrade/downgrade run, attached read-only as `/dev/sdb` and
  mounted read-only in nested dom0.
- Nested VM resources: `QUBES_NESTED_MEMORY=24576`,
  `QUBES_NESTED_CPUS=8`.

The data shuttle contained the fresh normal and minimal RPMs listed above plus
the patched lifecycle harness.  The harness checks the actual Qubes Template
Manager contract: the VM exists, `qvm-prefs TEMPLATE klass` is `TemplateVM`,
`qvm-features TEMPLATE template-name` matches the template name, and
`template-version` plus `template-release` matches the RPM EVR.  It does not
assert `installed_by_rpm=True`, because `qvm-template install` uses managed
template metadata.  With `--run-smoke`, it also creates an AppVM and runs the
dom0 smoke harness after install and again after reinstall.

The minimal variant passed:

```sh
/tmp/t -r /tmp/m.rpm -e guix-minimal -R -s
```

Result:

```text
template: guix-minimal
install RPM: /tmp/m.rpm (4.3.0-202605152142)
logs: /tmp/qubes-template-lifecycle-guix-minimal.$PID
running qvm-template install for guix-minimal
Installing template 'guix-minimal'...
guix-minimal: Importing data
running qvm-template reinstall for guix-minimal
Installing template 'guix-minimal'...
guix-minimal: Importing data
qvm-template lifecycle check passed for guix-minimal
```

The normal variant passed:

```sh
/tmp/t -r /tmp/g.rpm -e guix -R -s
```

Result:

```text
template: guix
install RPM: /tmp/g.rpm (4.3.0-202605152143)
logs: /tmp/qubes-template-lifecycle-guix.$PID
running qvm-template install for guix
Installing template 'guix'...
guix: Importing data
running qvm-template reinstall for guix
Installing template 'guix'...
guix: Importing data
qvm-template lifecycle check passed for guix
```

Smoke coverage included TemplateVM boot/qrexec, AppVM creation and qrexec,
QubesDB identity values, `/rw`, `/home`, and `/usr/local` mounts, `/dev/xvdb`,
desktop-file and command availability (`xterm`/`Xorg` for `guix-minimal`,
`xfce4-terminal`/`Xorg` for `guix`), `qubes.WaitForSession`, shutdown, and a
persistent AppVM home file across restart.

The smoke harness was then rerun for both variants after adding explicit
AppVM root assertions for standard Qubes swap and guest-side memory-ballooning
plumbing.  Both `guix-minimal` and `guix` passed the checks after install and
again after reinstall:

```sh
test -b /dev/xvdc1
grep -q '^/dev/xvdc1[[:space:]]' /proc/swaps
test -e /run/qubes-service/meminfo-writer
test -s /var/run/meminfo-writer.pid
kill -0 "$(cat /var/run/meminfo-writer.pid)"
pgrep -x meminfo-writer
```

## Dynamic Memory-Balloon Pressure Check

On May 16, 2026, the then-current review commit was copied to a clean remote
review tree.  Nested dom0 was started with the existing data image:

```sh
QUBES_NESTED_MEMORY=24576 \
ROOT_IMG=/tmp/qubes-guix-dom0-upgrade-data.img \
./scripts/qubes-nested-dom0-host.sh start
```

The `guix` template was present and had Qubes dynamic memory preferences:

```text
qvm-prefs guix klass   -> TemplateVM
qvm-prefs guix memory  -> 400
qvm-prefs guix maxmem  -> 4000
```

The dom0 memory-pressure harness was copied into nested dom0 and run against a
temporary AppVM:

```sh
./test-memory-balloon-dom0.sh \
  --template guix \
  --appvm guix-balloon-test \
  --replace-existing
```

Result:

```text
memory balloon check passed: guix-balloon-test grew from 400 MiB to 698 MiB
```

The cleanup path printed one guest-side `kill` warning for the Guile pressure
process, but follow-up dom0 checks showed no leftover AppVM and no leftover Xen
domain:

```text
qvm-ls --raw-list
dom0
guix

xl list
Name                                        ID   Mem VCPUs State   Time(s)
Domain-0                                     0  4080     8 r-----    160.3
```

The host-side nested QEMU process was stopped after the run.

The same nested dom0 then passed distinct-EVR upgrade and downgrade checks for
both variants.  The additional EVR RPMs were generated from the same release
root images, without rebuilding Guix System:

```text
6081f6630294c90420e1d7767775287f41102930e0870f3a8662062d2e8851b5  qubes-template-guix-minimal-4.3.0-202605152141.noarch.rpm
b17780fa49ff065a7c06f80d1742b2e59e8165ef91cc49c5bc9a5e0758a46e5c  qubes-template-guix-minimal-4.3.0-202605152143.noarch.rpm
24cff6b506a72002a161ecee6e396d7e1d05974095f5c9099d48a41ad1d03fe2  qubes-template-guix-4.3.0-202605152142.noarch.rpm
3bbeddc1b7348fc4b66987a1cf7bb0aaf4ab3fbad8574171e27ac5d48acd244c  qubes-template-guix-4.3.0-202605152144.noarch.rpm
```

The minimal upgrade/downgrade lifecycle passed:

```sh
/tmp/t -r /m/rpms/base-minimal.rpm \
  -u /m/rpms/upgrade-minimal.rpm \
  -d /m/rpms/downgrade-minimal.rpm \
  -e guix-minimal -R -s
```

The normal upgrade/downgrade lifecycle passed with `.rpm` symlinks to the same
read-only data-disk RPMs:

```sh
/tmp/t -r /tmp/b.rpm -u /tmp/u.rpm -d /tmp/d.rpm -e guix -R -s
```

Both runs ended with `qvm-template lifecycle check passed for ...` after
install, smoke, reinstall, repeated smoke, upgrade, downgrade, and final
remove.  The harness validates template metadata after each qvm-template
install/reinstall/upgrade/downgrade operation.

## Historical Release Build Snapshot

- Date: 2026-05-15.
- Release-build source: earlier review tree before the clean branch was split.
- Remote builder: remote Guix-capable review builder.
- Remote checkout: `~/guix-upstream-test`.
- Artifact timestamp: `202605150001`.

The release-build tree was copied to the remote builder from the local committed
tree with `git archive`.

## Historical Release Preflight

Local contract checks passed before remote release testing:

```sh
make check
```

Source pin provenance was checked separately with `make check-qubes-pins`.
That was not a template behavior test.

Remote contract checks passed with real Guix installed, so the Scheme module
load path was covered there:

```sh
make check
```

## Normal Template Evidence

The normal `guix` variant built a 20G root image through the Builder-shaped
adapter:

```sh
sudo env PATH="$PATH" HOME=/root \
  ARTIFACTS_DIR=/tmp/guix-upstream-release-normal \
  TEMPLATE_NAME=guix \
  TEMPLATE_FLAVOR= \
  TEMPLATE_ROOT_SIZE=20G \
  make prepare build-rootimg
```

The build produced this Guix system profile:

```text
/gnu/store/28ab509izyf23kvfal8i0yhi71gxwng7-system
```

Image inspection passed:

```sh
sudo env PATH="$PATH" HOME=/root \
  ./scripts/inspect-native-rootfs.sh \
  --image /tmp/guix-upstream-release-normal/qubeized_images/guix/root.img \
  --expect-command xfce4-terminal \
  --expect-command Xorg \
  --expect-desktop xfce4-terminal.desktop
```

Writable-root activation passed:

```sh
sudo env PATH="$PATH" HOME=/root \
  ./scripts/test-native-rootfs-activation.sh \
  --image /tmp/guix-upstream-release-normal/qubeized_images/guix/root.img
```

The activation test verifies generated `/etc` content, PAM for qrexec and GUI
services, qrexec shell execution for `root` and `user`, root execution for
`qubes.PostInstall`, and Guix distro metadata in `/etc/os-release`.

RPM packaging passed:

```sh
sudo env PATH="$PATH" HOME=/root \
  ARTIFACTS_DIR=/tmp/guix-upstream-release-normal \
  TEMPLATE_NAME=guix \
  TEMPLATE_FLAVOR= \
  TEMPLATE_VERSION=4.3.0 \
  TEMPLATE_TIMESTAMP=202605150001 \
  make prepare build-rpm
```

Produced RPM:

```text
/tmp/guix-upstream-release-normal/rpmbuild/RPMS/noarch/qubes-template-guix-4.3.0-202605150001.noarch.rpm
```

RPM SHA256:

```text
e9d5401f7a33e3afb686b8034e8ce3db181e8be28aba1b2cbd7275d3e08e87ba
```

RPM size:

```text
818M
```

## Minimal Template Evidence

The minimal `guix-minimal` variant built a 20G root image through the
Builder-shaped adapter:

```sh
sudo env PATH="$PATH" HOME=/root \
  ARTIFACTS_DIR=/tmp/guix-upstream-release-minimal \
  TEMPLATE_NAME=guix-minimal \
  TEMPLATE_FLAVOR=minimal \
  TEMPLATE_ROOT_SIZE=20G \
  make prepare build-rootimg
```

The build produced this Guix system profile:

```text
/gnu/store/f682gwlh407ind10zyy1i7f286kf7ffp-system
```

Image inspection passed:

```sh
sudo env PATH="$PATH" HOME=/root \
  ./scripts/inspect-native-rootfs.sh \
  --image /tmp/guix-upstream-release-minimal/qubeized_images/guix-minimal/root.img \
  --expect-command xterm \
  --expect-command Xorg \
  --expect-desktop xterm.desktop
```

Writable-root activation passed:

```sh
sudo env PATH="$PATH" HOME=/root \
  ./scripts/test-native-rootfs-activation.sh \
  --image /tmp/guix-upstream-release-minimal/qubeized_images/guix-minimal/root.img
```

The activation test verifies generated `/etc` content, PAM for qrexec and GUI
services, qrexec shell execution for `root` and `user`, root execution for
`qubes.PostInstall`, and Guix distro metadata in `/etc/os-release`.

RPM packaging passed:

```sh
sudo env PATH="$PATH" HOME=/root \
  ARTIFACTS_DIR=/tmp/guix-upstream-release-minimal \
  TEMPLATE_NAME=guix-minimal \
  TEMPLATE_FLAVOR=minimal \
  TEMPLATE_VERSION=4.3.0 \
  TEMPLATE_TIMESTAMP=202605150001 \
  make prepare build-rpm
```

Produced RPM:

```text
/tmp/guix-upstream-release-minimal/rpmbuild/RPMS/noarch/qubes-template-guix-minimal-4.3.0-202605150001.noarch.rpm
```

RPM SHA256:

```text
112e5b82f17c75b440b39a66cd7bffd59d8527c783b88b0ffba405695110a6e5
```

RPM size:

```text
661M
```

## Builder V2 Content-Script Smoke

After adding the standard content-script shape in `builder-v2-template/`, the
minimal variant was smoke-tested on the remote Guix builder by creating a blank 20G
ext4 root image, mounting it, and running:

```sh
builder-v2-template/00_prepare.sh
builder-v2-template/01_install_core.sh
builder-v2-template/02_install_groups.sh
builder-v2-template/04_install_qubes.sh
```

The smoke test used `TEMPLATE_NAME=guix-minimal`, `TEMPLATE_FLAVOR=minimal`,
and an already-mounted `INSTALL_DIR`, exercising
`scripts/build-native-rootfs.sh --install-dir`.

The resulting image passed:

```sh
./scripts/inspect-native-rootfs.sh \
  --image /tmp/guix-builder-v2-content.kZpu7c/root.img \
  --expect-command xterm \
  --expect-command Xorg \
  --expect-desktop xterm.desktop

./scripts/test-native-rootfs-activation.sh \
  --image /tmp/guix-builder-v2-content.kZpu7c/root.img
```

This is not a full Builder v2 job.  It shows the Guix Builder hooks can install
into Builder's mounted-root contract and produce an inspectable,
activatable minimal root image.

The matching Builder v2 patch sketch in
`config/qubes-builderv2-guix.example.patch` was also smoke-tested in a
refreshed `qubes-builderv2` checkout.  The focused distribution tests passed:

```sh
cd /tmp/qubes-builderv2-current
python -m pytest \
  tests/test_objects.py::test_dist_non_default_arch \
  tests/test_objects.py::test_dist_family \
  tests/test_objects.py::test_template_plugin_supports_guix \
  tests/test_objects.py::test_template_plugin_guix_parameters \
  -q
```

The focused plugin check verifies that `TemplateBuilderPlugin` accepts Guix
templates.  A full `tests/test_objects.py` run was not used as evidence because
unrelated tests require Docker in this environment.
The release-config fragment in
`config/qubes-os-r4.3-templates-community-guix.example.yml` was parsed with the
patched Builder v2 code and produced one component, `builder-guix`, plus two
templates, `guix` and `guix-minimal`, both using `vm-guix`.

## Default Updates-Proxy Target Check

On May 16, 2026, the current working tree was synced to a remote Guix-capable
review builder after changing the
`qubes-updates-proxy-forwarder` Shepherd requirement from qrexec/network
services to `qubes-sysinit`, matching Qubes' socket-activated model more
closely.  The builder produced and activation-tested:

```text
$REMOTE_REVIEW_TREE/root-update-proxy.img
$REMOTE_REVIEW_TREE/dist/qubes-template-guix-4.3.0-2026051602.noarch.rpm
```

The RPM was installed and reinstalled through nested dom0's Template Manager
path:

```sh
cd "$DOM0_TEST_DIR"
./test-template-rpm-lifecycle-dom0.sh \
  -r qubes-template-guix-4.3.0-2026051602.noarch.rpm \
  -e guix -R -k
```

Result:

```text
qvm-template lifecycle check passed for guix
```

The default update-target harness then passed from a clean target state after
removing an old local test policy override.  The only matching policy rule was
the stock Qubes default:

```text
/etc/qubes/policy.d/90-default.policy:78:qubes.UpdatesProxy      *   @type:TemplateVM        @default    allow target=sys-net
```

Clean nested-dom0 command:

```sh
cd "$DOM0_TEST_DIR"
./test-update-proxy-default-target-dom0.sh -t guix -T sys-net -c -s
```

Observed response:

```text
HTTP/1.1 200 OK
Content-Length: 2
Connection: close

OK
default updates-proxy target check passed: guix -> sys-net
```

This verifies that the native Guix TemplateVM's local `127.0.0.1:8082`
listener can reach Qubes' default update target selection through qrexec policy
and the target VM's `qubes.UpdatesProxy` service shape.  It does not prove real
Guix substitute or channel update tooling is fully configured to consume that
proxy; that remains a separate update workflow check.

## RPM-Mode openQA Template Checks

On May 16, 2026, a remote openQA host ran the RPM-mode openQA harness against
the 2026051602 normal and minimal template RPMs.  The harness used
`openqa/qubesos/tests/guix_template.pm` with `GUIX_INSTALL_MODE=rpm`, copied
helper scripts from the attached RPM asset disk, installed the template with
`qvm-template --yes install --nogpgcheck`, checked for postinstall failures,
and ran the dom0 TemplateVM/AppVM smoke script.

Later source also stages and runs
`scripts/test-guix-update-proxy-config-dom0.sh` from the same RPM asset disk.
Jobs 8 and 9 predate that verifier being wired into openQA, so they do not
prove the generated Guix daemon/client proxy configuration.

Normal template job:

```text
id: 8
BUILD: guix-normal-rpm-2026051602-inline-marker
TEST: guix_template
state: done
result: passed
```

Minimal template job:

```text
id: 9
BUILD: guix-minimal-rpm-2026051602-inline-marker
TEST: guix_template
state: done
result: passed
```

This is recorded release-review evidence for the RPM install path.  It is still
not a substitute for rerunning openQA from the final publication branch or
release object that Qubes reviewers are asked to evaluate.

On May 16, 2026, job 27 reran the minimal RPM-mode path from a rebuilt image
that includes the current updates-proxy forwarder and verifier changes:

```text
id: 27
BUILD: guix-minimal-rpm-r202605162304-proxyfix-202605162312
TEST: guix_template
state: done
result: passed
root image: $REMOTE_REVIEW_TREE/root-minimal-r202605162304.img
root image size: 20G
RPM: $REMOTE_REVIEW_TREE/dist/qubes-template-guix-minimal-4.3.0-202605162304.noarch.rpm
RPM size: 662M
RPM SHA256: 236641ab50919305d8e78bd9c9ef200582b3457cdd11973daea0d37f45b93904
result dir: /var/lib/openqa/testresults/00000/00000027-qubesos-4.3-guix-template-x86_64-Buildguix-minimal-rpm-r202605162304-proxyfix-202605162312-guix_template@qemu_x86_64
```

The archived serial log showed `qvm-template` install success
`OPENQA_RC_000007_0`, postinstall diagnostics success `OPENQA_RC_000008_0`,
postinstall log scan success `OPENQA_RC_000009_0`, TemplateVM/AppVM smoke
success `OPENQA_RC_000010_0`, Guix updates-proxy config success
`OPENQA_RC_000011_0`, log archival success `OPENQA_RC_000012_0`, and final
cleanup success `OPENQA_RC_000013_0`.  The smoke output included AppVM
`persistence=rw-only`, `xterm`, `Xorg`, `xterm.desktop`, `/dev/xvdc1` in
`/proc/swaps`, `/run/qubes-service/meminfo-writer`, a live
`meminfo-writer` process, `qrexec-ok`, `qubes.WaitForSession`, and
`native Guix TemplateVM smoke tests passed for guix-minimal`.  The proxy
verifier output included `checking Qubes updates-proxy forwarder`,
`Status of qubes-updates-proxy-forwarder: It is running`,
`checking guix-daemon service state`, `It is running`, and
`guix update proxy config check passed`.

On May 17, 2026, job 29 reran the same rebuilt minimal RPM-mode artifact with
the opt-in real-download proxy gate enabled:

```text
id: 29
BUILD: guix-minimal-rpm-r202605162304-proxydownload-short-202605170046
TEST: guix_template
state: done
result: failed
root image: $REMOTE_REVIEW_TREE/root-minimal-r202605162304.img
RPM: $REMOTE_REVIEW_TREE/dist/qubes-template-guix-minimal-4.3.0-202605162304.noarch.rpm
RPM SHA256: 236641ab50919305d8e78bd9c9ef200582b3457cdd11973daea0d37f45b93904
result dir: /var/lib/openqa/testresults/00000/00000029-qubesos-4.3-guix-template-x86_64-Buildguix-minimal-rpm-r202605162304-proxydownload-short-202605170046-guix_template@qemu_x86_64
```

This failed at the new optional real-download gate, not at the earlier template
integration gates.  The archived serial log showed `OPENQA_RC_000007_0`,
`OPENQA_RC_000008_0`, `OPENQA_RC_000009_0`, TemplateVM/AppVM smoke success
`OPENQA_RC_000010_0`, and Guix proxy configuration success
`OPENQA_RC_000011_0`.  The failing marker was `OPENQA_RC_000012_1` from
`scripts/test-guix-update-proxy-download-dom0.sh`.  Guest logs showed
`Request refused` from `qrexec-client-vm` and `socat ... child ... exited with
status 126`, so this run reached the Qubes updates-proxy forwarder but dom0
refused `qubes.UpdatesProxy` in the nested openQA environment.  This is useful
negative evidence: it confirms that the real-download verifier is wired into
openQA and strict, but it is not a passing Guix update-tooling proxy run.

On May 17, 2026, job 31 reran the same rebuilt minimal RPM-mode artifact with
the deterministic stub-download proxy gate enabled and the public-Internet
download gate disabled:

```text
id: 31
BUILD: guix-minimal-rpm-r202605162304-stubdownload-fix-202605170229
TEST: guix_template
state: done
result: passed
root image: $REMOTE_REVIEW_TREE/root-minimal-r202605162304.img
RPM: $REMOTE_REVIEW_TREE/dist/qubes-template-guix-minimal-4.3.0-202605162304.noarch.rpm
RPM SHA256: 236641ab50919305d8e78bd9c9ef200582b3457cdd11973daea0d37f45b93904
result dir: /var/lib/openqa/testresults/00000/00000031-qubesos-4.3-guix-template-x86_64-Buildguix-minimal-rpm-r202605162304-stubdownload-fix-202605170229-guix_template@qemu_x86_64
```

This run passed the earlier RPM install, postinstall, TemplateVM/AppVM smoke,
and Guix proxy configuration markers, then created a temporary `sys-net` stub
target and ran a controlled `guix download` through the generated Guix client
wrapper and Qubes `qubes.UpdatesProxy` path.  The archived serial log showed
`OPENQA_RC_000011_0` for proxy configuration, `downloaded 2 bytes`,
`guix update proxy download check passed`, `guix update proxy stub download
check passed: guix-minimal -> sys-net`, and `OPENQA_RC_000012_0` for the
controlled stub-download gate.  This verifies that the Guix client wrapper can
consume the local Qubes proxy through stock default-target policy in a
deterministic nested openQA environment.  It still does not prove public
Internet downloads, `guix time-machine`, or substitute downloads through a real
update-proxy target.

On May 17, 2026, job 38 repeated the controlled stub-download gate with a fresh
rebuilt minimal RPM that includes the current Guix proxy wrapper:

```text
id: 38
BUILD: guix-minimal-rpm-r202605171259-updatepath-stub-consolefix2-202605171431
TEST: guix_template
state: done
result: passed
template: guix-minimal
RPM SHA256: 319648c9813ef850c6a865d4cc0d129fb0a77ecde83eb422e86f0b30aae689e7
```

The archived serial log showed `OPENQA_RC_000007_0` for RPM install,
`OPENQA_RC_000008_0` and `OPENQA_RC_000009_0` for postinstall diagnostics and
log scanning, `qrexec-ok` and `OPENQA_RC_000010_0` for TemplateVM/AppVM smoke,
`guix update proxy config check passed` and `OPENQA_RC_000011_0` for generated
proxy configuration, then `raw proxy probe passed: HTTP/1.1 200 OK`,
`downloaded 2 bytes`, `guix update proxy download check passed`,
`guix update proxy stub download check passed: guix-minimal -> sys-net`, and
`OPENQA_RC_000012_0`.  This is current evidence that the rebuilt template's
generated Guix client wrapper can download through Qubes' default
`qubes.UpdatesProxy` path when the target service is available.  It remains a
controlled update-target proof, not a public-Internet `guix time-machine` or substitute
download proof.

On May 17, 2026, job 41 reran the controlled stub-download path with the
current helper scripts after tightening the download verifier to reject source
TemplateVMs with direct IPv4 or IPv6 default routes:

```text
id: 41
BUILD: guix-minimal-rpm-r202605171259-stub-nodirect-e7566e7-202605171704
TEST: guix_template
state: done
result: passed
template: guix-minimal
QEMURAM: 24576
```

The serial log showed RPM install success, postinstall diagnostics success,
TemplateVM/AppVM smoke success, and generated Guix proxy configuration success.
The update-path markers were `checking source TemplateVM has no direct default
route`, `raw proxy probe passed: HTTP/1.1 200 OK`, `downloaded 2 bytes`,
`guix update proxy download check passed`, and `guix update proxy stub download
check passed: guix-minimal -> sys-net`.  This is controlled update-target proof
for the rebuilt minimal artifact plus the no-direct-network guard.  It still
does not prove public Internet downloads, substitutes,
`guix time-machine`, or refresh-enabled central `qubes-vm-update`.

On May 18, 2026, job 44 reran the controlled stub-download path from current
commit `d508939` after making runtime `/var/run/qubes*` setup idempotent for
already-running service commands:

```text
id: 44
BUILD: guix-minimal-rpm-current-d508939stub-24g
TEST: guix_template
state: done
result: passed
template: guix-minimal
QEMURAM: 24576
RPM SHA256: 7e092e73681286e4111779282657e7fe6b0d370c1e66b5ea7561cb8d04afc52a
```

The serial log showed `OPENQA_RC_000007_0` for RPM install,
`OPENQA_RC_000008_0` and `OPENQA_RC_000009_0` for postinstall diagnostics and
log scanning, `native Guix TemplateVM smoke tests passed for guix-minimal` and
`OPENQA_RC_000010_0` for TemplateVM/AppVM smoke, and
`guix update proxy config check passed` with `OPENQA_RC_000011_0` for generated
proxy configuration.  The update-path markers were `checking source TemplateVM
has no direct default route`, `raw proxy probe passed: HTTP/1.1 200 OK`,
`downloaded 2 bytes`, `guix update proxy download check passed`,
`guix update proxy stub download check passed: guix-minimal -> sys-net`, and
`OPENQA_RC_000012_0`.  A targeted scan of the archived job logs found no
`ln: failed` markers from the updates-proxy forwarder.  This is the current
controlled update-target proof for the public review head.  It still does not
prove public Internet downloads, substitutes, `guix time-machine`, or
refresh-enabled central `qubes-vm-update`.

On May 17, 2026, job 40 reran the same rebuilt minimal RPM with the opt-in
public-network proxy gate enabled and a lower openQA RAM setting so QEMU would
fit on the current worker:

```text
id: 40
BUILD: guix-minimal-rpm-r202605171259-realproxy-24g-202605171610
TEST: guix_template
state: done
result: failed
template: guix-minimal
QEMURAM: 24576
```

This run passed RPM install, postinstall diagnostics, postinstall log scanning,
TemplateVM/AppVM smoke, and generated Guix proxy configuration.  The archived
serial log showed `OPENQA_RC_000007_0`, `OPENQA_RC_000008_0`,
`OPENQA_RC_000009_0`, `OPENQA_RC_000010_0`, and `OPENQA_RC_000011_0`, then
failed the public-network download gate with `OPENQA_RC_000012_1`.  The download
script reported `raw proxy probe did not return HTTP success`, `Request
refused`, and `The guest forwarder reached qrexec-client-vm, but dom0 refused
qubes.UpdatesProxy.`  This confirms again that the rebuilt template reaches the
real-download verifier and that the current nested openQA environment still
lacks an allowed Internet-capable updates-proxy target.  It is not evidence of a
template-side Guix wrapper failure, and it is not a passing public-network Guix
download or `guix time-machine` proof.

On May 18, 2026, the same nested dom0 disk was booted directly with 24G of RAM
after the default 32G helper setting failed to fit on the current worker.  SSH
did not accept the helper key, but the serial console was reachable.  Direct
dom0 inspection showed the exact environment limitation behind the openQA
real-proxy failures:

```text
qvm-ls --fields NAME,CLASS,STATE,TEMPLATE,NETVM,PROVIDES_NETWORK
NAME  CLASS       STATE    TEMPLATE  NETVM  PROVIDES-NETWORK
dom0  AdminVM     Running  -         -      -
guix  TemplateVM  Halted   -         -      False

qvm-check sys-net
qvm-check: sys-net: non-existent!

qvm-pci
dom0:00_03.0  Network: Intel Corporation 82574L Gigabit Network Connection

/etc/qubes/policy.d/90-default.policy:
qubes.UpdatesProxy      *   @type:TemplateVM        @default    allow target=sys-net
```

This is useful negative evidence: the nested dom0 has Qubes' standard
TemplateVM updates-proxy policy shape, but the policy target does not exist.
The emulated network device is still owned by dom0, and this test image has no
network-providing qube to act as the real update target.  Creating a Guix-based
NetVM/ProxyVM or provider-specific dom0 policy override would go beyond the
current TemplateVM/AppVM publication scope, so the real Internet update-proxy
proof still needs a review environment with an ordinary Internet-capable
`sys-net` or equivalent standard update target.

On May 17, 2026, a disposable nested-dom0 run installed a temporary backport of
the `config/qubes-core-admin-linux-guix-vmupdate.example.patch` logic into the
installed Qubes 4.3.20 `vmupdate` package.  The installed dom0 package predates
the current upstream `PackageManager(..., agent_type)` API, so this was a
runtime compatibility backport for validation only, not a replacement for the
upstream `qubes-core-admin-linux` PR branch.

The temporary backport added Guix OS-family detection, installed the Guix
backend under `/usr/lib/python3.13/site-packages/vmupdate/agent/source/guix/`,
and byte-compiled the modified files successfully.  A full central updater run
then selected the Guix backend and failed during refresh:

```text
guix:out: Progress reporting not supported.
guix:out: Refreshing package info
test-guix-central-vmupdate failed: qubes-vm-update failed with status 23
/tmp/qubes-guix-central-vmupdate-guix.2281/update-guix.log:
[Agent] Refreshing failed with code: 1
[Agent] Exiting due to a refresh error. Use --force-upgrade to upgrade anyway.
```

That is useful historical partial evidence: the prior unsupported-OS failure was
removed and central `qubes-vm-update` dispatch reached the Guix backend.  It is
not a passing current-backend central updater run; the external RFC backend now
refreshes with `guix time-machine --branch=master -- describe` and reconfigures
with `guix time-machine --branch=master -- system reconfigure /etc/config.scm`,
so this older `guix pull` failure must be rerun against the current semantics.

The refresh failure was reproduced directly from dom0 with the same proxy
environment that the Guix vmupdate backend injects.  This installed `guix`
template did not contain `/run/qubes/bin/guix`, so the temporary backend fell
back to the system Guix binary.  That is adequate evidence for central updater
dispatch, but weaker than the current rebuilt-image evidence for the generated
Guix client wrapper.

```sh
qvm-run --pass-io --no-gui --user root guix \
  'timeout 150 env http_proxy=http://127.0.0.1:8082/ \
   https_proxy=http://127.0.0.1:8082/ \
   HTTP_PROXY=http://127.0.0.1:8082/ \
   HTTPS_PROXY=http://127.0.0.1:8082/ \
   no_proxy=127.0.0.1,localhost \
   NO_PROXY=127.0.0.1,localhost \
   guix pull --channels=/etc/guix/channels.scm'
```

The command reached Guix's channel update path and failed while fetching the
pinned Guix commit:

```text
Updating channel 'guix' from Git repository at 'https://git.guix.gnu.org/guix.git'...
git-error: unexpected EOF
https://archive.softwareheritage.org/api/1/revision/520785e315eddbe47199ac557e88e60eca3ae97c/
guix/ui.scm:920:18: Bad Read-Header-Line header: #<eof>
```

This narrows the remaining refresh problem to the Guix network fetch path
through the Qubes updates proxy in this nested environment.  It is not evidence
of a central-updater OS-family dispatch failure.

The same proxy path also failed with a simpler Guix HTTPS download:

```sh
qvm-run --pass-io --no-gui --user root guix \
  'timeout 60 env http_proxy=http://127.0.0.1:8082/ \
   https_proxy=http://127.0.0.1:8082/ \
   guix download https://archive.softwareheritage.org/api/1/'
```

The guest had no `curl` or `wget`; `guix download` itself reported:

```text
Starting download of /tmp/guix-file.t3HPie
From https://archive.softwareheritage.org/api/1/...
Bad Read-Header-Line header: #<eof>
From https://web.archive.org/web/20260517091209/https://archive.softwareheritage.org/api/1/...
Bad Read-Header-Line header: #<eof>
guix download: error: https://archive.softwareheritage.org/api/1/: download failed
```

This confirms the remaining refresh blocker is reproducible with Guix's HTTPS
download path through the nested Qubes update proxy.  The controlled HTTP stub
download evidence from job 31 remains valid, but it is not equivalent to this
public HTTPS/Guix fetch case.

The wrapper path distinction was checked explicitly:

```text
lrwxrwxrwx ... /run/current-system/profile/bin/guix -> /gnu/store/...-guix-1.5.0-1.deedd48/bin/guix
ls: cannot access '/run/qubes/bin/guix': No such file or directory
```

So this central-updater run should not be treated as proof that the current
generated `/run/qubes/bin/guix` wrapper handles public HTTPS Guix update
tooling.

A bounded follow-up run skipped refresh and exercised the central updater's Guix
reconfigure path:

```sh
qubes-vm-update --targets guix --force-update --max-concurrency 1 \
  --show-output --no-progress --no-refresh
```

It reached the Guix backend and reported no installed, updated, or removed
packages:

```text
guix:out: Progress reporting not supported.
guix:out: Installed packages:
guix:out: None
guix:out: Updated packages:
guix:out: None
guix:out: Removed packages:
guix:out: None
```

The command exited with status `2`, matching the no-updates path rather than the
previous unsupported-OS or refresh-failure path.  This historical run proved
central updater dispatch and no-refresh backend execution in the nested dom0;
later job 129 superseded it for the passing refresh/reconfigure path.  A
publication-branch or release-tag rerun is still required.

## Not Yet Passed

The following gates remain open and must not be claimed as passing from this
snapshot:

- Final publication evidence still needs a fresh central `qubes-vm-update` run
  from the exact publication branch or release object.  Job 129 is passing proof
  for the current review artifact, but public Guix Git and substitute
  availability are external variables, as shown by job 133 failing on HTTP 504
  after the Qubes update-proxy path had already been proven reachable.
- The opt-in public-network `scripts/test-guix-update-proxy-download-dom0.sh`
  gate still needs a passing run from the publication branch or release object.
  The central update path has now proven `guix time-machine` through a standard
  Qubes update target, while the standalone public `guix download` gate remains
  separate release evidence.
- Final publication-branch or release-tag reruns of the rootfs build, image
  inspection, activation tests, RPM packaging, qvm-template lifecycle checks,
  and RPM-mode openQA.
- Full Qubes Builder v2 prep/build/sign/publish/upload acceptance of a Guix
  distribution/template path.
- Qubes maintainer review and publication in `templates-community-testing`.
