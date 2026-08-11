# 92-small-team-relay — Dylan action items

Do not place credentials, APNs keys/tokens, VPN keys, recovery material, VPS passwords, or real transcript content in this repository or `qa-runs/`.

## Before committing/arming the program

- [ ] Resolve the preserved queue-91 P4.6 dirty candidate at `~/.pi/agent-tile-ux-runs/continuum-overnight/run-20260730T225228/`; accept/repair/commit it or deliberately discard it through that program's recovery procedure. Do not reset/clean it casually.
- [ ] Let queue 91 reach a clean stop/drain point before starting the relay loop; the two loops must never write this checkout concurrently.
- [ ] Review `_DESIGN.md`, `_QUEUE.md`, and representative packets for scope/priority.
- [ ] Review and commit the program preparation separately. Until committed, the relay loop correctly refuses the dirty tree.
- [ ] Decide whether implementation remains on `overnight/agent-ux` or moves to a dedicated branch. If changed, update the runbook/control default before arming—never branch-switch while another loop owns the checkout.
- [x] Explicitly approve the repository decision that supersedes blanket I5 for typed/authenticated Class-B content while preserving Class-C host-only secrets. Approved by starting the companion catch-up plan on 2026-08-10; P0 still owns the repository lock/check implementation.

## Required by P3.10 transport/security review

- [ ] Choose the first relay host:
  - existing office Mac mini/Linux/NAS; or
  - an approximately $5/month VPS whose actual current price/region/storage/traffic/backup terms you approve.
- [ ] Set a monthly infrastructure ceiling and decide whether a few dollars over $5 is acceptable for backups/storage.
- [ ] Choose the first route: existing WireGuard/VPN, licensed private mesh, LAN-only milestone, or public TLS/reverse proxy.
- [ ] If public, choose domain/subdomain, DNS owner, TLS termination, firewall/patching owner, and whether provider TLS visibility of Class-B content is acceptable.
- [ ] Choose default workspace privacy: private/invite-only (recommended) or office-wide shared.
- [ ] Choose encrypted backup destination and retention owner. It must be off the relay disk/machine.
- [ ] Choose recovery-key custody: password manager, offline encrypted media, or another explicit protected location. Decide who besides Dylan may recover/revoke the relay.
- [ ] Provide access to the selected host privately; do not paste access material into tickets.

## Required by P4.9 physical iPhone review

- [ ] Provide one physical iPhone and a verified signing/provisioning path.
- [ ] If APNs is in scope, provide `.p8`, Key ID, Team ID, bundle/topic, and sandbox/production choice through protected local secret storage—not source or shell history.
- [ ] Decide iPhone cache policy after device/credential revocation: immediate erase or retained encrypted read-only cache for a bounded period.
- [ ] Decide lock-screen notification wording and whether agent/workspace names are safe to show.
- [ ] Be available to approve pairing fingerprint, background/foreground, app-switcher privacy, transcript/control behavior, and correction packets.

## Required by P5.7 final acceptance

- [ ] Provide/approve the actual deployment machine, service user, firewall/private route, storage quota, and maintenance window.
- [ ] Provide an external witness device (phone or independent host) for explicit Sleep/lid-close/wake tests.
- [ ] Approve active-turn idle-sleep policy: plugged-in default, per-machine opt-in, or never.
- [ ] Run/observe an encrypted backup restore into isolated replacement storage and confirm custody of recovery material.
- [ ] If Linux/VPS is advertised, provide a real Linux environment for build, process, restart, filesystem, and systemd smoke—not only source scans.
- [ ] Review the target-host capacity/soak report and actual monthly cost.
- [ ] Approve the security review, operational burden, and legacy relay removal.
- [ ] Decide who owns updates, certificate/domain renewal, backup alerts, disk/quota cleanup, and incident response after rollout.

## Optional later decisions—not blockers for initial private release

- [ ] Whether end-to-end content encryption is needed when relay/TLS provider trust becomes uncomfortable.
- [ ] Whether Cloudflare Tunnel/public onboarding is worth the provider dependency.
- [ ] Whether organization SSO, public multi-tenancy, hosted accounts, HA, or managed discovery are ever justified by real demand.
