# Tech Brief: Phase 1 — Security Onion Install Completion (x86-64-v3 Workaround)

Reproducible record of completing the Security Onion 3.3.0 install on VM 300 (`so-socdeploy`, 192.168.2.50) after the stock `so-elastic-fleet` container failed on the host's Ivy Bridge CPU. Every command below was executed and verified on 2026-09-13.

## 1. Problem

The post-reboot SO setup wizard failed at the Elastic Fleet step. The `so-elastic-fleet` container crash-looped with:

```
Fatal glibc error: CPU does not support x86-64-v3
```

- Host CPU: `Intel(R) Xeon(R) CPU E5-4650 v2 @ 2.40GHz` (Ivy Bridge) — has `avx f16c` but **no `avx2`**.
- x86-64-v3 requires AVX2. Elastic moved the `elastic-agent` image base from UBI 9 to **UBI 10** in beats 9.4.3 (PR #51377); UBI 10's glibc is compiled for x86-64-v3.
- Upstream tracking issue: [elastic/beats#51824](https://github.com/elastic/beats/issues/51824). Elastic's position: "UBI10 is the standard we need to align on everywhere now." No fix planned.

## 2. Investigation

### 2.1 SO image is stock Elastic (not a custom build)

`~/SecurityOnion/salt/elasticfleet/enabled.sls` line 44 references the image as:

```
{{ GLOBALS.registry_host }}:5000/{{ GLOBALS.image_repo }}/so-elastic-agent:{{ GLOBALS.so_version }}
```

SO's `so-elastic-agent` Dockerfile is a single line:

```dockerfile
FROM docker.elastic.co/elastic-agent/elastic-agent:$VERSION
```

SO re-tags the stock Elastic image as `so-elastic-agent:3.3.0` and serves it from the local registry. No custom build, no added layers.

### 2.2 Binary analysis — only the base OS is the problem

Extracted and ran `readelf` on every binary in the image:

| Binary | glibc requirement | x86-64-v3? |
|---|---|---|
| `elastic-agent` | 2.3.2 (libc, libpthread, libdl, libresolv) | No |
| `fleet-server` | static | No |
| `apm-server`, `pf-*`, `cloudbeat`, `cloud-defend`, `elastic-otel-collector`, `endpoint-security` | static or ≤2.17 | No |

All Go components are v2-compatible. Only the **UBI 10 base OS glibc** requires x86-64-v3.

### 2.3 Container topology — only fleet is UBI 10

23 of 24 containers run fine. Only `so-elastic-fleet` (UBI 10) fails:

| Base OS | Containers |
|---|---|
| UBI 9 | elasticsearch, kibana, logstash, soc, kratos, elastalert, postgres, suricata, zeek, strelka-backend |
| Alpine | nginx, redis, strelka-manager, telegraf |
| Debian 12 | influxdb |
| Chainguard | fleet-package-registry |
| **UBI 10** | **so-elastic-fleet (BLOCKED)** |

### 2.4 The fix: Elastic's official Wolfi variant

Elastic ships a hardened Wolfi/Chainguard variant of the same image: `docker.elastic.co/elastic-agent/elastic-agent-wolfi:9.4.5`.

Verified on the v2-only CPU:
- `elastic-agent version` → starts successfully (agent 9.4.5)
- `fleet-server --version` → exit 0
- Identical layout, entrypoint (`/usr/bin/tini -- /usr/local/bin/docker-entrypoint`), user (uid 1000), workdir, env, and components as the UBI image.
- Wolfi is Elastic's **hardened** variant (fewer CVEs) — the one they recommend.

## 3. The swap (executed)

All commands as `root` on the SO VM (via `sudo -S` over SSH).

### 3.1 Pull, tag, push wolfi image to local registry

```bash
docker tag docker.elastic.co/elastic-agent/elastic-agent-wolfi:9.4.5 \
  so-socdeploy:5000/security-onion-solutions/so-elastic-agent:3.3.0

docker push so-socdeploy:5000/security-onion-solutions/so-elastic-agent:3.3.0
```

Output confirms the local registry now serves the wolfi image:

```
3.3.0: digest: sha256:29f5e64d97fd334bb7963d76449aa2940472d51110fd22200b1adea7eb16bff2 size: 3671
```

### 3.2 Generate the missing fleet certs

The failed setup left `/etc/pki/elasticfleet-server.key` without its `.crt`. Salt's `elasticfleet.ssl` state generates it:

```bash
salt-call state.apply elasticfleet.ssl
# Succeeded: 18, Failed: 0
ls -la /etc/pki/elasticfleet-server.crt   # now present
```

### 3.3 Recreate the fleet container via salt

```bash
docker rm -f so-elastic-fleet
salt-call state.apply elasticfleet.enabled
```

The state pulls the (now-wolfi) image from the local registry, starts the container, and waits for `https://localhost:8220/api/status` (up to 300 s). The container enrolled successfully:

```
{"log.level":"info",...,"message":"Elastic Agent successfully enrolled",...}
{"name":"fleet-server","status":"HEALTHY"}
```

Verify the running image is wolfi:

```bash
docker exec so-elastic-fleet cat /etc/os-release
# NAME="Wolfi"  ID=wolfi
```

## 4. Remaining setup steps (executed)

The wizard had failed at `so-elastic-fleet-setup` (line 796 of `~/SecurityOnion/setup/so-setup`). After the container was healthy:

### 4.1 Fleet setup

```bash
so-elastic-fleet-setup
```

This deletes stale `.fleet-*` indices, restarts Kibana, creates the ES service token, and installs the core fleet packages (`elastic_agent`, `elasticsearch`, `endpoint`, `fleet_server`, `filestream`, `http_endpoint`, `httpjson`, `log`, `osquery_manager`, `redis`, `system`, `tcp`, `udp`, `windows`, `winlog`). Takes ~10 min (Kibana restarts + package installs).

### 4.2 Post-fleet steps from the wizard

```bash
mark_setup_complete
# (sources /usr/sbin/so-common)
initialize_elasticsearch_indices "so-case so-casehistory so-assistant-session so-assistant-chat"
```

### 4.3 Final highstate

```bash
salt-call state.highstate -l info
# Succeeded: 1935 (changed=48), Failed: 0
# Total run time: 1562.594 s (~26 min)
```

### 4.4 Enable scheduled highstates

```bash
salt-call schedule.enable -linfo --local
# Enabled schedule on minion.
```

### 4.5 Setup marker + boot service

The `mark_setup_complete` salt state is gated on `startup_states: highstate` being present in `/etc/salt/minion` (the wizard normally sets it, then removes it). Because the wizard was interrupted, the marker was never created. Fix:

```bash
echo "startup_states: highstate" >> /etc/salt/minion
salt-call state.apply salt.minion.boot_highstate
# Succeeded: 4 (changed=2) — created /opt/so/state/setup-complete, enabled so-boot-highstate.service
```

### 4.6 Verify

```bash
./so-verify standalone   # exit 0
so-status                # all 24 containers running; "This onion is ready to make your adversaries cry!"
curl -sk https://localhost:8220/api/status   # {"name":"fleet-server","status":"HEALTHY"}
```

## 5. Troubleshooting log

### 5.1 Pillar failed to render — duplicate YAML keys

After the fleet setup, `salt-call state.highstate` failed with:

```
Rendering SLS 'global.soc_global' failed. Please see master log for details.
Rendering SLS 'minions.so-socdeploy_standalone' failed. Please see master log for details.
```

**Cause:** the two `so-elastic-fleet-setup` runs (failed during initial setup, successful after the swap) each appended a token block to the pillar files, producing **duplicate top-level YAML keys**:

- `/opt/so/saltstack/local/pillar/global/soc_global.sls` — `fleet_grid_enrollment_token_general` and `_heavy` appeared twice.
- `/opt/so/saltstack/local/pillar/minions/so-socdeploy_standalone.sls` — the whole `elasticfleet:` block appeared twice.

Salt's YAML loader rejects duplicate keys (PyYAML silently keeps the last). **Fix:** rewrite both files keeping only the last (newest) token block:

```bash
python3 - <<'EOF'
import yaml
for path in [
    "/opt/so/saltstack/local/pillar/global/soc_global.sls",
    "/opt/so/saltstack/local/pillar/minions/so-socdeploy_standalone.sls",
]:
    with open(path) as f:
        data = yaml.safe_load(f)   # keeps last duplicate
    with open(path, "w") as f:
        yaml.safe_dump(data, f, default_flow_style=False, sort_keys=False)
EOF
```

Verify with `salt-call pillar.items` (no errors) and `salt-call state.show_top`.

### 5.2 Salt-call "running as PID" lock

After the highstate completed, a stale `salt-call state.highstate` process kept the state lock. Symptom:

```
The function "state.highstate" is running as PID 1425231 ...
```

**Fix:** kill the hung process and clear the proc files:

```bash
kill -9 <PID>
rm -f /var/cache/salt/minion/proc/<jid>
```

### 5.3 `mark_setup_complete` skipped — "onlyif condition is false"

The `mark_setup_complete` state (in `salt/minion/boot_highstate.sls`) is gated on `grep -qx 'startup_states: highstate' /etc/salt/minion` for managers. The interrupted wizard never set it. Fix documented in §4.5.

### 5.4 SSH timeouts during long salt states

`so-elastic-fleet-setup` and `state.highstate` exceed the 120 s SSH command timeout. Run them detached and poll:

```bash
nohup salt-call state.highstate -l info > /tmp/highstate.log 2>&1 &
# poll: ps aux | grep "salt-call state.highstate"
#       tail /tmp/highstate.log
```

### 5.5 Web console unreachable from the LAN

`https://192.168.2.50` worked from the VM itself but timed out from the workstation (TCP 443 unreachable; ping OK). **Cause:** the wizard's `set_initial_firewall_access` (a function inside `so-setup`, not run in standalone mode) never ran, so the SO iptables INPUT chain dropped everything except SSH, docker, localhost, and self. **Fix** — add the browser access range to the `analyst` hostgroup and apply:

```bash
so-firewall includehost analyst 192.168.2.0/24 --apply
```

This updates `/opt/so/saltstack/local/pillar/firewall/soc_firewall.sls` (`analyst: [192.168.2.0/24]`) and triggers a salt state that inserts `ACCEPT tcp 192.168.2.0/24 dpt:80/443` into the `DOCKER-USER` chain. Note: `--apply` queues behind any running highstate (observed ~30 min wait). Verify from the workstation:

```bash
curl -sk https://192.168.2.50/   # 302 -> /auth/self-service/login/browser -> 200 login page
```

## 6. Update risk — the wolfi swap is not persistent

`soup` (Security Onion Update) calls `update_docker_containers()` in `/usr/sbin/so-image-common`, which **always** re-pulls `ghcr.io/security-onion-solutions/so-elastic-agent:$VERSION`, GPG-verifies it, and pushes it to the local registry via `docker buildx imagetools create`. This overwrites the wolfi swap on every update.

**Implications:**
- After any `soup` run, the fleet container will crash-loop again until §3 is re-applied.
- **Mitigation implemented:** a native salt healthcheck hook (see §7) detects the image revert within 5 minutes and auto-heals it (re-pulls the wolfi image by digest from the local registry, re-tags it, and recreates the container via `elasticfleet.enabled`). No manual action needed after updates.
- Remaining options if the hook is ever removed:
  1. **Manual re-apply** after each update (documented in §3).
  2. **Hardware migration** to an AVX2-capable host — the cleanest long-term fix; the VM disk is ready to move.
- Upstream: [elastic/beats#51824](https://github.com/elastic/beats/issues/51824) tracks the UBI 10 change. If Elastic reverts or provides a v2-compatible base, the swap becomes unnecessary.

## 7. Native monitoring hook — auto-detect + auto-heal the swap

SO ships a salt **healthcheck** framework (pillar `healthcheck`, state `healthcheck`, module `healthcheck.run`) that runs a configurable list of checks on a schedule. It is normally disabled. We enabled it and added a custom `fleet_image` check that verifies the `so-elastic-fleet` container is still running the wolfi image.

### 7.1 How it works

- `healthcheck` state (`/opt/so/saltstack/default/salt/healthcheck/init.sls`) creates a salt schedule entry `healthcheck` → `healthcheck.run` every N seconds when `healthcheck.enabled` is true and `healthcheck.checks` is non-empty.
- `healthcheck.run` (`/opt/so/saltstack/default/salt/_modules/healthcheck.py`) iterates the checks and only executes functions in its `allowed_functions` allowlist.
- Our **local override** of the module adds a `fleet_image` check. Because `file_roots` lists `/opt/so/saltstack/local/salt` **before** `/opt/so/saltstack/default/salt`, the local copy wins and survives `soup` (the `local/` tree is never touched by updates).

### 7.2 Deployed files (in the `local/` override tree)

| File | Purpose |
|---|---|
| `/opt/so/saltstack/local/salt/_modules/healthcheck.py` | Copy of the stock module + `fleet_image` check (added to `allowed_functions`) |
| `/opt/so/saltstack/local/pillar/healthcheck/standalone.sls` | Enables healthcheck, schedule 300 s, checks `[zeek, fleet_image]`, expected image ID + `heal: True` |

The `fleet_image` check:
1. `docker.inspect_container('so-elastic-fleet')` and compares `Image` (image ID) to the expected wolfi ID `sha256:c786ed0c…`.
2. On match → publishes event `so/healthcheck/fleet_image` with `{'fleet_image': 'ok'}`.
3. On mismatch → logs a warning, publishes `{'fleet_image': 'mismatch', ...}`, and if `heal: True`:
   - `docker.pull` the wolfi image by digest from the local registry (`so-socdeploy:5000/…@sha256:29f5e64d…` — content-addressed, so it survives the tag being overwritten),
   - `docker.tag` it back to `so-socdeploy:5000/security-onion-solutions/so-elastic-agent:3.3.0`,
   - remove the container and `state.apply('elasticfleet.enabled')` to recreate it (same as §3.3).

### 7.3 Deploy / verify commands

```bash
# deploy (files already in place on this VM)
salt-call saltutil.sync_all                 # load the local module override
salt-call state.apply healthcheck           # creates + enables the schedule

# verify
salt-call healthcheck.run                   # -> ['zeek', 'fleet_image']
salt-call healthcheck.fleet_image           # -> [{'fleet_image': 'ok', 'image': 'so-socdeploy:5000/…:3.3.0'}]
salt-call schedule.list | grep -A6 healthcheck
grep -A6 'healthcheck:' /etc/salt/minion.d/_schedule.conf   # persisted across reboot
```

Monitoring signal: the `so/healthcheck/fleet_image` event on the salt master event bus (`salt-run state.event`), plus a `healthcheck_module: fleet_image mismatch` warning in `/opt/so/log/salt/minion`.

## 8. Access details

| Resource | Access |
|---|---|
| SO VM SSH | `ssh -i ~/.ssh/id_ed25519_so socadmin@192.168.2.50` |
| SO console | `https://192.168.2.50` (browser access range `192.168.2.0/24`) |
| `socadmin` sudo password | `/tmp/so_vnc/socadmin_pw.txt` |
| Proxmox SSH | `ssh -i ~/.ssh/id_ed25519_pve_opencode root@192.168.2.2` |