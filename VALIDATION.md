# Validation Snapshot

This file records accumulated validation evidence for the native GNU Guix
System Qubes TemplateVM prototype.  It is evidence for review discussion, not
proof that Qubes has accepted or published the template.

## Evidence Scope

The normal/minimal rootfs and RPM evidence below is a release-build snapshot
from May 15, 2026.  It shows the build path has worked for this review effort,
but it is not a substitute for fresh release evidence from the final signed
public branch.  Later commits may update review documentation,
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
service-state verifier.  A later RPM-mode openQA run passed a controlled
`guix download` through the generated wrapper and stock Qubes default-target
policy using a temporary `sys-net` stub.  Final signed-branch reruns and real
Guix update tooling through an Internet update target still remain open.

## Current HEAD Contract Checks

The current tree passed the local artifact checks and the Guix-capable GCP
system-contract check after the May 17, 2026 audit refresh.  The latest GCP
rerun archived commit `e475c2b` after the unused qrexec fork-server Shepherd
service was removed.  Later commits after `e475c2b` are documentation,
evidence, or history-map updates; they do not change the Guix system records or
Scheme services covered by that GCP run.

Local artifact check:

```sh
make check
```

GCP Guix system-contract check:

```sh
make guix-system-contract-check
```

`make check` currently runs `tests/builder-hook-contract-check.sh`,
`tests/builder-rpm-contract-check.sh`, and `tests/rpm-layout-check.sh`.
The default suite does not include source-text, patch-shape, or
release-config-fragment checks as substitute evidence.  Tests in this suite
must exercise generated artifacts or Qubes-visible contracts.
The Builder hook contract check
executes the Builder v2 hooks against a temporary install tree.  The Builder
RPM contract check feeds generated ext4 root images through
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
on the GCP review builder after adding the check, then rerun at commit
`e475c2b`, and passed with:

```text
./tests/guix-system-contract-check.sh
Guix system contract check passed
```

That check instantiates the normal and minimal `operating-system` records with
real Guix and asserts standard Qubes/Guix system contracts: `/dev/xvdc1` swap,
the standard `user` account with Qubes group membership, unchanged Guix default
privileged programs, passwordless `wheel` and `user` sudo, required Qubes
services, and default `meminfo-writer` configuration.

No source-only checker is part of the validation evidence or the repository
test suite.  Formatting, parser-only, inventory, or patch-shape commands are
manual maintainer chores, not release gates, and should not be submitted as
substitutes for artifact, Guix system-record, dom0, or openQA evidence.

Earlier targeted Scheme-load evidence is kept here for traceability.  After
aligning the updates-proxy wrapper with Qubes' current
`--use-stdin-socket` command, the touched Scheme file was synced to the GCP
builder checkout and loaded with real Guix:

```sh
cd /home/sandbox/guix-review-current
guix repl -L /home/sandbox/guix-review-current/native/modules -- /dev/stdin
```

The REPL loaded `(qubes packages qubes-vm)`, `(qubes services qubes-vm)`, and
`native/qubes-guix.scm`, then printed the expected `qubes-vm-core` package
version:

```text
4.3.42
```

After adding `qubes-guix-update-proxy-service-type`, the then-current tree was
synced to the same GCP builder and both operating-system variants were
constructed with real Guix:

```sh
cd /home/sandbox/guix-review-current
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
upstream `qubes-builderv2` sources on May 17, 2026, at commit `ff36320`; the
same upstream commit was rechecked after local commit `c64b789`:

```sh
rm -rf /tmp/qubes-builderv2-current
git clone --depth 1 https://github.com/QubesOS/qubes-builderv2.git \
  /tmp/qubes-builderv2-current
git -C /tmp/qubes-builderv2-current apply \
  /home/user/guix/config/qubes-builderv2-guix.example.patch
PYTHONPATH=/tmp/qubes-builderv2-current \
  python -m pytest \
    /tmp/qubes-builderv2-current/tests/test_objects.py::test_dist \
    /tmp/qubes-builderv2-current/tests/test_objects.py::test_dist_family \
    /tmp/qubes-builderv2-current/tests/test_objects.py::test_template_plugin_supports_guix
```

Result:

```text
3 passed in 0.11s
```

The release-config sketch also passed an applied-config YAML validation in a
fresh shallow checkout.  The latest refresh used current upstream
`qubes-release-configs` sources on May 17, 2026, at commit `e7ad66d`; the same
upstream commit was rechecked after local commit `c64b789`:

```sh
rm -rf /tmp/qubes-release-configs-current
git clone --depth 1 https://github.com/QubesOS/qubes-release-configs.git \
  /tmp/qubes-release-configs-current
git -C /tmp/qubes-release-configs-current apply \
  /home/user/guix/config/qubes-release-configs-guix.example.patch
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

The review source tree was also copied to the GCP builder as
`~/guix-review-current`.  On May 17, 2026, both the current local review tree
and the synced GCP review checkout passed the network-dependent Qubes pin
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

The pinned Guix channel in `config/channels.scm` was resolved on the GCP builder
with:

```text
guix 520785e
  repository URL: https://git.guix.gnu.org/guix.git
  branch: master
  commit: 520785e315eddbe47199ac557e88e60eca3ae97c
```

The rootfs builder's pinned-channel policy was also checked locally after
commit `2b6f5c1`: a temporary repo copy without `config/channels.scm` and with a
fake `guix` in `PATH` failed before mount/image work with:

```text
error: missing pinned Guix channels file: .../config/channels.scm; set GUIX_CHANNELS_FILE or explicit developer-only GUIX_BRANCH
```

This verifies that release builds no longer silently fall back to an unpinned
Guix branch when the pinned channel file is absent.

## Latest GCP Minimal Release Build Snapshot

- Date: 2026-05-15.
- Remote builder: `qubes-guix-dev-0508` in GCP zone `us-east1-d`.
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

## Latest GCP Normal Release Build Snapshot

- Date: 2026-05-15.
- Remote builder: `qubes-guix-dev-0508` in GCP zone `us-east1-d`.
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
- Remote builder: `qubes-guix-dev-0508` in GCP zone `us-east1-d`.
- Nested dom0: Qubes R4.3.0, booted from
  `/home/sandbox/qubes-nested/vm/qubes-r4.3.0.qcow2`.
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

On May 16, 2026, the then-current review commit was copied to the GCP nested
builder as `/home/sandbox/guix-review-61f66bb`.  Nested dom0 was started with
the existing data image:

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
- Release-build source: local commit
  `40fae59 Add Qubes upstream review scaffolding`.
- Remote builder: `qubes-guix-dev-0508` in GCP zone `us-east1-d`.
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
minimal variant was smoke-tested on the GCP builder by creating a blank 20G
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
  tests/test_objects.py::test_dist \
  tests/test_objects.py::test_dist_family \
  tests/test_objects.py::test_template_plugin_supports_guix \
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

On May 16, 2026, the current working tree was synced to the GCP builder
`qubes-guix-dev-0508` in zone `us-east1-d` after changing the
`qubes-updates-proxy-forwarder` Shepherd requirement from qrexec/network
services to `qubes-sysinit`, matching Qubes' socket-activated model more
closely.  The builder produced and activation-tested:

```text
/home/sandbox/guix-review-current/root-update-proxy.img
/home/sandbox/guix-review-current/dist/qubes-template-guix-4.3.0-2026051602.noarch.rpm
```

The RPM was installed and reinstalled through nested dom0's Template Manager
path:

```sh
cd /home/user
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
cd /home/user
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

On May 16, 2026, the GCP openQA host `qubes-guix-dev-0508` in zone
`us-east1-d` ran the RPM-mode openQA harness against the 2026051602 normal and
minimal template RPMs.  The harness used
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

This is current release-review evidence for the RPM install path.  It is still
not a substitute for rerunning openQA from the final signed public branch or
tag that Qubes reviewers are asked to evaluate.

On May 16, 2026, job 27 reran the minimal RPM-mode path from a rebuilt image
that includes the current updates-proxy forwarder and verifier changes:

```text
id: 27
BUILD: guix-minimal-rpm-r202605162304-proxyfix-202605162312
TEST: guix_template
state: done
result: passed
root image: /home/sandbox/guix-review-current/root-minimal-r202605162304.img
root image size: 20G
RPM: /home/sandbox/guix-review-current/dist/qubes-template-guix-minimal-4.3.0-202605162304.noarch.rpm
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
root image: /home/sandbox/guix-review-current/root-minimal-r202605162304.img
RPM: /home/sandbox/guix-review-current/dist/qubes-template-guix-minimal-4.3.0-202605162304.noarch.rpm
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
root image: /home/sandbox/guix-review-current/root-minimal-r202605162304.img
RPM: /home/sandbox/guix-review-current/dist/qubes-template-guix-minimal-4.3.0-202605162304.noarch.rpm
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
Internet downloads, `guix pull`, or substitute downloads through a real
update-proxy target.

## Not Yet Passed

The following gates remain open and must not be claimed as passing from this
snapshot:

- End-to-end Guix update tooling through a real Internet update-proxy target
  remains untested.  The default-target HTTP forwarding gate is covered by the
  2026051602 nested-dom0 run above, RPM-mode openQA job 27 passed
  `scripts/test-guix-update-proxy-config-dom0.sh` for the generated
  daemon/client proxy configuration, and job 31 passed
  `scripts/test-guix-update-proxy-stub-download-dom0.sh` for a controlled
  `guix download` through a temporary `sys-net` stub target.  Job 29 reached the
  public-network `scripts/test-guix-update-proxy-download-dom0.sh` gate and
  failed on dom0 `qubes.UpdatesProxy` refusal in the nested openQA environment.
  This snapshot does not yet contain a passing run of that public-network gate
  or prove that `guix pull`, substitute downloads, or channel updates consume a
  real Internet update-proxy target as intended.
- Final signed-branch or signed-tag reruns of the rootfs build, image
  inspection, activation tests, RPM packaging, qvm-template lifecycle checks,
  and RPM-mode openQA.
- Full Qubes Builder v2 prep/build/sign/publish/upload acceptance of a Guix
  distribution/template path.
- Qubes maintainer review and publication in `templates-community-testing`.
