# Deployment Plan

VM topology, resource sizing, and integration wiring order for the SOC platform.

## VM topology

| VM | Role | OS | Placement |
|---|---|---|---|
| `soc-onion` | Security Onion (core XDR) | Oracle Linux (appliance) | Proxmox |
| `soc-host` | Fedora Server 43 — external platform layer (IRIS, IntelOwl, MISP, CAPEv2, Velociraptor, Shuffle) | Fedora Server 43 | Proxmox |
| `soc-ips` | Inline Suricata IPS (Phase 4) | Fedora Server or appliance | Proxmox, network edge |

Security Onion runs in its own VM — it is an appliance, not a Quadlet stack. The external platform layer runs as Podman Quadlet containers on `soc-host`, reusing the Phase 1 pattern from this repo.

## Resource sizing

| VM | vCPU | RAM | Disk | Notes |
|---|---|---|---|---|
| `soc-onion` | 8 | 16–24 GB | 200 GB+ | Security Onion minimum; ES + Zeek + Suricata are memory-hungry. Add RAM before adding rulesets |
| `soc-host` | 4 | 8 GB | 100 GB | IRIS/IntelOwl/MISP are modest; CAPEv2 (Phase 4) needs its own disk for samples |
| `soc-ips` | 4 | 8 GB | 50 GB | Phase 4 only |

## Network layout

- **Management network:** analyst access to SOC console, IRIS, IntelOwl, MISP, Shuffle. Never exposed to the internet.
- **Monitoring interface (Security Onion):** passive TAP (or managed-switch mirror) at the WAN edge between the modem and the ASUS GS-AX5400, feeding a dedicated sniffing NIC on the R820. Out-of-band copy — never inline. See [docs/PHASE0.md](docs/PHASE0.md).
- **`soc-net` bridge (10.89.1.0/24):** existing Quadlet network from Phase 1; reused for the external platform layer containers on `soc-host`.

## Integration wiring order

Wire in this order — each step depends on the previous:

1. **Security Onion → console:** install, configure management + monitoring interfaces, create analyst account. Verify dashboards populate.
2. **MISP → Security Onion:**
   - Elastic `ti_misp` integration ingests MISP IOCs into Elasticsearch (visible in Hunt; no alerts by itself).
   - Community `securityonion-misp` pulls MISP NIDS rules into Suricata/Zeek via cron.
3. **IntelOwl → IRIS:** enable the native connector so enrichment results write into IRIS cases.
4. **IRIS → MISP:** export case IOCs to MISP; **IntelOwl → MISP:** push enriched indicators.
5. **Velociraptor → Elasticsearch:** stream artifact results via native `Elastic.Flows.Upload` / `elastic_upload` VQL, or the community `weslambert/securityonion-velociraptor` script (unofficial, tested standalone).
6. **Shuffle → everything:** build playbooks that call IntelOwl, open IRIS cases, and trigger Wazuh active response. Use Wazuh active response for fast blocking; Shuffle for multi-step workflows.
7. **CAPEv2 (Phase 4):** submit samples from IRIS/IntelOwl analyzers; push extracted IOCs to MISP.

## Secrets management

- Never commit secrets. `.gitignore` excludes `*.env`, `*.secret`, `secrets/`, `credentials/`.
- Phase 1 pattern: Podman secrets injected as container env vars (`Secret=name,type=env,target=VAR`). Secrets live in `/var/lib/containers/storage/secrets/` — back up securely.
- Vault migration is planned: replace the Podman secret creation block in `deploy.sh` with a Vault agent that writes secrets into the container environment. Quadlet unit files do not need to change.
- Security Onion credentials are managed by its own setup wizard; store them in the same secret manager as everything else.

## Verification checklist

- [ ] SOC console shows live alerts and Zeek logs
- [ ] PCAP capture works
- [ ] Wazuh agent reports from `soc-host`
- [ ] MISP IOCs appear in Hunt
- [ ] IntelOwl enrichment lands in an IRIS case
- [ ] Velociraptor artifact results appear in Elasticsearch
- [ ] Shuffle playbook completes end-to-end
- [ ] CAPEv2 sample submission returns results to MISP/IRIS (Phase 4)