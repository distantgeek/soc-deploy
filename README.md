# soc-deploy

Homelab SOC platform: **Malcolm** (CISA/INL, Apache 2.0) for network monitoring + **Wazuh** (GPL) for host EDR, wrapped with an open-source platform layer (case management, threat intel, enrichment, sandbox, DFIR, SOAR).

This repo is the deployment and integration wiring for that platform. It started as a DIY ELK stack on Podman Quadlets (Phase 1, see git history); pivoted to Security Onion as the foundation; and **migrated to Malcolm + Wazuh** (2026-09-16) because SO's API Clients are Pro-paywalled. Malcolm bundles the same network stack (Arkime + Zeek + Suricata + OpenSearch + Dashboards) pre-integrated with zero paywalls. See [docs/MIGRATION-PLAN.md](docs/MIGRATION-PLAN.md).

## Architecture

```
                    ┌─────────────────────────────────────────────────────┐
                    │            Malcolm (network monitoring)             │
                    │  Arkime (PCAP) · Zeek · Suricata · OpenSearch       │
                    │  OpenSearch Dashboards · Keycloak (IdP)             │
                    └───────────────┬─────────────────────────────────────┘
                                    │
        ┌───────────────┬───────────┼───────────────┬───────────────┐
        ▼               ▼           ▼               ▼               ▼
   ┌─────────┐    ┌──────────┐ ┌─────────┐    ┌──────────┐    ┌─────────┐
   │  IRIS   │    │ IntelOwl │ │  MISP   │    │Velociraptor│   │ Shuffle │
   │  cases  │◄──►│ enrich   │◄─►│  TIP    │    │  DFIR    │    │  SOAR   │
   └────┬────┘    └──────────┘ └─────────┘    └──────────┘    └─────────┘
        │               ▲
        └── CAPEv2 ─────┘   (sandbox)

   Wazuh (host EDR: FIM, active response, vuln) — agents on endpoints
   OPNSense (inline IPS) — Phase 4 enforcement layer
```

### Component roles

| Component | Role | License | Notes |
|---|---|---|---|
| **Malcolm** | Network monitoring: PCAP (Arkime), NSM (Zeek), IDS (Suricata), search (OpenSearch + Dashboards) | Apache 2.0 | CISA/INL. Runs on `soc-host` (26 containers). Bundles Arkime, Zeek, Suricata, OpenSearch, Dashboards, Keycloak. Zero paywalls |
| **Wazuh** | Host EDR: FIM, active response, vulnerability detection, syscollector | GPLv2 | Agents on endpoints; manager + indexer + dashboard on `soc-host` (Phase M3, deferred ~Oct 1) |
| **DFIR-IRIS** | Incident response case management | LGPL-3.0 | TheHive successor. Cases, timelines, evidence hashing, IOC mgmt, MITRE ATT&CK mapping, multi-tenant, REST API, 162 hook bindings |
| **IntelOwl** | Threat intel enrichment engine | AGPL-3.0 | Cortex successor. 100+ analyzers (VT, MISP, Shodan, GreyNoise...), native connectors to MISP/OpenCTI/IRIS, playbooks, correlator |
| **MISP** | Threat intelligence platform | AGPL-3.0 | IOC sharing, NIDS rule generation for Suricata/Zeek |
| **CAPEv2** | Malware sandbox | BSD-3-Clause | Trellix Intelligent Sandbox (TIS/ATD) analog |
| **Velociraptor** | Endpoint DFIR / live forensics | AGPL-3.0 | Streams artifact results into OpenSearch |
| **Shuffle** | SOAR / playbook orchestration | AGPL-3.0 | Visual builder, 300+ integrations, native Wazuh webhook |
| **OPNSense** | Inline IPS / firewall (Phase 4) | BSD-2-Clause | Suricata inline (blocking) + Zenarmor app control |

### Trellix mapping

| Trellix product | Open-source equivalent |
|---|---|
| XDR / Endpoint Security | Malcolm (Suricata IDS + Zeek + Arkime) + Wazuh (host EDR) |
| Network IPS | Inline Suricata (separate sensor, deferred) |
| Intelligent Sandbox (TIS/ATD) | CAPEv2 |
| ePO (centralized orchestration) | Fleet (osquery) + Wazuh active response + Shuffle — no single 1:1 equivalent exists |
| Threat Intelligence Exchange | MISP + IntelOwl + IRIS |
| DLP | No maintained purpose-built OSS exists; composed from Suricata/Zeek egress rules + Wazuh FIM + osquery/Fleet + secret scanners (Phase 5) |
| Application Control | No OSS equivalent; functionality splits across Fleet/osquery (allowlisting + inventory) + Wazuh FIM/active response (FIM + change control) + SELinux/AppArmor/Landlock (kernel enforcement) — Phase 5 |

## Repo layout

```
deploy.sh                      Phase 1 installer (ELK pod, Podman Quadlets)
soc-elastic.pod                Pod: ES loopback 127.0.0.1:9200, Kibana 5601
soc-elasticsearch.container    ES 8.13.4 single-node, 2g heap / 3g memory
soc-kibana.container           Kibana 8.13.4, 1g memory, service token + 3 encryption keys
soc-net.network                Bridge 10.89.1.0/24
salt/                          SO salt overrides (deployed to /opt/so/saltstack/local/)
  _modules/healthcheck.py      healthcheck module + fleet_image check (wolfi swap guard)
  pillar/healthcheck/          healthcheck pillar (enabled, schedule, checks)
malcolm/                       Malcolm deployment helpers (deployed to soc-host)
  filebeat-patch.sh            Filebeat 9.4.2 pin (AVX2 fix) + rebuild
  malcolm-update.sh            Safe update wrapper (update → re-patch → restart)
  malcolm-filebeat-check.sh    Auto-heal: detects Filebeat crash-loop → re-patch
  malcolm-filebeat-check.*     systemd service + timer (runs the check every 5 min)
  so-capture                   Per-endpoint capture (IP or MAC) on the mirror NIC
docs/ROADMAP.md                Phased build plan
docs/DEPLOYMENT.md             VM topology, sizing, integration wiring order
docs/MIGRATION-PLAN.md         Migration off SO → Malcolm + Wazuh
docs/PHASE0.md                 Phase 0 plan: SO on Proxmox + network mirror
docs/TECH-BRIEF-PHASE0.md      Reproduction runbook: exact commands + config changes
docs/TECH-BRIEF-PHASE1.md      Phase 1 runbook: x86-64-v3 wolfi swap + setup completion + monitoring hook
docs/TECH-BRIEF-PHASE-M0.md    M0 runbook: soc-host VM + mirror NIC
docs/TECH-BRIEF-PHASE-M1.md    M1 runbook: Malcolm deployment + 8 critical fixes
```

The Phase 1 ELK Quadlet stack is superseded by Malcolm's bundled OpenSearch. It is retained in git history and as a reference pattern for running the external platform layer (IRIS, IntelOwl, MISP, CAPEv2, Shuffle) as Quadlet containers on the Fedora host.

## Security notes

- Secrets are never committed. `.gitignore` excludes `*.env`, `*.secret`, `secrets/`, `credentials/`.
- Phase 1 stored credentials as Podman secrets (`/var/lib/containers/storage/secrets/`); the deploy script carries a Vault-migration TODO.
- All external services must be bound to the management network only, never exposed to the internet.

## Status

**Malcolm is live** (M0–M2 complete, 2026-09-16): 26 containers healthy on `soc-host`, Zeek/Suricata/Arkime capturing the mirrored feed, parity confirmed against SO. **Security Onion decommissioned** (VM 300 stopped, kept as backup). **Wazuh (M3) deferred ~Oct 1** (monthly API usage at 95%). See [docs/MIGRATION-PLAN.md](docs/MIGRATION-PLAN.md) and [docs/ROADMAP.md](docs/ROADMAP.md).