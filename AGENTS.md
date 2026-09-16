# Agent Notes — soc-deploy

Notes for future agent sessions working in this repo.

## Open items / revisit later

- **`so-capture` systemd service (DEFERRED 2026-09-16):** the per-endpoint capture helper at `/usr/sbin/so-capture` is on-demand only (start/stop via sudo). Revisit when persistent captures are needed — wrap it in a systemd service (or a `systemd-run --unit=...` wrapper) so captures survive reboots. See `docs/TECH-BRIEF-PHASE0.md` §6.2.

## Environment facts

- SO VM: `ssh -i ~/.ssh/id_ed25519_so socadmin@192.168.2.50`; sudo + console password = `CONPASS` in `.env`
- PVE: `ssh -i ~/.ssh/id_ed25519_pve_opencode root@192.168.2.2`
- SO console: `https://192.168.2.50` (login `admin` / CONPASS)
- Monitor sniffing bridge: `vmbr1` on PVE with `nic1` (mirror ingress). **MAC learning is disabled on `nic1`** (`post-up bridge link set dev nic1 learning off` in `/etc/network/interfaces`) — required so the bridge floods the mirror feed to the SO VM's `tap300i1`. Do not re-enable learning.
- Suricata PCAP cap: 10GB (`max-files: 10`), set via `suricata.pcap.maxsize: 10` in `/opt/so/saltstack/local/pillar/minions/so-socdeploy_standalone.sls`
- Per-endpoint capture: `sudo so-capture start|stop|stop-all|status <host-or-ip> [hours]` → `/nsm/pcapout/<ip>/`
- ES retention: 90d (DLM); disk watermarks 80/85/90%; NSM/root disk alarms WARN >90% / CRIT >95%