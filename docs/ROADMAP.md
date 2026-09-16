# Roadmap

Phased build plan for the SOC platform. Each phase has a goal, the components it introduces, the integration wiring, and exit criteria. Phases build on each other; do not skip ahead.

> **DIRECTION CHANGE (2026-09-16):** Security Onion's API Clients (programmatic rule tuning) require a paid **Pro license + Hydra** — paywalled on free tier. The platform is migrating to a **fully open-source stack: Malcolm (CISA/INL, Apache 2.0) for network monitoring + Wazuh for host EDR** — zero paywalls, full API. Malcolm bundles the same stack (Arkime + Zeek + Suricata + OpenSearch + Dashboards) pre-integrated. Phase 0 (SO foundation) is complete and its network monitoring carries over. See [docs/MIGRATION-PLAN.md](docs/MIGRATION-PLAN.md). Phases 1–5 below are reframed around the target stack, not SO.

## Phase M — Migration to Malcolm + Wazuh (DRAFT)

**Goal:** Replace the SO console with a no-paywall stack while keeping the network monitoring already built.

- Deploy **Malcolm** (Arkime + Zeek + Suricata + OpenSearch + Dashboards) on `soc-host`; capture the mirror feed.
- Deploy **Wazuh** (manager + indexer + dashboard); enroll endpoints (DC01, MEMBERSRV01, Workstation, open-atomic, soc-host).
- Carry over the TrueNAS suppression; build saved queries mirroring the SO Hunt searches.
- Decommission SO once the target stack is stable.

**Prerequisites (M0):**
- Add a mirror NIC to `soc-host` on PVE `vmbr1`
- **Filebeat AVX2 swap** (required on Ivy Bridge host): Malcolm's `filebeat-oss:9.5.2` uses UBI 10 (requires AVX2). Swap to `filebeat-wolfi:9.5.2` via `malcolm/filebeat-patch.sh`
- **Update hook** (auto-heal): `malcolm/malcolm-update.sh` (safe update wrapper) + `malcolm/malcolm-filebeat-check.sh` + systemd timer (detects crash-loop → re-applies swap). Same pattern as the SO wolfi healthcheck guard
- Resource sizing (~8GB RAM + disk for OpenSearch + Arkime PCAP); rule-update mechanism (`suricata-update` cron); alerting (OpenSearch Alerting + Sigma)

**Tools:**
- **network-engineer subagent** (opencode, deepseek-v4-pro) — consult for topology/mirror/IPS/capture review during M0–M2

Detailed plan: [docs/MIGRATION-PLAN.md](docs/MIGRATION-PLAN.md).

**Exit criteria:** Suricata alerts, Zeek logs, Arkime sessions, and Wazuh events all visible in dashboards; API access is free on every component; Filebeat survives updates via the auto-heal hook.

## Phase 0 — Foundation: Security Onion (COMPLETE 2026-09-16)

**Goal:** Stand up the core detection platform and prove the network is being monitored.

- Install Security Onion 3.3.0 in its own VM (Oracle Linux-based appliance) on Proxmox.
- Feed it a passive copy of WAN-edge traffic via a TAP (or managed-switch mirror); dedicated sniffing NIC on the R820.
- Configure management + monitoring interfaces, analyst account, and SOC console.
- Verify Suricata IDS, Zeek, and PCAP are ingesting traffic.
- Confirm Elasticsearch is healthy and the SOC console dashboards populate.

Detailed steps: [docs/PHASE0.md](docs/PHASE0.md).

**Exit criteria:** SOC console shows live alerts and Zeek logs; PCAP capture works; analyst can search logs in the console.

## Phase 1 — Core detection tuning

**Goal:** Make detection useful, not just running.

- Tune Suricata rulesets (ET Open + MISP-imported rules); suppress noise.
- Enable Elastic Agent/Fleet/osquery on endpoints; build baseline inventory. (Wazuh is **not bundled** in SO 3.x — deferred to Phase 3, where it pairs with Velociraptor/Shuffle for DFIR + active response.)
- Enable Elastic Agent/Fleet/osquery on endpoints; build baseline inventory.
- Use Hunt for ad-hoc threat hunting queries.

**Exit criteria:** Alert volume is reviewable; host telemetry flows into Elasticsearch; at least one detection rule fires on a test signal.

## Phase 2 — External platform layer: IRIS + IntelOwl + MISP + IdP

**Goal:** Add case management, enrichment, threat intel, and unified login around the core.

- Deploy **DFIR-IRIS** (case management) and **IntelOwl** (enrichment) as Quadlet containers on the Fedora host.
- Deploy **MISP** as the threat intel platform.
- **Unified IdP: Malcolm's bundled Keycloak** serves as the single login for Malcolm, Wazuh dashboard, IRIS, IntelOwl, MISP, and OpenSearch Dashboards (OIDC/SAML). Decision 2026-09-16: use bundled Keycloak over Authentik (zero extra deployment, full-featured, Malcolm is long-term). Authentik deferred unless SSH-key-via-IdP or advanced features are needed.
- Wire MISP → Security Onion: Elastic `ti_misp` integration ingests IOCs into Elasticsearch (Hunt-viewable); community `securityonion-misp` pulls MISP NIDS rules into Suricata/Zeek via cron.
- Wire IntelOwl → IRIS via the native connector (enrichment results land in cases).
- Wire IRIS → MISP (IOC export) and IntelOwl → MISP (enriched IOC push).

**Exit criteria:** An analyst can open a case in IRIS, enrich an indicator via IntelOwl, see MISP IOCs appear in Hunt and Suricata rules, and log into all platforms with one Keycloak account.

**Follow-up (after Malcolm/Wazuh stack is stable):** centralized SSH key management — evaluate Authentik (LDAP-based `AuthorizedKeysCommand`) vs a CA-signed SSH key system. Deferred until the core stack is up.

## Phase 3 — DFIR + SOAR: Velociraptor + Shuffle

**Goal:** Add endpoint forensics and automated response.

- Deploy **Velociraptor** server; enroll the Fedora host and key VMs.
- Stream Velociraptor artifact results into Security Onion's Elasticsearch (native `Elastic.Flows.Upload` / `elastic_upload` VQL, or the community `weslambert/securityonion-velociraptor` script).
- Deploy **Shuffle** as the SOAR layer; build a first playbook (e.g., alert → enrich via IntelOwl → open IRIS case → notify).
- Prefer **Wazuh active response** for fast automated blocking (measured ~6x faster than a Shuffle loop: 0.387s vs 2.5s); use Shuffle for multi-step workflows.

**Exit criteria:** A detected alert can be enriched, escalated to a case, and (optionally) blocked — with the full chain visible in one place.

## Phase 4 — Sandbox + IPS (expansion)

**Goal:** Close the loop with malware analysis and inline prevention.

- Deploy **CAPEv2** sandbox; submit samples from IRIS/IntelOwl analyzers; push extracted IOCs to MISP.
- Deploy a separate inline **Suricata IPS** sensor (Security Onion itself is passive IDS only). Place it at the network edge; move from alerting to blocking.

**Exit criteria:** A suspicious file can be detonated in CAPEv2 with results flowing back to MISP/IRIS; the IPS sensor blocks a test signature inline.

## Phase 5 — DLP + Application Control (long-term)

**Goal:** Add data-loss prevention and application allowlisting — the Trellix DLP and Application Control equivalents. Much later phase; only after the detection, case, intel, and SOAR layers are mature.

- **DLP (data loss prevention):** no maintained purpose-built open-source DLP exists — OpenDLP (abandoned 2012) and MyDLP (abandoned 2014) are dead. Build DLP from the existing stack instead:
  - **Network egress DLP:** Suricata/Zeek rules + custom signatures to flag sensitive data (PII, credentials, card numbers) leaving the network.
  - **Endpoint DLP:** Wazuh FIM + active response for sensitive-file monitoring; osquery/Fleet queries for data-at-rest discovery.
  - **Secret/PII scanning:** TruffleHog/Gitleaks for repos and CI; a scanner like `pleno-dlp` or `ghostdlp` for filesystem PII/secret discovery.
  - **AI/LLM egress DLP:** LeakShield (self-hosted AI gateway + DLP) if LLM usage becomes a concern.
- **Application Control (allowlisting + change control):** Trellix Application Control is a robust suite — allowlisting, FIM, software/version inventory, change tracking, and exploit mitigation. No single open-source equivalent exists; its functionality splits across the stack:

  | Trellix App Control capability | Open-source equivalent |
  |---|---|
  | Application allowlisting / default-deny | osquery + Fleet exec-event policy; Wazuh active response blocks on detection; SELinux/AppArmor/Landlock kernel enforcement; OpenShield HIPS (pre-alpha, most direct analog) |
  | File integrity monitoring (FIM) | Wazuh FIM (syscheck); osquery `file_events`; AIDE/Samhain for baseline integrity |
  | Software / version inventory | osquery `programs`/`rpm_packages`/`deb_packages` tables via Fleet; Wazuh syscollector inventory; OCS Inventory NG / GLPI for CMDB-style tracking |
  | Change control / change tracking | Wazuh FIM + active response; osquery process/file event streams; auditd for syscall-level change audit |
  | Exploit mitigation / memory protection | No direct OSS equivalent — partially covered by SELinux hardening and kernel hardening (grsecurity/PaX are dead); accept as a gap |
  | Centralized policy + reporting | Fleet (osquery) + Wazuh manager; policy-as-code in the repo |

**Exit criteria:** A test sensitive file is flagged when exfiltrated; a test unauthorized binary is blocked from executing on an enrolled endpoint; FIM detects a modified baseline file; software inventory is queryable via Fleet.

## Deferred / not planned

- **TheHive/Cortex:** removed from Security Onion since 2.3.100 (2022) over licensing; replaced by IRIS + IntelOwl. Do not reintroduce.
- **Second detection engine:** Elastic Security detection rules stay disabled — Security Onion/Wazuh is the single detection engine; Elasticsearch is used for search/dissection/storage only.
- **ePO clone:** no open-source equivalent exists; the role is covered by Fleet + Wazuh active response + Shuffle.
- **Purpose-built open-source DLP:** OpenDLP and MyDLP are abandoned; DLP is built from Suricata/Zeek + Wazuh + osquery/Fleet + secret scanners (Phase 5).

## Decision log

| Date | Decision | Rationale |
|---|---|---|
| 2026-09 | **Migrate off Security Onion → Malcolm + Wazuh** | SO's API Clients (rule tuning) require a paid Pro license + Hydra — paywalled on free tier. Malcolm (CISA/INL, Apache 2.0) bundles the same network stack (Arkime + Zeek + Suricata + OpenSearch + Dashboards) pre-integrated; Wazuh covers host EDR. Zero paywalls, full API. Migration is low-risk (little data) |
| 2026-09 | **Malcolm's bundled Keycloak = unified IdP** (over Authentik) | Keycloak is already bundled with Malcolm (zero extra deployment), full-featured (OIDC/SAML/LDAP), and Malcolm is the long-term platform. Authentik's advantages (SSH-key-via-LDAP, lighter, more flexible) don't justify a separate component for homelab SSO. Authentik deferred unless SSH-key management or advanced features are needed |
| 2026-09 | Security Onion replaces DIY ELK Quadlet stack | Fastest path to network monitoring + log dissection; bundles Suricata/Zeek/Wazuh/ES/Fleet |
| 2026-09 | IRIS + IntelOwl replace TheHive + Cortex | TheHive went commercial; IRIS/IntelOwl are actively maintained, fully open source, natively integrated |
| 2026-09 | IDS (passive) first; inline IPS deferred | "Lots of setup before expanding" — IPS is Phase 4 |
| 2026-09 | Single detection engine (Wazuh/SO); ELK as log store only | Avoid duplicate alerting; ELK adds value for search/dissection |
| 2026-09 | DLP + Application Control added as Phase 5 (long-term) | Trellix DLP/App Control equivalents; no maintained purpose-built OSS exists, so compose from existing stack |
| 2026-09 | Managed switch inline on the AiMesh backhaul link (RT-AC68U ↔ GS-AX5400), mirroring to a dedicated sniffing port | ASUS AiMesh has no SPAN; the backhaul is the choke point for all upstairs traffic; monitoring stays out-of-band for endpoints |
| 2026-09 | Dedicated sniffing port on the R820's quad-port NIC via a dedicated bridge (vmbrX) | Isolates promiscuous sniffing + offload changes from management; PCIe passthrough would take all 4 ports including management |
| 2026-09 | Disable MAC learning on the mirror ingress port (`nic1`) | The bridge learned all LAN MACs and stopped flooding known-unicast to the sniffing VM — the "no feed" root cause. Learning off forces the bridge to flood everything to `tap300i1` |
| 2026-09 | Suricata PCAP cap lowered to 10GB | Disk is limited (125G NSM); PCAP was growing ~311GB/day at current traffic. 10GB cap + per-endpoint `so-capture` for full visibility on specific hosts |
| 2026-09 | Per-endpoint capture via `so-capture` script (not Suricata) | Suricata pcap has no per-IP retention exception; a separate tcpdump per host is the only way to capture "all data for one IP regardless of the global cap" |
| 2026-09 | Wazuh deferred to Phase 3; Fleet/osquery for Phase 1 host telemetry | SO 3.x does not bundle Wazuh (no `so-wazuh-manager` container). Fleet/osquery is the native, zero-extra-infra path for Phase 1; Wazuh pairs with Velociraptor/Shuffle for DFIR + active response in Phase 3 |
| 2026-09 | Event split: SO = store/search layer, Wazuh = host EDR layer | Avoid duplicate alerting. SO owns ES; Wazuh alerts forward into SO's Logstash → ES → Hunt. Wazuh agent for host security (FIM, rootkits, active response); Elastic Agent/osquery for host inventory/telemetry; network events are SO-only |
| 2026-09 | Console split: Hunt = primary console, Wazuh console = drill-down only | Hunt is the single pane of glass for all events (network + host, with PCAP/case pivots). Wazuh console used only for Wazuh-specific deep dives (FIM file details, vulnerability scan results, active response history) |