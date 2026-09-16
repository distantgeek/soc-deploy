# Tech Brief: Phase M0 — soc-host VM + Mirror NIC (DONE 2026-09-16)

Reproducible record of creating the `soc-host` VM (400) on Proxmox and wiring the mirror NIC for Malcolm capture. Verified by the network-engineer subagent (Option A direct capture + Option C overlap).

## 1. VM creation

- **VMID:** 400, name `soc-host`
- **Spec:** 8 vCPU / 16 GB RAM / 200 GB disk (bumped from 4/8/100 per network-engineer review)
- **OS:** Fedora Cloud Base 43-1.6 (cloud-init image, not DVD install)
- **Disk:** `garage-0` zfspool (5TB free)
- **Network:**
  - `net0` → `vmbr0` (management, 192.168.2.51/24, gw 192.168.2.1)
  - `net1` → `vmbr1` (mirror, `firewall=0`)
- **cloud-init:** user `socadmin` / CONPASS / SSH key `id_ed25519_so`

Commands:
```bash
qm create 400 --name soc-host --memory 16384 --cores 8 --sockets 1 \
  --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-pci --ostype l26
qm importdisk 400 /var/lib/vz/template/iso/Fedora-Cloud-Base-Generic-43-1.6.x86_64.qcow2 garage-0
qm set 400 --scsi0 garage-0:vm-400-disk-0 --ide2 garage-0:cloudinit \
  --boot order=scsi0 --serial0 socket --vga serial0
qm resize 400 scsi0 200G
qm set 400 --net1 virtio,bridge=vmbr1,firewall=0
qm set 400 --ciuser socadmin --cipassword '<CONPASS>' \
  --ipconfig0 ip=192.168.2.51/24,gw=192.168.2.1 --nameserver 192.168.2.1 --sshkeys <pubkey>
qm start 400
```

## 2. Mirror NIC config (ens19)

The mirror NIC must be **IP-less, promiscuous, offloads off** (per network-engineer review — PVE firewall would drop mirror frames, so `firewall=0`).

```bash
# Remove cloud-init's DHCP IP; create an IP-less NM connection
nmcli con add type ethernet ifname ens19 con-name mirror
nmcli con modify mirror ipv4.method disabled ipv6.method disabled
nmcli con up mirror

# Promisc + offloads off
ip link set ens19 promisc on
ethtool -K ens19 gro off gso off tso off lro off
```

**Persistence:** `/etc/NetworkManager/dispatcher.d/50-mirror-nic.sh` re-applies promisc + offloads on `ens19` up (survives reboot).

## 3. Verification

- `tcpdump -i ens19 -nn -c 15` → **real unicast traffic** (192.168.2.27→HTTPS, 192.168.2.46→router, etc.), 0 packets dropped
- Confirms the vmbr1 bridge floods the mirror feed to BOTH taps (SO VM + soc-host) simultaneously — MAC learning off on `nic1` makes every mirrored unicast frame flood to all ports
- ens19: IP-less, `PROMISC`, gro/gso/tso/lro all off
- eth0: 192.168.2.51/24 (management), SSH via `id_ed25519_so`

## 4. Next steps (M1)

- Deploy Malcolm on soc-host (clone `cisagov/Malcolm`, apply `malcolm/filebeat-patch.sh` wolfi swap, `docker compose up`)
- Configure Malcolm live capture on `ens19`
- Overlap with SO for a few days (Option C), cross-check Suricata/Zeek parity, then decommission SO