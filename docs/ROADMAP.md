# Roadmap

Phased build plan for the SOC platform. Each phase has a goal, the components it introduces, the integration wiring, and exit criteria. Phases build on each other; do not skip ahead.

## Phase 0 — Foundation: Security Onion

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
- Enable Wazuh agent on the Fedora host and key VMs; review active response options.
- Enable Elastic Agent/Fleet/osquery on endpoints; build baseline inventory.
- Use Hunt for ad-hoc threat hunting queries.

**Exit criteria:** Alert volume is reviewable; host telemetry flows into Elasticsearch; at least one detection rule fires on a test signal.

## Phase 2 — External platform layer: IRIS + IntelOwl + MISP

**Goal:** Add case management, enrichment, and threat intel around the core.

- Deploy **DFIR-IRIS** (case management) and **IntelOwl** (enrichment) as Quadlet containers on the Fedora host.
- Deploy **MISP** as the threat intel platform.
- Wire MISP → Security Onion: Elastic `ti_misp` integration ingests IOCs into Elasticsearch (Hunt-viewable); community `securityonion-misp` pulls MISP NIDS rules into Suricata/Zeek via cron.
- Wire IntelOwl → IRIS via the native connector (enrichment results land in cases).
- Wire IRIS → MISP (IOC export) and IntelOwl → MISP (enriched IOC push).

**Exit criteria:** An analyst can open a case in IRIS, enrich an indicator via IntelOwl, and see MISP IOCs appear in Hunt and Suricata rules.

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
| 2026-09 | Security Onion replaces DIY ELK Quadlet stack | Fastest path to network monitoring + log dissection; bundles Suricata/Zeek/Wazuh/ES/Fleet |
| 2026-09 | IRIS + IntelOwl replace TheHive + Cortex | TheHive went commercial; IRIS/IntelOwl are actively maintained, fully open source, natively integrated |
| 2026-09 | IDS (passive) first; inline IPS deferred | "Lots of setup before expanding" — IPS is Phase 4 |
| 2026-09 | Single detection engine (Wazuh/SO); ELK as log store only | Avoid duplicate alerting; ELK adds value for search/dissection |
| 2026-09 | DLP + Application Control added as Phase 5 (long-term) | Trellix DLP/App Control equivalents; no maintained purpose-built OSS exists, so compose from existing stack |
| 2026-09 | Managed switch inline on the AiMesh backhaul link (RT-AC68U ↔ GS-AX5400), mirroring to a dedicated sniffing port | ASUS AiMesh has no SPAN; the backhaul is the choke point for all upstairs traffic; monitoring stays out-of-band for endpoints |
| 2026-09 | Dedicated sniffing port on the R820's quad-port NIC via a dedicated bridge (vmbrX) | Isolates promiscuous sniffing + offload changes from management; PCIe passthrough would take all 4 ports including management |