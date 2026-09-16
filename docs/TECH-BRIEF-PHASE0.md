# Tech Brief: Phase 0 — Security Onion on Proxmox (Reproduction Runbook)

Reproducible record of the Phase 0 setup: network mirror, Proxmox host changes, and (pending) the Security Onion VM. Every command below was executed and verified on 2026-09-12 unless marked pending.

## 1. Network topology

```
Basement:  Cable Modem ── GS-AX5400 (main router, 192.168.2.1)
Upstairs:  RT-AC68U (AiMesh node) ◄── R820 (Proxmox, 192.168.2.2) + all endpoints
           (RT-AC68U ↔ GS-AX5400 = 1 Gbps Ethernet backhaul)
```

Mirror point — NetGear GS305E inline on the backhaul link:

```
RT-AC68U backhaul ── Port 1 ── [GS305E] ── Port 2 ── GS-AX5400
                              Port 3 ── R820 nic1 (mirror destination)
```

- Switch: NetGear GS305E (5-port Gigabit "Plus" managed), IP 192.168.2.122 (DHCP).
- Port mirroring: source = Port 1 (both directions), destination = Port 3.
- The mirror destination port cannot carry normal traffic — it is dedicated to sniffing.
- Captures all traffic crossing the backhaul (internet both directions + cross-node LAN). Does NOT capture same-node LAN-to-LAN traffic on the RT-AC68U.

## 2. Proxmox host: sniffing bridge `vmbr1`

### 2.1 Host hardware (confirmed via API + SSH)

- Dell R820, node `kevbotpve-0`, Proxmox at 192.168.2.2.
- Single quad-port NIC: Broadcom BCM57800 (NetXtreme II), ports `nic0`–`nic3` (`enp1s0f0`–`enp1s0f3`).
- `nic0` → `vmbr0` (management, 192.168.2.2/24). `nic1` was free → dedicated to sniffing.
- Storage: ZFS pool `garage-0`, 6.1 TB free. Only VM: `open-atomic` (200).

### 2.2 Change to `/etc/network/interfaces`

Backup taken first, then the following stanza appended:

```
auto vmbr1
iface vmbr1 inet manual
	bridge-ports nic1
	bridge-stp off
	bridge-fd 0
	post-up ethtool -K nic1 gro off gso off tso off
	post-up ethtool -K nic1 rx off tx off
	post-up ethtool -K nic1 rxvlan off txvlan off
	post-up ethtool -K nic1 ntuple off
```

Notes:
- `inet manual` — the bridge carries no IP; it is a pure mirror feed.
- Offloads are disabled on the sniffing port (required for accurate capture).
- `rx-vlan-offload` is `on [fixed]` on the BCM57800 — a hardware limitation, not a blocker.

### 2.3 Commands to apply

```bash
# Backup
cp /etc/network/interfaces /etc/network/interfaces.bak.$(date +%Y%m%d%H%M%S)

# Append the vmbr1 stanza (see 2.2), then:
ifreload -a
```

`ifreload -a` (ifupdown2) applies the change without a reboot and without dropping the management connection.

### 2.4 Verification (all passed)

```bash
ip -br link show vmbr1      # UP, LOWER_UP
bridge link show vmbr1      # nic1 master vmbr1, state forwarding
ethtool -k nic1 | grep -E 'generic-receive-offload|generic-segmentation-offload|tcp-segmentation-offload|large-receive-offload'
                            # all: off
ip -s link show vmbr1       # RX counters incrementing (mirror feed live)
```

### 2.5 Root cause: bridge MAC learning starves the sniffing VM (FIXED 2026-09-15)

**Symptom:** the SO VM's monitor NIC (`ens19`/`bond0`) saw only broadcast/multicast — no unicast — even though the mirror feed was flowing into `nic1` (471 GB RX). Suricata/Zeek got no real traffic.

**Root cause:** a Linux bridge does MAC learning. Once it learned every LAN MAC on `nic1`, known-unicast frames were forwarded only to `nic1` (the ingress port → dropped) instead of being flooded to the VM's `tap300i1`. The VM only received broadcast/multicast + unknown unicast. The switch mirror was working all along.

**Fix:** disable MAC learning on the mirror ingress port so the bridge floods everything to the sniffing VM:

```bash
bridge link set dev nic1 learning off
bridge fdb del <mac> dev nic1 master   # clear stale entries (repeat per entry; they also age out in ~5 min)
```

**Persistent config** — added to the `vmbr1` stanza in `/etc/network/interfaces`:

```
	post-up bridge link set dev nic1 learning off
```

**Verification (2026-09-15):**
- `tap300i1` TX (into the VM) climbed from 139 MB to 200 MB within minutes of the fix.
- Suricata `eve` file began generating real unicast alerts: `GPL P2P BitTorrent transfer`, `GPL WEB_SERVER 403 Forbidden`, `ET DNS Query for .cc TLD`, `ET P2P BitTorrent DHT ping/announce_peers`.

## 3. Security Onion VM creation (DONE 2026-09-12)

### 3.1 Settings

| Setting | Value |
|---|---|
| VM ID / name | 300 / `soc-onion` |
| OS | Oracle Linux 9 (Security Onion 3.3.0 ISO) |
| CPU | `host` (required — SO needs host CPU flags) |
| vCPU | 8 |
| RAM | 16384 MB (16 GB) |
| Disk | 200 GB on `garage-0` |
| VGA | `vmware` (needed for NetworkMiner/Mono apps) |
| NIC 1 (management) | virtio, bridge `vmbr0` |
| NIC 2 (sniffing) | virtio, bridge `vmbr1` |
| Boot order | `ide2;scsi0` (CD first, then disk) |

### 3.2 Commands used

```bash
# Upload ISO (14 GB, ~2-3 min on gigabit LAN)
scp -i ~/.ssh/id_ed25519_pve_opencode \
  /home/kevbot/Downloads/securityonion-3.3.0-20260911.iso \
  root@192.168.2.2:/var/lib/vz/template/iso/

# Verify checksum on host (matches official 0938c73b76ce30ec9e4394d312c79ea7cac721b6818541697279a6221f7d870d)
sha256sum /var/lib/vz/template/iso/securityonion-3.3.0-20260911.iso

# Create VM — NOTE: quote the boot order; the semicolon is a shell separator
qm create 300 --name soc-onion --ostype l26 \
  --cpu host --cores 8 --memory 16384 \
  --scsi0 garage-0:200 \
  --vga vmware \
  --net0 virtio,bridge=vmbr0 \
  --net1 virtio,bridge=vmbr1 \
  --ide2 local:iso/securityonion-3.3.0-20260911.iso,media=cdrom \
  --boot 'order=ide2;scsi0'
```

Gotcha: an unquoted `--boot order=ide2;scsi0` truncates at the semicolon (shell separator) and silently sets `order=ide2` only. Fix with `qm set 300 --boot 'order=ide2;scsi0'`.

## 4. Security Onion install (pending)

1. Boot VM 300 from the ISO.
2. Install Oracle Linux + Security Onion per the installer.
3. Setup wizard:
   - Management interface = NIC 1 (vmbr0)
   - Monitoring interface = NIC 2 (vmbr1)
   - Analyst account, hostname, timezone
4. Reboot; confirm `so-status` all green.

## 5. Verification checklist (ALL PASSED 2026-09-16)

- [x] `so-status` shows all services green (24/24 containers running)
- [x] SOC console dashboards populate (Elasticsearch healthy)
- [x] Zeek logs flowing (`conn.log` etc.)
- [x] Suricata alerts fire on real unicast traffic (BitTorrent, 403s, DNS .cc)
- [x] PCAP capture works (`/nsm/suripcap/1/so-pcap.*`, 1GB files)
- [x] No persistent Capture Loss on the sniffing interface

## 6. PCAP cap + per-endpoint capture (2026-09-16)

### 6.1 Global PCAP cap lowered to 10GB

The default Suricata PCAP cap was 32GB (`max-files: 32`). Lowered to **10GB** to conserve disk:

- Edited `/opt/so/saltstack/local/pillar/minions/so-socdeploy_standalone.sls` → `suricata.pcap.maxsize: 10`
- Applied: `salt-call state.apply suricata.config` then `docker restart so-suricata`
- Verified: `max-files: 10` in `/opt/so/conf/suricata/suricata.yaml`; old files trimmed 32 → 10

### 6.2 `so-capture` — per-endpoint capture independent of the cap

Suricata's pcap capture is global; it has no per-IP retention exception. To capture **all** traffic for one endpoint regardless of the 10GB cap, a helper script was installed at `/usr/sbin/so-capture`:

```bash
sudo so-capture start <hostname-or-ip> [hours]   # default 24h retention
sudo so-capture stop <hostname-or-ip>
sudo so-capture stop-all
sudo so-capture status
```

- Resolves hostname → IP (or takes an IP directly)
- Writes to `/nsm/pcapout/<ip>/capture.pcap` — separate from the Suricata cap
- Rotates hourly, keeps `[hours]` files (default 24)
- Output dir is chowned to `tcpdump:tcpdump` (tcpdump drops privileges)
- Verified: captured real DNS traffic for 192.168.2.148; hostname resolution works

**Caveats:** hostname resolves once at start (restart if DHCP IP changes); on-demand only (no systemd service yet — see AGENTS.md).

## Appendix A — Access details

| Resource | Access |
|---|---|
| Proxmox API | token in `~/.config/proxmox/token` (`opencode@pve!opencode0`) |
| Proxmox SSH | `ssh -i ~/.ssh/id_ed25519_pve_opencode root@192.168.2.2` |
| GS305E web UI | `http://192.168.2.122` (login `admin`/blank or `admin`/`password`) |
| SO VM SSH | `ssh -i ~/.ssh/id_ed25519_so socadmin@192.168.2.50` |
| SO console | `https://192.168.2.50` (login `admin` / CONPASS from `.env`) |
| SO sudo | CONPASS from `.env` (`echo '$CONPASS' | sudo -S ...`) |

## Appendix B — Commands used to verify the mirror (2026-09-12)

```bash
# Link check (initially DOWN — port was administratively down; brought up, link negotiated)
ip link set nic1 up
ethtool nic1 | grep -E 'Speed|Duplex|Link detected'   # 1000Mb/s, Full, yes

# Traffic proof
timeout 8 tcpdump -i nic1 -c 10 -nn
# Saw: internet UDP both directions, ARP, STP from GS-AX5400 (04:42:1a:47:e1:88)
# → confirms inline backhaul mirror

# After bridge creation
ip -s link show vmbr1    # RX counters incrementing
```