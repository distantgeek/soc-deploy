# Agent Notes — soc-deploy

Notes for future agent sessions working in this repo.

## Current direction (2026-09-16)

**Migrating off Security Onion** → **Malcolm (CISA/INL, Apache 2.0) for network monitoring + Wazuh for host EDR**. SO's API Clients are Pro-paywalled. Malcolm bundles the same stack (Arkime + Zeek + Suricata + OpenSearch + Dashboards) pre-integrated. See `docs/MIGRATION-PLAN.md`. Phase 0 (SO) is complete; network monitoring carries over. Migration is low-risk (little data) and not time-critical.

**Malcolm update hook (auto-heal):** Malcolm's `filebeat-oss:9.5.2` uses UBI 10 (requires AVX2 — crashes on the Ivy Bridge host). Scripts in `malcolm/`: `filebeat-patch.sh` (wolfi swap + rebuild), `malcolm-update.sh` (safe update wrapper), `malcolm-filebeat-check.sh` + systemd timer (auto-heal). Deploy to `/usr/local/sbin/` + `/etc/systemd/system/`.

**network-engineer subagent:** available in opencode (deepseek-v4-pro) for topology/mirror/IPS/capture review during M0–M2.

## Open items / revisit later

- **`so-capture` systemd service (DEFERRED 2026-09-16):** the per-endpoint capture helper at `/usr/sbin/so-capture` is on-demand only (start/stop via sudo). Revisit when persistent captures are needed — wrap it in a systemd service (or a `systemd-run --unit=...` wrapper) so captures survive reboots. See `docs/TECH-BRIEF-PHASE0.md` §6.2.

## Environment facts

- SO VM: `ssh -i ~/.ssh/id_ed25519_so socadmin@192.168.2.50`; **sudo password = `CONPASS`** in `.env`
- PVE: `ssh -i ~/.ssh/id_ed25519_pve_opencode root@192.168.2.2`
- SO console: `https://192.168.2.50` — login user is **`socadmin@distantgeek.net`** (Kratos identity). **The console password is NOT CONPASS** (CONPASS is sudo only; Kratos rejects it — confirmed in kratos.log). Console password is unknown to agents; ask the user.
- Monitor sniffing bridge: `vmbr1` on PVE with `nic1` (mirror ingress). **MAC learning is disabled on `nic1`** (`post-up bridge link set dev nic1 learning off` in `/etc/network/interfaces`) — required so the bridge floods the mirror feed to the SO VM's `tap300i1`. Do not re-enable learning.
- Suricata PCAP cap: 10GB (`max-files: 10`), set via `suricata.pcap.maxsize: 10` in `/opt/so/saltstack/local/pillar/minions/so-socdeploy_standalone.sls`
- Per-endpoint capture: `sudo so-capture start|stop|stop-all|status <host-or-ip> [hours]` → `/nsm/pcapout/<ip>/`
- ES retention: 90d (DLM); disk watermarks 80/85/90%; NSM/root disk alarms WARN >90% / CRIT >95%

## API access — PAYWALLED (Pro license required)

- SO's **API Clients** (OAuth2 client credentials at `/oauth2/token`) require a **Security Onion Pro license + Hydra enabled**. This deployment is free tier (`license.sls` → `features: []`), no Hydra container → **API auth is unavailable**.
- The SOC API (`/api/*`) needs a Kratos session cookie, which requires the console password (unknown to agents).
- **Workaround for rule tuning:** write directly to ES (see below).

## Direct ES manipulation technique (rule tuning without the API)

Detection documents live in ES index **`so-detection`** (73k+ docs). ES creds in `/opt/so/conf/elasticsearch/curl.config` (readable via sudo).

Schema (verified 2026-09-16):
- Doc = `{ "so_detection": { ...Detection... }, "so_kind": "detection", "@timestamp": ... }`; ES `_id` = detection UUID
- `so_detection.publicId` = Suricata SID; `so_detection.overrides` = array (null if none)
- Suppress override: `{"type":"suppress","isEnabled":true,"note":"...","createdAt":"<RFC3339>","updatedAt":"<RFC3339>","track":"by_src","ip":"192.168.2.148"}` — must NOT include regex/value/thresholdType/count/seconds/customFilter (validation rejects them)
- Partial update: `POST /so-detection/_update/<_id>` body `{"doc":{"so_detection":{"overrides":[<override>]}}}` (arrays replaced wholesale)

After writing overrides to ES, the threshold file must be updated manually (sync is API/UI-triggered): write `suppress gen_id 1, sig_id <sid>, track by_src, ip <ip>` lines to `/opt/so/conf/suricata/threshold.conf` (mounted into container) and `docker restart so-suricata`. Future syncs regenerate the same rules from ES (persistent).

**Applied 2026-09-16:** 16 SIDs suppressed for TrueNAS (192.168.2.148): `2102181 2008581 2010144 2008585 2008582 2008583 2008584 2010139 2010140 2010141 2010142 2010143 2102180 2000357 2000369 2027757`. Backup: `/tmp/so-detection-backup.json` on VM.