# Migration Plan — Security Onion → OpenSearch + Suricata/Zeek/Arkime + Wazuh

Status: DRAFT (2026-09-16). Migration is low-risk (little data); not time-critical.

## 1. Rationale

Security Onion's core (Suricata, Zeek, Elasticsearch, PCAP) is open-source, but the **SOC console's API Clients require a paid Pro license + Hydra**. Programmatic rule tuning is paywalled. The target stack replicates SO's functions with **zero paywalls** and full API access on every component.

## 2. Platform / function roles

| SO function | SO component | Target replacement | Notes |
|---|---|---|---|
| Network IDS | Suricata | **Suricata** (standalone) | Already running; extract or keep in SO and forward |
| Network metadata | Zeek | **Zeek** (standalone) | Already running; 22 log types |
| PCAP capture/search | suricata pcap-file | **Arkime** | Better session→PCAP search UI |
| SIEM / search store | Elasticsearch | **Wazuh indexer** (OpenSearch fork) | Single unified store |
| Dashboards | Kibana | **OpenSearch Dashboards** (Wazuh dashboard) | Custom dashboards |
| Host telemetry | Fleet + Elastic Agent | **Wazuh agent** (syscollector, FIM, active response) | Replaces Fleet inventory role |
| osquery | Fleet osquery_manager | **Wazuh osquery integration** (limited) | Partial; Kolide Fleet later if needed |
| Analyst query UI | Hunt | **OpenSearch Dashboards** + saved queries | Threat hunting deferred |
| Rule management | Detections page | **Suricata rule files + Wazuh rules** | File-based, salt/ansible-managed |
| Cases | Cases | **IRIS** (planned Phase 2) | Later phase |
| Threat intel | — | **MISP** (planned) | Later phase |
| DFIR | — | **Velociraptor** (planned) | Later phase |
| Automation | — | **Shuffle** (planned) | Later phase |
| Inline IPS | — | **OPNSense** (Suricata inline) | Phase 4; blocking layer, not another IDS |

## 3. Target architecture (Wazuh-indexer-unified)

```
Endpoints (DC01, MEMBERSRV01, Workstation, open-atomic, soc-host)
    │  Wazuh agent (FIM, syscollector, active response, osquery)
    ▼
Wazuh manager ──► Wazuh indexer (OpenSearch) ◄── OpenSearch Dashboards
    ▲                                        ▲
    │                                        │
Suricata (eve.json) ──► Logstash/Data Prepper ─┘
Zeek (logs) ─────────► Logstash/Data Prepper ─┘
Arkime ──────────────► session metadata ──────┘  + PCAP files on disk
```

**Data flow:**
1. Suricata `eve.json` → Logstash → Wazuh indexer
2. Zeek logs → Logstash → Wazuh indexer
3. Arkime → Wazuh indexer (session metadata) + PCAP files on disk
4. Wazuh agents → Wazuh manager → Wazuh indexer
5. OpenSearch Dashboards → query everything in one place

## 4. Data verification (2026-09-16)

- ES total: **2.6GB** — mostly SO operational logs (soc 464MB, redis, kratos, elastalert_error 44MB)
- Real security data: Zeek **808MB** (556k docs), Suricata alerts **57MB** (17.7k alerts), PCAP **7GB**
- Zeek logs on disk: 40MB; Suricata eve: small (hourly rotation)
- **Migration is low-risk** — no large historical dataset to preserve

## 5. Migration plan (phased)

### M1 — Stand up target stack on soc-host (Fedora)
- Wazuh manager + indexer + dashboard (Wazuh bundles all three)
- Logstash (or OpenSearch Data Prepper) for network log ingestion
- Arkime (capture + viewer)

### M2 — Network data pipeline
- Keep Suricata/Zeek running (in SO containers or standalone on soc-host)
- Configure Logstash: Suricata `eve.json` + Zeek logs → Wazuh indexer
- Configure Arkime: capture on the mirror interface → Wazuh indexer + PCAP files

### M3 — Endpoint enrollment
- Install Wazuh agents on DC01, MEMBERSRV01, Workstation, open-atomic, soc-host
- Enable syscollector (inventory), FIM, active response

### M4 — Dashboards
- OpenSearch Dashboards: network overview, alert triage, host inventory
- Saved queries mirroring the SO Hunt saved searches (Remote Desktop Activity, etc.)

### M5 — Verify
- Suricata alerts, Zeek conn/dns/http, Wazuh events, Arkime sessions all visible in one dashboard
- Confirm the TrueNAS suppression carries over (Suricata threshold.conf + rules)

### M6 — Decommission SO
- Keep SO VM as backup until the target stack is stable
- Then shut down / reclaim the VM

## 6. What's lost by dropping SO (and later-phase replacements)

| Lost capability | Impact | Replacement (later phase) |
|---|---|---|
| **Hunt console** (analyst query UI) | Threat hunting UX | OpenSearch Dashboards + Sigma rules + OpenSearch alerting |
| **Fleet/osquery centralized mgmt** | osquery policy management | Kolide Fleet (open-source) or keep Elastic Fleet |
| **Integrated detections UI** | Rule tuning convenience | File-based rules + salt/ansible |
| **PCAP pivot from alerts** | Click alert → PCAP | Arkime session→PCAP (better) |
| **AI summaries / assistant** | Paywalled anyway | Not needed |
| **Cases** | Case management | IRIS (planned) |
| **Elastic Agent** | Host agent | Wazuh agent |

## 7. Viability assessment

- **All components mature:** Wazuh (widely deployed), Arkime (production NSM), OpenSearch (AWS-backed), Suricata/Zeek (already proven here)
- **Reuses existing work:** Suricata/Zeek running; ES manipulation technique transfers to OpenSearch (API-compatible)
- **Main risk is assembly effort**, not viability — no single appliance, so more wiring and maintenance
- **OPNSense** adds inline IPS (blocking) + firewall + Zenarmor app control — earns its place as the Phase 4 enforcement layer, not another IDS

## 8. Open questions

- Wazuh indexer as the single store (recommended) vs separate OpenSearch + forward Wazuh alerts
- Keep Suricata/Zeek in SO containers (forward data) vs extract to soc-host standalone
- Whether Fleet/osquery centralized management is needed (Kolide) or Wazuh syscollector suffices