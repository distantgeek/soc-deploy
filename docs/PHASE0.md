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

### Chosen: Netgear managed switch inline on the upstairs backhaul link

The network splits across two floors:

```
Basement:  Cable Modem ── GS-AX5400 (main router)
Upstairs:  RT-AC68U (AiMesh node) ◄── R820 + all other endpoints
           (RT-AC68U ↔ GS-AX5400 = 1 Gbps Ethernet backhaul)
```

All upstairs traffic (internet + cross-node) crosses the backhaul link. Put the Netgear managed switch **inline on that link** and mirror it to the sniffing port:

```
RT-AC68U backhaul ── port 1 ── [Netgear switch] ── port 2 ── GS-AX5400
                              port 3 (mirror) ── R820 nic1 (sniffing)
```

- Configure port mirroring: mirror port 1 (and/or 2) to port 3.
- Captures all traffic between the upstairs node and the rest of the network — internet in both directions plus cross-node LAN traffic. This includes the R820 itself.
- Does NOT capture same-node LAN-to-LAN traffic (endpoint A → endpoint B, both on the RT-AC68U, stays local and never crosses the backhaul). Internet traffic is the high-value visibility anyway.
- The switch must be **inline** on the backhaul link — a passive side-attachment sees nothing.

### Switch config (NetGear GS305E)

The GS305E is a 5-port Gigabit "Plus" managed switch — it supports port mirroring via its web UI. Only 3 of its 5 ports are needed.

- **Unmanaged by default:** wired inline it behaves as a plain switch, so the network works before any config. Mirroring is the only step needed.
- **Discovered:** 192.168.2.122 (DHCP on the LAN).
- **Port assignment:** Port 1 = RT-AC68U backhaul (mirror source), Port 2 = GS-AX5400, Port 3 = R820 `nic1` (mirror destination).
- **Mirror source:** mirror Port 1 only (both directions) — Port 2 carries the same link in reverse, so mirroring both would duplicate.
- **Factory reset (recommended after shelving):** hold the reset button ~10 s until the power LED blinks. Clears any stale config.
- **Access the web UI:** http://192.168.2.122. Login: `admin` / blank password (some firmware: `password`).
- **Enable port mirroring:** System > Monitoring > Port Mirroring (path varies by firmware). Destination = Port 3; source = Port 1. Both directions are mirrored.
- **Verify before building the VM:** on the Proxmox host, `tcpdump -i nic1` should show mirrored traffic.
- **Caveat:** the mirror destination port cannot carry normal traffic while mirroring is active — that's fine, it is dedicated to sniffing.

### Free fallback: Proxmox bridge mirroring (start now)

To get SO running today while the switch is located/wired: mirror the Proxmox bridge (OVS or `tc mirred`) to the SO VM's sniffing vNIC. Captures only VM-to-VM traffic on the host — no physical devices. Good for learning the platform.

## Prerequisites

- [ ] NetGear GS305E located (5-port Plus switch, supports port mirroring). Factory reset + configure via web UI.
- [ ] Confirm the RT-AC68U backhaul port and the GS-AX5400 port are accessible for the inline switch.
- [ ] R820 free port for sniffing: `nic1`/`nic2`/`nic3` are all free (confirmed via API — only `nic0` is used by vmbr0).
- [ ] R820 resources: 6.1 TB free on `garage-0` (confirmed via API); only one small VM running. RAM/CPU headroom is ample for the SO VM.

## Proxmox VM setup

### Dedicated sniffing port: bridge on the existing quad-port NIC

The R820 has a single 4-port NIC (`enp1s0f0-3`). `nic0` carries management (vmbr0); `nic1`/`nic2`/`nic3` are free. Dedicate one free port to sniffing via a dedicated bridge:

- Create `vmbrX` bound to one free port (e.g., `nic1`); attach the SO VM's second vNIC to it. Simple, no IOMMU setup.
- **PCIe passthrough is NOT viable here** — passing the NIC through would take all 4 ports, including management. The dedicated bridge is the right call.

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
| NIC 2 (sniffing) | virtio on `vmbrX` (dedicated bridge on `nic1`) |

## Proxmox host config

Disable NIC offloading on the sniffing interface (post-up in `/etc/network/interfaces` on the Proxmox host):

```
auto vmbrX
iface vmbrX inet static
    address 10.89.0.X/24
    bridge-ports nic1
    bridge-stp off
    bridge-fd 0
    post-up ethtool -K nic1 gro off gso off tso off
    post-up ethtool -K nic1 rx off tx off
    post-up ethtool -K nic1 rxvlan off txvlan off
    post-up ethtool -K nic1 ntuple off
```

(Proxmox 9 + virtual-NIC sniffing additionally requires `mtu 9000` on the physical sniffing NIC and bridge; with a dedicated physical NIC this is not needed.)

## Security Onion install

1. Upload the Security Onion 3.3.0 ISO to Proxmox storage; boot the VM from it.
2. Install Oracle Linux + Security Onion per the installer.
3. Run the setup wizard:
   - Management interface = NIC 1 (vmbr0)
   - Monitoring interface = NIC 2 (vmbrX)
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

1. Netgear switch inline on the RT-AC68U ↔ GS-AX5400 backhaul; mirror backhaul port(s) to the sniffing port → R820 `nic1`.
2. Proxmox: create `vmbrX` on `nic1`, disable offloads.
3. Create SO VM (settings above), install SO, run wizard.
4. Verify per checklist.