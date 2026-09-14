# soc-deploy

Homelab SOC platform: **Security Onion** as the core detection/XDR layer, wrapped with an open-source platform layer (case management, threat intel, enrichment, sandbox, DFIR, SOAR).

This repo is the deployment and integration wiring for that platform. It started as a DIY ELK stack on Podman Quadlets (Phase 1, see git history); the direction has since pivoted to Security Onion as the foundation, with the Quadlet pattern retained for the external platform layer.

## Architecture

```
                    ┌─────────────────────────────────────────────────────┐
                    │            Security Onion (core XDR)                │
                    │  Suricata (IDS) · Zeek · Wazuh · Elastic Security   │
                    │  Elastic Agent / Fleet / osquery · PCAP · Hunt      │
                    │  Cases · SOC console                                │
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
```

### Component roles

| Component | Role | License | Notes |
|---|---|---|---|
| **Security Onion** | Core detection/XDR: IDS, NSM, log management, host agent | Free (GPL components) | Oracle Linux-based appliance, runs in its own VM. Bundles Suricata, Zeek, Wazuh, Elasticsearch, Fleet/osquery, PCAP, Hunt, Cases |
| **DFIR-IRIS** | Incident response case management | LGPL-3.0 | TheHive successor. Cases, timelines, evidence hashing, IOC mgmt, MITRE ATT&CK mapping, multi-tenant, REST API, 162 hook bindings |
| **IntelOwl** | Threat intel enrichment engine | AGPL-3.0 | Cortex successor. 100+ analyzers (VT, MISP, Shodan, GreyNoise...), native connectors to MISP/OpenCTI/IRIS, playbooks, correlator |
| **MISP** | Threat intelligence platform | AGPL-3.0 | IOC sharing, NIDS rule generation for Suricata/Zeek |
| **CAPEv2** | Malware sandbox | BSD-3-Clause | Trellix Intelligent Sandbox (TIS/ATD) analog |
| **Velociraptor** | Endpoint DFIR / live forensics | AGPL-3.0 | Streams artifact results into Elasticsearch |
| **Shuffle** | SOAR / playbook orchestration | AGPL-3.0 | Visual builder, 300+ integrations, native Wazuh webhook |

### Trellix mapping

| Trellix product | Open-source equivalent |
|---|---|
| XDR / Endpoint Security | Security Onion (Suricata IDS + Zeek + Wazuh + Elastic Security) |
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
docs/ROADMAP.md                Phased build plan
docs/DEPLOYMENT.md             VM topology, sizing, integration wiring order
docs/PHASE0.md                 Phase 0 plan: SO on Proxmox + network mirror
docs/TECH-BRIEF-PHASE0.md      Reproduction runbook: exact commands + config changes
docs/TECH-BRIEF-PHASE1.md      Phase 1 runbook: x86-64-v3 wolfi swap + setup completion + monitoring hook
```

The Phase 1 ELK Quadlet stack is superseded by Security Onion's bundled Elasticsearch. It is retained in git history and as a reference pattern for running the external platform layer (IRIS, IntelOwl, MISP, CAPEv2, Shuffle) as Quadlet containers on the Fedora host.

## Security notes

- Secrets are never committed. `.gitignore` excludes `*.env`, `*.secret`, `secrets/`, `credentials/`.
- Phase 1 stored credentials as Podman secrets (`/var/lib/containers/storage/secrets/`); the deploy script carries a Vault-migration TODO.
- All external services must be bound to the management network only, never exposed to the internet.

## Status

Phase 0 (Security Onion foundation) is the current focus. See [docs/ROADMAP.md](docs/ROADMAP.md).