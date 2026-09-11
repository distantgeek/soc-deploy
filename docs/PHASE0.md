# Phase 0 — Security Onion on Proxmox + Network Monitoring

Concrete steps to get Security Onion 3.3.0 running as a VM on the Dell R820 Proxmox host and ingesting a mirrored copy of network traffic.

## Goal

- Security Onion VM running on Proxmox (management + monitoring interfaces).
- Network traffic feeding Suricata/Zeek/PCAP from a passive copy — not inline.
- SOC console showing live alerts, Zeek logs, and working PCAP capture.

## Why passive monitoring cannot bottleneck your network

The pihole experience was inline: every DNS query was forced through the pihole instance, so it sat in the critical path and could (and did) become the bottleneck.

Security Onion is the opposite — it is **out-of-band**. The mirror port or TAP makes a *copy* of each frame and hands it to the sniffing NIC. The original frame continues on the normal forwarding path untouched. Nothing is routed through the SOC; endpoints never wait on it.

- Zero added latency to endpoints.
- Zero impact on forwarding if the SOC is down, overloaded, or unplugged.
- The only thing that can be "overloaded" is the SOC VM itself (CPU/disk). That degrades *capture fidelity* (dropped/missed frames), never endpoint performance — and SO reports capture loss so you know when it happens.

The real constraint is bandwidth, not load: the sniffing NIC must absorb the aggregate mirrored traffic. On a 1 Gbps WAN edge that is at most 1 Gbps; a dedicated gigabit NIC handles it, and drops only affect fidelity.

## Traffic source decision

The ASUS AiMesh routers (GS-AX5400 + RT-AC68U) are consumer gear — **no SPAN/port mirroring**. The mirror must happen outside them.

### Recommended: passive TAP at the WAN edge

Place a passive copper TAP inline between the modem and the GS-AX5400 WAN port. A passive TAP is a wire splitter: it passes traffic with zero added latency, is fail-open (the link survives even unpowered), and physically cannot bottleneck the link. Two ports feed the R820 sniffing NIC (one per direction).

- Captures all internet traffic in both directions — the highest-value visibility for a homelab SOC (C2, phishing, exfiltration).
- Does NOT see LAN-to-LAN traffic between your devices (that needs a managed LAN switch — later).
- Cost: ~$30–80.

### Alternative: managed switch with port mirroring

A cheap gigabit managed switch (TP-Link/Netgear/MikroTik, ~$30–50) between modem and router, mirroring the router-facing port to the sniffing port. More flexible than a TAP (can later mirror LAN ports too), but it sits in the data path — a gigabit switch won't bottleneck a 1 Gbps link, but it is one more inline device.

### Free fallback: Proxmox bridge mirroring (start now)

To get SO running today with zero hardware: mirror the Proxmox bridge (OVS or `tc mirred`) to the SO VM's sniffing vNIC. Captures only VM-to-VM traffic on the host — no physical devices, no WAN. Good for learning the platform while the TAP/switch ships.

## Prerequisites

- [ ] Confirm the modem→GS-AX5400 link is copper Ethernet and physically accessible (not a combo modem/router with an internal WAN).
- [ ] Identify a spare physical NIC/port on the R820 for sniffing.
- [ ] Confirm the R820 has 16–24 GB RAM and 200 GB+ free disk for the SO VM.
- [ ] Purchase the TAP (or managed switch) if going the WAN-edge route.

## Proxmox VM setup

### Dedicated sniffing NIC: bridge vs passthrough

A dedicated physical NIC is strongly preferred over a shared/virtual one — it isolates promiscuous mode and offload changes from all other traffic and avoids the virtio capture-loss quirks seen with virtual NIC sniffing.

- **Dedicated bridge (recommended):** create `vmbrX` bound to the spare physical port; attach the SO VM's second vNIC to it. Simple, no IOMMU setup.
- **PCIe passthrough (alternative):** pass the whole NIC through to the SO VM. Cleanest isolation and lowest overhead, but needs VT-d enabled and the NIC in its own IOMMU group (multi-port NICs often group all ports — check before committing).

### VM creation settings

| Setting | Value |
|---|---|
| OS | Linux (Oracle Linux 9 / generic) |
| CPU | `host` (required — SO needs the host CPU flags) |
| vCPU | 8 |
| RAM | 16–24 GB |
| Disk | 200 GB+ |
| Display | `VMware compatible (vmware)` — needed for NetworkMiner/Mono apps |
| NIC 1 (management) | virtio on `vmbr0` |
| NIC 2 (sniffing) | virtio on `vmbrX` (or passthrough) |

## Proxmox host config

Disable NIC offloading on the sniffing interface (post-up in `/etc/network/interfaces` on the Proxmox host):

```
auto vmbrX
iface vmbrX inet static
    address 10.89.0.X/24
    bridge-ports enoX
    bridge-stp off
    bridge-fd 0
    post-up ethtool -K enoX gro off gso off tso off
    post-up ethtool -K enoX rx off tx off
    post-up ethtool -K enoX rxvlan off txvlan off
    post-up ethtool -K enoX ntuple off
```

(Proxmox 9 + virtual-NIC sniffing additionally requires `mtu 9000` on the physical sniffing NIC and bridge; with a dedicated physical NIC this is not needed.)

## Security Onion install

1. Upload the Security Onion 3.3.0 ISO to Proxmox storage; boot the VM from it.
2. Install Oracle Linux + Security Onion per the installer.
3. Run the setup wizard:
   - Management interface = NIC 1 (vmbr0)
   - Monitoring interface = NIC 2 (vmbrX / passthrough)
   - Analyst account, hostname, timezone
4. Reboot; confirm services start (`so-status`).

## Verification checklist

- [ ] `so-status` shows all services green
- [ ] SOC console dashboards populate (Elasticsearch healthy)
- [ ] Zeek logs flowing (`conn.log` etc.)
- [ ] Suricata alerts fire on a test signal (`so-import-pcap` of a known-bad pcap, or a test rule)
- [ ] PCAP capture works (search + download a session from Hunt)
- [ ] No persistent Capture Loss on the sniffing interface

## Wiring order

1. TAP/switch inline between modem and GS-AX5400 → sniffing NIC on R820.
2. Proxmox: create `vmbrX`, disable offloads.
3. Create SO VM (settings above), install SO, run wizard.
4. Verify per checklist.