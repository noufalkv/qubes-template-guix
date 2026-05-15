# GNU Guix Template for Qubes OS - Research Note

Date: 2026-05-08

Status: historical research note, superseded by the implemented native
TemplateVM prototype and review documents.  The current review and release
status is in `UPSTREAMING.md`, `REVIEW_NOTES.md`,
`ADAPTATION_INVENTORY.md`, `VALIDATION.md`, and `SUBMISSION_AUDIT.md`.  Treat
this file as background context only; do not use it as the authoritative
upstream submission plan.

## Executive Conclusion

There are two different deliverables that people can mean by "a GNU Guix
template for Qubes OS":

1. A normal Qubes Linux template, such as Debian/Fedora/Arch, with the Guix
   package manager installed inside it.
2. A native Guix System TemplateVM, where PID 1, system services, package
   management, and the root filesystem are Guix-built.

The first path is straightforward and should be the near-term usable option.
The second path is feasible, but it is not just a rootfs conversion. It requires
porting the Qubes VM agent stack to Guix packaging and mapping the current
systemd-oriented Qubes service graph to GNU Shepherd services.

Recommended implementation strategy:

1. Build a "Guix-on-Debian-minimal" or "Guix-on-Fedora-minimal" template first
   if the immediate goal is to use Guix packages in Qubes.
2. Build a native Guix System TemplateVM as a staged port:
   headless AppVM first, then GUI, then TemplateManager packaging, then NetVM
   features.
3. Keep the first native target intentionally small: x86_64, Qubes R4.3,
   AppVM-only, dom0-provided kernel, no NetworkManager/NetVM support until
   qrexec, QubesDB, /rw persistence, and GUI are solid.

## Source Anchors

Primary online sources used:

- Qubes supported releases:
  https://doc.qubes-os.org/en/latest/user/downloading-installing-upgrading/supported-releases.html
- Qubes template implementation:
  https://doc.qubes-os.org/en/latest/developer/system/template-implementation.html
- Qubes qrexec documentation:
  https://doc.qubes-os.org/en/latest/developer/services/qrexec.html
- Qubes Builder v2 documentation:
  https://doc.qubes-os.org/en/latest/developer/building/qubes-builder-v2.html
- Qubes Template Manager documentation:
  https://doc.qubes-os.org/en/latest/developer/system/template-manager.html
- Guix manual, `guix system`:
  https://guix.gnu.org/manual/devel/en/html_node/Invoking-guix-system.html
- Guix manual, binary installation on a foreign distribution:
  https://guix.gnu.org/manual/devel/en/html_node/Binary-Installation.html
- Guix manual, Shepherd services:
  https://guix.gnu.org/manual/devel/en/html_node/Shepherd-Services.html

Local Qubes source evidence on this machine:

- `/home/user/qubes-opt/repos/qubes-core-agent-linux`
- `/home/user/qubes-opt/repos/qubes-core-qrexec`
- `/home/user/qubes-opt/repos/qubes-core-qubesdb`
- `/home/user/qubes-opt/repos/qubes-gui-agent-linux`
- `/home/user/qubes-opt/repos/qubes-linux-utils`

The local source trees currently have no Guix or Shepherd integration files.
They do have RPM, Debian, and Arch packaging.

## Qubes Template Requirements

A Qubes TemplateVM is not only a bootable Linux root filesystem. It must fit
Qubes volume and agent semantics:

- Qubes uses a root volume from the template, private per-qube state, and
  volatile runtime state.
- The VM side needs QubesDB, qrexec, GUI agent, RPC service scripts, service
  environment files, and Qubes-specific startup ordering.
- Common Qubes Linux agents expect fixed paths such as `/usr/lib/qubes`,
  `/etc/qubes-rpc`, `/run/qubes-service`, `/var/run/qubes-service-environment`,
  `/rw`, `/home`, and `/usr/local`.
- Template packaging should eventually integrate with Qubes Template Manager,
  not only a one-off root image import.

The local Qubes source confirms the current Linux agent startup graph is
systemd-first. `qubes-core-agent-linux/vm-systemd/75-qubes-vm.preset` enables
core services such as `qubes-sysinit.service`, `qubes-db.service`,
`qubes-gui-agent.service`, `qubes-qrexec-agent.service`,
`qubes-mount-dirs.service`, and `qubes-bind-dirs.service`. The qrexec service
unit starts `/usr/lib/qubes/qrexec-agent`, the QubesDB unit starts
`/usr/bin/qubesdb-daemon 0`, and the GUI unit starts `/usr/bin/qubes-gui`.

## Guix-Specific Friction Points

### 1. Init System Mismatch

Guix System uses GNU Shepherd, while the Qubes Linux agent stack is currently
packaged around systemd units. The core-agent tree includes some SysV init
scripts, but qrexec, QubesDB, and GUI integration still ship systemd units in
the local source tree.

Native Guix work therefore needs Shepherd services for at least:

- `qubes-db`
- `qubes-sysinit`
- `qubes-mount-dirs`
- `qubes-bind-dirs`
- `qubes-misc-post`
- `qubes-qrexec-agent`
- `qubes-gui-agent`
- optional network/update/firewall services later

The service ordering should start with QubesDB, then sysinit, then persistent
mount/bind setup, then qrexec and GUI.

### 2. Guix Store vs Fixed Qubes Paths

Guix packages normally install into immutable `/gnu/store/...` prefixes and
are exposed through profiles and system generations. Qubes scripts and dom0
integration expect conventional fixed paths.

Practical options:

- Patch Qubes components to resolve all paths from Guix store locations.
- Keep upstream paths and add Guix activation code that creates stable symlinks
  or wrappers at `/usr/lib/qubes`, `/etc/qubes-rpc`, and related locations.
- For the first prototype, prefer stable compatibility paths. That minimizes
  changes to qrexec service scripts and Qubes RPC handlers.

This is not purely cosmetic. The local qrexec unit hardcodes
`/usr/lib/qubes/qrexec-agent`, and `qubes-core-agent-linux/init/functions`
checks for qrexec by searching `/usr/lib/qubes`.

### 3. Package Availability

I did not find existing Guix package definitions for the Qubes VM agents in the
local checkout or current package-search results. Expect to create Guix package
definitions for the VM-side components.

Suggested initial package order:

1. Xen/vchan support from `qubes-core-vchan-xen`
2. QubesDB VM daemon and client tools from `qubes-core-qubesdb`
3. qrexec VM tools from `qubes-core-qrexec`
4. core VM scripts/services from `qubes-core-agent-linux`
5. GUI common and GUI agent from `qubes-gui-common` and
   `qubes-gui-agent-linux`
6. Optional integrations after the base works: split-gpg, u2f, USB proxy,
   input proxy, notification proxy, app menus, file manager plugins

### 4. Image Construction

For Qubes, the useful artifact is a root filesystem image usable as a Qubes
root volume, not a normal bootable Guix disk image with a bootloader. A first
prototype should use a plain ext4 root image and let Qubes/dom0 provide the
kernel, as regular Linux templates do.

Likely image build flow:

```sh
truncate -s 10G root.img
mkfs.ext4 -F root.img
sudo mount -o loop root.img /mnt/guix-root
sudo guix system init --no-bootloader qubes-guix.scm /mnt/guix-root
sudo umount /mnt/guix-root
```

The exact Guix command should be verified on a host with Guix installed. This
machine does not currently have `guix` in `PATH`.

### 5. Persistence and `/rw`

Qubes templates require special handling for persistent private state:

- `/rw` must be mounted from the private volume.
- `/home` normally comes from `/rw/home`.
- `/usr/local` normally comes from `/rw/usrlocal`.
- Qubes bind-dirs and protected-files behavior should be preserved.

The local `qubes-core-agent-linux` tree already has scripts for these concepts,
but the systemd units need Shepherd equivalents and some scripts branch on
whether PID 1 is systemd.

### 6. Networking and NetVM Features

Do not include NetVM or ProxyVM behavior in milestone 1. Qubes networking pulls
in more assumptions:

- NetworkManager integration
- firewall/iptables/nftables services
- updates proxy and proxy forwarder
- DNS and anti-spoofing setup
- service flags under `/run/qubes-service`

Add these only after qrexec, QubesDB, persistence, and GUI are working.

## Approach A: Guix Package Manager in an Existing Qubes Template

This is the lowest-risk way to get usable Guix functionality inside Qubes.

Plan:

1. Start from an official or community Qubes Debian/Fedora minimal template.
2. Install Guix as a foreign-distribution package manager.
3. Enable `guix-daemon` using that template's native init system.
4. Add users to the Guix build group as required by the Guix installer.
5. Keep the standard Qubes packages responsible for qrexec, GUI, networking,
   updates proxy, and TemplateVM behavior.

Pros:

- Fastest route to a working Guix-enabled Qubes template.
- Qubes integration remains on supported package paths.
- Avoids the systemd-to-Shepherd port initially.

Cons:

- Not a native Guix System.
- The base OS is still Debian/Fedora/Arch.
- Guix does not own PID 1 or the whole system generation.

This path is the right answer if the user goal is "I want Guix packages in
Qubes." It is not the right answer if the user goal is "I want the TemplateVM
itself to be Guix System."

## Approach B: Native Guix System TemplateVM

### Milestone 0 - Build Environment

- Use Qubes R4.3 as the target unless there is a reason to support R4.2.
- Build on a non-dom0 Linux builder.
- Install Guix on the builder.
- Create a Guix channel or local package module, for example
  `qubes/packages.scm` and `qubes/services.scm`.
- Keep Qubes source versions pinned to known commits or release tags.

### Milestone 1 - Headless AppVM Boot

Goal: boot a Guix-based qube and prove QubesDB and qrexec work.

Tasks:

- Package `qubes-core-vchan-xen`, `qubes-core-qubesdb`, and
  `qubes-core-qrexec` for Guix.
- Provide fixed compatibility paths for Qubes binaries and scripts.
- Add Shepherd service for `qubes-db`.
- Add Shepherd service for `qubes-qrexec-agent`.
- Include a normal `user` account and enough base packages for shell access.
- Build root.img with `guix system init --no-bootloader`.
- Import or attach the root image to a test TemplateVM/StandaloneVM.

Success checks:

```sh
qvm-start guix-test
qvm-run --pass-io guix-test 'qubesdb-read /name'
qvm-run --pass-io guix-test 'id && uname -a'
qvm-run --pass-io guix-test 'ls -l /usr/lib/qubes /etc/qubes-rpc'
```

### Milestone 2 - Persistence

Goal: AppVMs based on the template preserve private state correctly.

Tasks:

- Implement Shepherd services for `qubes-sysinit`, `qubes-mount-dirs`, and
  `qubes-bind-dirs`.
- Verify `/rw`, `/home`, `/usr/local`, bind-dirs, and protected-files behavior.
- Verify shutdown/reboot does not dirty template state unexpectedly.

Success checks:

```sh
qvm-create --template guix-template guix-app
qvm-run --pass-io guix-app 'echo ok > ~/qubes-guix-persist-test'
qvm-shutdown --wait guix-app
qvm-start guix-app
qvm-run --pass-io guix-app 'cat ~/qubes-guix-persist-test'
```

### Milestone 3 - GUI

Goal: launch an X application through Qubes GUI.

Tasks:

- Package `qubes-gui-common` and `qubes-gui-agent-linux`.
- Package Xorg dependencies and minimal desktop/session dependencies.
- Add Shepherd service equivalent to `qubes-gui-agent.service`.
- Preserve `/run/qubes-service-environment` handling.

Success checks:

```sh
qvm-run guix-app xterm
qvm-run guix-app 'zenity --info --text=guix-template'
```

### Milestone 4 - Template Packaging

Goal: install the template through normal Qubes mechanisms.

Tasks:

- Produce a `qubes-template-guix` package containing the root image and
  template metadata.
- Integrate with Qubes Builder v2 or the template configuration repository
  rather than relying on manual root image import.
- Verify `qvm-template install`, update, remove, and reinstall behavior.
- Include an update mechanism story. For Guix System, that may be a qrexec
  update RPC that runs `guix pull` and `guix system reconfigure` in the
  TemplateVM.

### Milestone 5 - Networking and Optional Features

Goal: make the template practical as a daily AppVM base, then possibly a NetVM.

Tasks:

- Add network service support for ordinary AppVM networking.
- Add update proxy support.
- Add file copy/move/open integrations.
- Add app menus.
- Only then consider NetVM/ProxyVM roles.

## Shepherd Service Sketch

Initial service graph:

| Shepherd service | Equivalent systemd unit | Notes |
| --- | --- | --- |
| `qubes-db` | `qubes-db.service` | Start early; provides `qubesdb-read`/daemon state. |
| `qubes-sysinit` | `qubes-sysinit.service` | Creates Qubes service environment and early VM config. |
| `qubes-mount-dirs` | `qubes-mount-dirs.service` | Mounts `/rw`, `/home`, `/usr/local` equivalents. |
| `qubes-bind-dirs` | `qubes-bind-dirs.service` | Applies bind-dirs after persistent mounts. |
| `qubes-misc-post` | `qubes-misc-post.service` | Late misc setup after bind/network. |
| `qubes-qrexec-agent` | `qubes-qrexec-agent.service` | Must run reliably or dom0 cannot manage the VM. |
| `qubes-gui-agent` | `qubes-gui-agent.service` | Start after env setup; respect `/qubes-gui-enabled`. |

The first implementation can wrap existing Qubes shell scripts. Later cleanup
can make the Guix services more native.

## Risk Register

High risks:

- Service graph bugs can make the VM unmanageable if qrexec does not start.
- Guix immutable paths conflict with Qubes hardcoded compatibility paths.
- GUI agent dependencies are Xorg/ABI-sensitive.
- Qubes networking has many systemd and NetworkManager assumptions.

Medium risks:

- Template packaging is less forgiving than a manual root image smoke test.
- Guix system generations and Qubes root/private volume semantics may surprise
  users unless update/reconfigure behavior is documented.
- Some Qubes scripts branch on `systemd` detection or call `systemctl`.

Low risks:

- A headless proof of qrexec and QubesDB should be achievable before GUI work.
- Guix-on-Debian/Fedora is immediately practical if native Guix System slips.

## Recommended Next Actions

1. Decide whether the immediate deliverable is Guix packages in Qubes or native
   Guix System.
2. If immediate usability matters, build a Guix-on-Debian/Fedora minimal
   template first.
3. If native Guix System is the goal, start a small Guix channel with package
   definitions for QubesDB and qrexec only.
4. Build a headless root.img and prove `qvm-run --pass-io` works.
5. Add persistence, then GUI, then packaging.

The critical design rule is to treat qrexec and QubesDB as the first milestone,
not the GUI or the template RPM. If those two do not work, Qubes cannot safely
control or inspect the qube.
