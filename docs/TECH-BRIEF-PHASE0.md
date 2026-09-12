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

## 5. Verification checklist

- [ ] `so-status` shows all services green
- [ ] SOC console dashboards populate (Elasticsearch healthy)
- [ ] Zeek logs flowing (`conn.log` etc.)
- [ ] Suricata alerts fire on a test signal (`so-import-pcap` of a known-bad pcap)
- [ ] PCAP capture works (search + download a session from Hunt)
- [ ] No persistent Capture Loss on the sniffing interface

## Appendix A — Access details

| Resource | Access |
|---|---|
| Proxmox API | token in `~/.config/proxmox/token` (`opencode@pve!opencode0`) |
| Proxmox SSH | `ssh -i ~/.ssh/id_ed25519_pve_opencode root@192.168.2.2` |
| GS305E web UI | `http://192.168.2.122` (login `admin`/blank or `admin`/`password`) |

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