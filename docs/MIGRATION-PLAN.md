# Migration Plan — Security Onion → Malcolm + Wazuh

Status: DRAFT (2026-09-16). Migration is low-risk (little data); not time-critical.

## 1. Rationale

Security Onion's core (Suricata, Zeek, Elasticsearch, PCAP) is open-source, but the **SOC console's API Clients require a paid Pro license + Hydra**. Programmatic rule tuning is paywalled.

**Target:** **Malcolm** (CISA/INL, Apache 2.0) for network monitoring + **Wazuh** (GPL) for host EDR. Malcolm is the *same* stack the custom plan would assemble (Arkime + Zeek + Suricata + OpenSearch + OpenSearch Dashboards + Logstash) but pre-integrated, with prebuilt dashboards and easy container deployment. Zero paywalls, full API access.

## 2. Platform / function roles

| SO function | SO component | Target replacement | Notes |
|---|---|---|---|
| Network IDS | Suricata | **Malcolm** (bundles Suricata) | Pre-integrated, ET Open rules |
| Network metadata | Zeek | **Malcolm** (bundles Zeek) | 22 log types, pre-parsed |
| PCAP capture/search | suricata pcap-file | **Malcolm** (bundles Arkime) | Session→PCAP search UI, prebuilt |
| SIEM / search store | Elasticsearch | **Malcolm** (bundles OpenSearch) | Single unified store |
| Dashboards | Kibana | **Malcolm** (OpenSearch Dashboards) | Dozens of prebuilt dashboards |
| Host telemetry | Fleet + Elastic Agent | **Wazuh agent** (syscollector, FIM, active response) | Replaces Fleet inventory role |
| osquery | Fleet osquery_manager | **Wazuh osquery integration** (limited) | Partial; Fleet DM (free tier) later if needed |
| Analyst query UI | Hunt | **Malcolm** (OpenSearch Dashboards + Arkime) | Threat hunting deferred |
| Rule management | Detections page | **Suricata rule files** (suricata-update) + Wazuh rules | File-based, salt/ansible-managed |
| Alerting | ElastAlert + Sigma | **OpenSearch Alerting plugin** + Sigma | Gap to fill (see §6) |
| Cases | Cases | **IRIS** (planned Phase 2) | Later phase |
| Threat intel | — | **MISP** (planned) | Later phase |
| DFIR | — | **Velociraptor** (planned) | Later phase |
| Automation | — | **Shuffle** (planned) | Later phase |
| Inline IPS | — | **OPNSense** (Suricata inline) | Phase 4; blocking layer, not another IDS. **No complication adding later** — sits at the network edge, independent of the GS305E backhaul mirror |

## 3. Target architecture

```
Endpoints (DC01, MEMBERSRV01, Workstation, open-atomic, soc-host)
    │  Wazuh agent (FIM, syscollector, active response, osquery)
    ▼
Wazuh manager ──► Wazuh indexer (OpenSearch) ◄── Wazuh dashboard
    ▲
    │
Malcolm (on soc-host, Docker Compose)
    ├── Arkime (PCAP + session metadata)
    ├── Zeek (network metadata)
    ├── Suricata (IDS alerts)
    ├── OpenSearch (unified store)
    └── OpenSearch Dashboards (prebuilt dashboards)
        ▲
        │  mirror feed (vmbr1) via forwarder or direct capture
```

**Data flow:**
1. Mirror feed (PVE `vmbr1`) → Malcolm capture (Arkime/Zeek/Suricata) → Malcolm OpenSearch
2. Wazuh agents → Wazuh manager → Wazuh indexer
3. Analyst UI: Malcolm OpenSearch Dashboards (network) + Wazuh dashboard (host)
4. (Optional later) unify Wazuh alerts into Malcolm's OpenSearch for a single pane

## 4. Data verification (2026-09-16)

- ES total: **2.6GB** — mostly SO operational logs (soc 464MB, redis, kratos, elastalert_error 44MB)
- Real security data: Zeek **808MB** (556k docs), Suricata alerts **57MB** (17.7k alerts), PCAP **7GB**
- Zeek logs on disk: 40MB; Suricata eve: small (hourly rotation)
- **Migration is low-risk** — no large historical dataset to preserve

## 5. Migration plan (phased)

### M0 — Prerequisites
- **soc-host mirror NIC:** add a NIC on PVE `vmbr1` to `soc-host` so Malcolm can capture the mirror feed (or run a Malcolm forwarder on the SO VM's `bond0`)
- **Filebeat AVX2 swap (REQUIRED on Ivy Bridge host):** Malcolm's `filebeat-oss:9.5.2` uses UBI 10 (requires AVX2). Swap to `filebeat-wolfi:9.5.2` via `malcolm/filebeat-patch.sh` (see §7b)
- **Update hook (auto-heal):** `malcolm/malcolm-update.sh` wraps Malcolm updates (re-applies the swap); `malcolm/malcolm-filebeat-check.sh` + systemd timer auto-detect a crash-loop and re-heal (see §7c)
- **Resource sizing:** Malcolm needs ~8GB RAM + disk for OpenSearch indices + Arkime PCAP (reuse the 10GB PCAP cap / `so-capture` pattern)
- **Rule update mechanism:** plan `suricata-update` cron for ET Open rules
- **Alerting:** plan OpenSearch Alerting plugin + Sigma rules (replaces ElastAlert)

### M1 — Deploy Malcolm on soc-host
- Clone `cisagov/Malcolm`, run setup + `docker compose up`
- Configure capture on the mirror NIC
- Verify OpenSearch Dashboards + Arkime come up

### M2 — Network data pipeline
- Point Malcolm at the mirror feed (direct capture or forwarder)
- Verify Suricata alerts, Zeek logs, Arkime sessions populate the prebuilt dashboards
- Carry over the TrueNAS suppression (Suricata threshold.conf + rules)

### M3 — Deploy Wazuh
- Wazuh manager + indexer + dashboard (bundled)
- Install Wazuh agents on DC01, MEMBERSRV01, Workstation, open-atomic, soc-host
- Enable syscollector (inventory), FIM, active response

### M4 — Dashboards + saved queries
- Malcolm prebuilt dashboards (network overview, protocols)
- Wazuh dashboard (host inventory, FIM, vuln)
- Saved queries mirroring the SO Hunt saved searches (Remote Desktop Activity, etc.)

### M5 — Verify
- Suricata alerts, Zeek conn/dns/http, Arkime sessions, Wazuh events all visible
- Confirm the TrueNAS suppression carries over
- Confirm API access is free on every component

### M6 — Decommission SO
- Keep SO VM as backup until the target stack is stable
- Then shut down / reclaim the VM

## 6. What's lost by dropping SO (and later-phase replacements)

| Lost capability | Impact | Replacement (later phase) |
|---|---|---|
| **Hunt console** (analyst query UI) | Threat hunting UX | Malcolm OpenSearch Dashboards + Arkime; Sigma + OpenSearch Alerting |
| **Fleet/osquery centralized mgmt** | osquery policy management | Fleet DM (free tier, fork of the original open-source Kolide Fleet) or keep Elastic Fleet |
| **Integrated detections UI** | Rule tuning convenience | File-based rules + salt/ansible |
| **ElastAlert/Sigma alerting** | Sigma-based detection | **OpenSearch Alerting plugin + Sigma** (gap — needs building) |
| **PCAP pivot from alerts** | Click alert → PCAP | Arkime session→PCAP (better, prebuilt) |
| **AI summaries / assistant** | Paywalled anyway | Not needed |
| **Cases** | Case management | IRIS (planned) |
| **Elastic Agent** | Host agent | Wazuh agent |

## 7. Viability assessment

- **Malcolm is the same stack, pre-integrated** — Arkime + Zeek + Suricata + OpenSearch + OpenSearch Dashboards + Logstash, Apache 2.0, CISA/INL-backed, actively maintained (updated 2026-09-16), 2.5k stars
- **Much lower assembly effort** than the custom stack — prebuilt dashboards, setup scripts, container deployment
- **Wazuh** is mature and widely deployed for host EDR
- **Reuses existing work:** Suricata/Zeek concepts carry over; the ES manipulation technique transfers to OpenSearch (API-compatible); the TrueNAS suppression carries over
- **Main risk:** Malcolm is a container cluster (resource use) and lacks host EDR (Wazuh covers it). No single-appliance convenience like SO's SOC console
- **OPNSense** adds inline IPS (blocking) + firewall + Zenarmor — Phase 4 enforcement layer, no complication adding later

## 7a. Licensing (verified 2026-09-16)

- **Malcolm project: Apache 2.0** (fully permissive)
- Components: OpenSearch + Dashboards (Apache 2.0), Arkime (Apache 2.0), Zeek (BSD-3), Suricata (GPL-2.0), Strelka (Apache 2.0), NetBox (Apache 2.0), Keycloak (Apache 2.0), Valkey (BSD-3), Postgres (PostgreSQL license), Nginx (BSD-2)
- **Logstash OSS + Filebeat OSS: Elastic License 2.0 (ELv2)** — source-available, NOT OSI open source. Restrictions: cannot offer as a managed service to third parties; cannot circumvent license keys. **Free for internal/homelab use** — no practical restriction here
- **Wazuh: GPLv2** (fully open source)

## 7b. CPU compatibility — AVX2 / x86-64-v3 (verified 2026-09-16)

The SO deployment hit this: Elastic's `elastic-agent` 9.4.3+ uses a UBI 10 base whose glibc requires **x86-64-v3 (AVX2)** — the Proxmox host (Xeon E5-4650 v2, Ivy Bridge) lacks AVX2, so the container crash-loops with `Fatal glibc error: CPU does not support x86-64-v3` (elastic/beats#51824).

**Malcolm image bases (verified from Dockerfiles):**

| Malcolm container | Base image | AVX2-safe? |
|---|---|---|
| opensearch | `opensearchproject/opensearch:3.8.0` (Java) | ✅ |
| dashboards | `opensearchproject/opensearch-dashboards:3.8.0` (Node.js) | ✅ |
| logstash-oss | `docker.elastic.co/logstash/logstash-oss:9.5.2` (**UBI 9**) | ✅ |
| **filebeat-oss** | `docker.elastic.co/beats/filebeat-oss:9.5.2` (**UBI 10**) | ❌ **AVX2 REQUIRED** |
| arkime | `debian:13-slim` | ✅ |
| zeek | `zeek/zeek:8.2.2` | ✅ |
| suricata | `debian:13-slim` | ✅ |

**Wazuh image bases:** manager (`amazonlinux:2023`, C-based) ✅ · indexer (OpenSearch/Java) ✅ · dashboard (Node.js) ✅ · agent (C-based) ✅ — **no AVX2 issues**.

**The one blocker: Malcolm's Filebeat 9.5.2 (UBI 10).** Workaround (same as the SO elastic-agent fix): swap to the **wolfi variant** — `docker.elastic.co/beats/filebeat-wolfi:9.5.2` (hardened, no AVX2 requirement; verified it exists). One-line change to Malcolm's `filebeat.Dockerfile` or a docker-compose image override. Alternative: pin `filebeat-oss:9.4.2` (last pre-UBI-10 version).

**Bottom line:** Malcolm + Wazuh is viable on the Ivy Bridge host with a single Filebeat image swap — a much smaller workaround than SO's fleet swap.

## 7c. Filebeat update hook (auto-heal, mirrors the SO wolfi guard)

Elastic keeps UBI 10 ("the standard we need to align on everywhere now"), so **every Malcolm update re-introduces the AVX2 crash** when the Filebeat version bumps. Scripts in `malcolm/`:

| File | Purpose |
|---|---|
| `filebeat-patch.sh` | Patches `filebeat.Dockerfile` (`filebeat-oss` → `filebeat-wolfi`), rebuilds the image with the docker-compose tag |
| `malcolm-update.sh` | Safe update wrapper: `control.py update` → re-patch → `docker compose up -d` |
| `malcolm-filebeat-check.sh` | Auto-heal: detects Filebeat crash-loop (`x86-64-v3` in logs) → re-patch → restart |
| `malcolm-filebeat-check.service` + `.timer` | systemd timer running the check every 5 min |

**Deploy:** copy scripts to `/usr/local/sbin/`, units to `/etc/systemd/system/`, `systemctl enable --now malcolm-filebeat-check.timer`. Same resilience as the SO healthcheck guard — even if an update bypasses the wrapper, the timer catches it within minutes.

## 8. Open questions

- Malcolm capture mode: direct capture on the mirror NIC vs a lightweight forwarder on the SO VM's `bond0`
- Whether to unify Wazuh alerts into Malcolm's OpenSearch (single pane) or keep two dashboards
- Whether Fleet/osquery centralized management is needed (Fleet DM free tier) or Wazuh syscollector suffices
- Malcolm resource sizing on soc-host (RAM/disk) given the 8GB/100GB allocation