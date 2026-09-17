# Tech Brief: Phase M1 — Malcolm Deployment (DONE 2026-09-16)

Reproducible record of deploying Malcolm (26.08.0) on `soc-host` (192.168.2.51) with live capture on the mirror NIC. All 26 containers healthy; web UI, Arkime, and capture verified.

## 1. Prerequisites (M0 carried over)

- soc-host VM (400): 8 vCPU / 16GB / 200GB, Fedora Cloud Base 43
- Mirror NIC `ens19` on `vmbr1`: IP-less, promisc, offloads off (dispatcher script persists)
- **`cpu: host`** on VM 400 — REQUIRED. The default KVM CPU model exposes only `cx16`/`lahf_lm` (no SSE4/POPCNT/AVX), which breaks x86-64-v2 images. Set via `qm set 400 --cpu host`.

## 2. Install

```bash
# deps
dnf install -y git docker docker-compose-plugin
systemctl enable --now docker; usermod -aG docker socadmin

# kernel tuning (Malcolm docs)
cat > /etc/sysctl.d/99-malcolm-performance.conf << EOF
fs.file-max=2097152
fs.inotify.max_user_watches=131072
fs.inotify.max_queued_events=131072
fs.inotify.max_user_instances=512
vm.swappiness=1
vm.max_map_count=524288
vm.dirty_background_ratio=5
vm.dirty_ratio=10
vm.overcommit_memory=1
EOF
sysctl --system

# clone + configure
git clone --depth 1 https://github.com/cisagov/Malcolm.git /opt/Malcolm
chown -R socadmin:socadmin /opt/Malcolm
# NOTE: run install.py directly, NOT the `configure` symlink (it forces config-only mode)
sudo -u socadmin python3 scripts/install.py --non-interactive --load-existing-env --skip-splash
sudo -u socadmin python3 scripts/auth_setup --auth-noninteractive --auth-method basic
htpasswd -bc /opt/Malcolm/nginx/htpasswd admin '<CONPASS>'
```

## 3. Critical fixes (all required on this host)

| # | Fix | Why |
|---|---|---|
| 1 | **`cpu: host`** on VM 400 | Default KVM CPU lacks SSE4/POPCNT/AVX → x86-64-v2 images crash |
| 2 | **Filebeat 9.4.2 pin** (`malcolm/filebeat-patch.sh`) | `filebeat-oss:9.5.2` uses UBI 10 (requires AVX2). Wolfi swap BREAKS the build (Malcolm's Dockerfile uses microdnf, wolfi uses apk). Pin to `filebeat-oss:9.4.2` (UBI 9, no AVX2) |
| 3 | **`PUID=1000`/`PGID=1000`** in `config/process.env` | Default `PUID=0` makes containers run as root → "cannot run as superuser" (OpenSearch, Logstash, Dashboards) |
| 4 | **Remove `read_only: true`** from opensearch service | Read-only root breaks usermod home-dir chown → container runs as root |
| 5 | **`INTERNAL_PASSWORD`** in `config/opensearch.env` + matching `.opensearch.primary.curlrc` | OpenSearch security plugin needs the internal user password |
| 6 | **Keystore + data dir ownership** (`chown socadmin:socadmin /opt/Malcolm/opensearch`) | Root-owned keystore/data → AccessDenied / node-lock failures |
| 7 | **Enable live capture** | `ZEEK_LIVE_CAPTURE=true`, `SURICATA_LIVE_CAPTURE=true`, `ARKIME_LIVE_CAPTURE=true` in the `*-live.env` files |
| 8 | **Recreate containers after fixes** | Containers started before the fixes keep the old (broken) config — `docker rm -f` + `docker compose up -d <svc>` |

## 4. Verification

- **All 26 containers healthy** (`docker ps` — 26/26)
- **Web UI:** `https://192.168.2.51/` (admin / CONPASS) → HTTP 200; `/arkime` → 200; `/dashboards` → 302
- **Capture:** Suricata-live 191 alerts; Zeek conn.log 293+ lines; Arkime `arkime_sessions3-260916` 4466 docs
- **Data flow:** Zeek/Suricata → Logstash (`malcolm-zeek` in=8800, `malcolm-suricata` in=1007) → enrichment → Arkime sessions
- **Filebeat:** healthy (9.4.2 pin works — no AVX2 crash)

## 5. Optional ingestion features (enabled 2026-09-16)

The `filebeat-nginx`, `filebeat-syslog-tcp`, `filebeat-syslog-udp`, and `filebeat-tcp` instances are gated by env vars (default `false`). **Enabled for the homelab** (home-network-only threat surface):

- `nginx.env: NGINX_LOG_ACCESS_AND_ERRORS=true` → filebeat-nginx (watches `/nginx`)
- `filebeat.env: FILEBEAT_SYSLOG_TCP_LISTEN=true` + `FILEBEAT_SYSLOG_TCP_PORT=514`
- `filebeat.env: FILEBEAT_SYSLOG_UDP_LISTEN=true` + `FILEBEAT_SYSLOG_UDP_PORT=514`
- `filebeat.env: FILEBEAT_TCP_LISTEN=true` + `FILEBEAT_TCP_PORT=5045`

**Ports published to host** (added to `docker-compose.yml` filebeat service — **re-apply after Malcolm updates**):
```yaml
ports:
  - "514:514/udp"
  - "514:514/tcp"
  - "5045:5045/tcp"
```

**Verified:** all 4 instances RUNNING; nginx logs flowing (`malcolm_beats_nginx_260916` 60 docs); syslog UDP test landed (`malcolm_beats_syslog_260916` 1 doc).

## 6. Next steps

- M2: Overlap with SO for a few days, cross-check Suricata/Zeek parity
- M3: Deploy Wazuh (manager + indexer + dashboard) on soc-host
- Investigate the filebeat-logs beats pipeline issue