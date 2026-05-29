# Security Review Notes

This repository is a TemplateVM build prototype.  It does not ask Qubes to trust
a new dom0 service or a privileged host-side daemon.  The security-sensitive
question is whether the Guix guest image preserves the expected Qubes VM-agent
contracts while translating the Linux distribution integration from systemd/FHS
assumptions to Guix System and Shepherd.

## Trust Boundaries

- dom0 still owns VM creation, qrexec policy, GUI policy, kernel supply, device
  assignment, and template package installation.
- The template root image contains Qubes VM-side agents, Guix packages, and
  compatibility services only.
- The template RPM installs under `/var/lib/qubes/vm-templates/<name>` using
  the same split `root.img.part.NN` payload shape expected by `qvm-template`.
- Guix store paths are immutable, but Qubes VM agents still require stable FHS
  paths such as `/usr/lib/qubes`, `/etc/qubes-rpc`, `/run/qubes`, `/rw`,
  `/home`, and `/usr/local`.  The compatibility services in `modules/qubes/packages.scm`
  create those paths inside the VM only.

## Validation Infrastructure Scope

Integration testing is performed using Qubes OS's existing openQA
infrastructure, which is outside this repository's trust boundary and review
scope.  Local build and artifact validation scripts are not installed into the
TemplateVM image, do not add a new dom0 service, and should not be treated as
part of the runtime trusted computing base of a published Guix template.  They
still need ordinary review before use on a build host because they copy
artifacts and run local test commands.

## Source Integrity

- Qubes VM agent sources are fetched from QubesOS Git repositories by exact
  commit and Guix recursive content hash in `modules/qubes/packages.scm`.
- `scripts/check-qubes-pins.sh` compares the pinned commits with live upstream
  release tags for the intended Qubes release series.
- `config/channels.scm` pins the Guix channel used for release-quality builds.
  That pin is a template-generation input, not installed user/root channel
  state.

## Privileged Guest Behavior

- qrexec and QubesDB run as guest-side services under Shepherd.
- `qubes.PostInstall` is forced to run as root because Qubes post-install hooks
  update root-owned template state and Qubes integration tests expect that
  behavior.
- The standard Qubes `user` account is kept as the primary interactive account,
  with primary group `users` and supplementary `wheel`, `netdev`, `audio`,
  `video`, and `qubes` groups.  This is the expected TemplateVM guest account
  contract, not a Guix-specific privilege model.
- Qubes-style passwordless sudo and default privileged helper behavior are
  treated as compatibility requirements, not new policy invented by this
  template.
- The updates proxy implementation forwards to Qubes `qubes.UpdatesProxy`
  instead of creating an independent network updater.  Guix update operations
  that need the Qubes proxy set an explicit proxy environment; ordinary Guix
  commands are not hidden behind a global wrapper.
- Swap uses `/dev/xvdc1`, and private volume persistence uses the standard
  Qubes `/dev/xvdb -> /rw`, `/rw/home -> /home`, and
  `/rw/usrlocal -> /usr/local` model.

## Review-Sensitive Adaptations

`ADAPTATION_INVENTORY.md` is the detailed map of Guix-specific adaptations.
The highest-risk rows for security review are:

- qrexec PAM selection and qrexec Python path adjustments.
- qrexec `qubes.WaitForSession` replacement for Shepherd.
- QubesDB foreground supervision.
- core-agent post-install and feature reporting changes without systemd.
- updates proxy forwarding.
- GUI startup and Xorg wrapper changes, especially the temporary `-ac`
  compatibility path for the root-owned Xorg/default-user session split.
- FHS compatibility links under `/usr`, `/etc/qubes-rpc`, `/run`, and
  `/var/run`.

Those changes should be kept small and dropped whenever upstream Qubes gains a
native mechanism that removes the Guix-specific need.

## Evidence Boundary

Security review should treat generated artifacts, openQA, qvm-template
lifecycle, and live TemplateVM/AppVM behavior as separate evidence classes.
`VALIDATION.md` records which of those classes are current.  Until the missing
runtime gates are refreshed from the publication source state, this is a
reviewable prototype, not a security-reviewed Qubes community template.
