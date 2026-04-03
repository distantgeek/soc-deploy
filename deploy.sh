#!/bin/bash
# =============================================================================
# SOC Stack — Elastic Pod Deployment
# Run as root on Fedora Server 43.
#
# What this does:
#   1. Prompts for credentials and stores them as Podman secrets
#   2. Sets required kernel parameters
#   3. Creates and chowns volume directories
#   4. Installs Quadlet units and reloads systemd
#
# Vault migration: when ready, replace the Podman secret creation block with
# a Vault agent that writes secrets into the container environment. The Quadlet
# unit files do not need to change.
# =============================================================================

set -euo pipefail

QUADLET_DIR="/etc/containers/systemd"
FILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Preflight ────────────────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
  echo "Error: must be run as root." >&2
  exit 1
fi

echo ""
echo "SOC Stack — Elastic Pod Deployment"
echo "==================================="
echo ""

# ── Helper: prompt for password with confirmation and minimum length ──────────

prompt_password() {
  local prompt="$1"
  local password confirm

  while true; do
    read -rsp "  ${prompt}: " password; echo ""
    read -rsp "  Confirm:  " confirm;  echo ""

    if [[ "$password" != "$confirm" ]]; then
      echo "  Passwords do not match. Try again."; continue
    fi
    if [[ ${#password} -lt 12 ]]; then
      echo "  Must be at least 12 characters. Try again."; continue
    fi
    break
  done

  printf '%s' "$password"
}

# ── Helper: generate a 32-char alphanumeric key ───────────────────────────────

generate_key() {
  openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 32
  echo ""
}

# ── Step 1: Podman secrets ───────────────────────────────────────────────────

echo "==> [1/4] Creating Podman secrets..."
echo ""
echo "  The elastic_password becomes the 'elastic' superuser password."
echo "  It is used by both Elasticsearch and Kibana."
echo ""

# Remove existing secrets if present (allows redeployment / rotation)
for secret in elastic_password kibana_enc_key1 kibana_enc_key2 kibana_enc_key3; do
  if podman secret inspect "$secret" &>/dev/null; then
    podman secret rm "$secret" > /dev/null
    echo "  Removed existing secret: $secret"
  fi
done

ELASTIC_PASS=$(prompt_password "Elastic password")
printf '%s' "$ELASTIC_PASS" | podman secret create elastic_password -
echo "    Created secret: elastic_password"

echo ""
echo "  Generating Kibana encryption keys..."
printf '%s' "$(generate_key)" | podman secret create kibana_enc_key1 -
echo "    Created secret: kibana_enc_key1"
printf '%s' "$(generate_key)" | podman secret create kibana_enc_key2 -
echo "    Created secret: kibana_enc_key2"
printf '%s' "$(generate_key)" | podman secret create kibana_enc_key3 -
echo "    Created secret: kibana_enc_key3"

echo ""
echo "  IMPORTANT: Podman secrets are stored in:"
echo "  /var/lib/containers/storage/secrets/"
echo "  Back this directory up securely — losing it means re-running this script."
echo ""

# ── Step 2: Kernel parameters ────────────────────────────────────────────────

echo "==> [2/4] Setting kernel parameters..."

cat > /etc/sysctl.d/99-elasticsearch.conf << 'EOF'
vm.max_map_count=262144
EOF
sysctl -p /etc/sysctl.d/99-elasticsearch.conf
echo "    vm.max_map_count=262144 applied and persisted."

# ── Step 3: Volume directories ───────────────────────────────────────────────

echo ""
echo "==> [3/4] Creating volume directories..."

mkdir -p /opt/soc/elasticsearch/{data,logs}
mkdir -p /opt/soc/kibana/data

# Elasticsearch and Kibana run as UID 1000 inside the container.
# Without this the JVM cannot write logs and crashes immediately.
chown -R 1000:1000 /opt/soc/elasticsearch/
chown -R 1000:1000 /opt/soc/kibana/

echo "    /opt/soc/elasticsearch/data  (owner: 1000)"
echo "    /opt/soc/elasticsearch/logs  (owner: 1000)"
echo "    /opt/soc/kibana/data         (owner: 1000)"

# ── Step 4: Quadlet units ────────────────────────────────────────────────────

echo ""
echo "==> [4/4] Installing Quadlet units and reloading systemd..."

cp "$FILES_DIR"/soc-net.network \
   "$FILES_DIR"/soc-elastic.pod \
   "$FILES_DIR"/soc-elasticsearch.container \
   "$FILES_DIR"/soc-kibana.container \
   "$QUADLET_DIR/"

systemctl daemon-reload

# ── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo "==================================="
echo "Deployment complete."
echo ""
echo "Start the stack:"
echo ""
echo "    systemctl start soc-elasticsearch.service soc-kibana.service"
echo ""
echo "Verify (wait ~2 minutes after start):"
echo ""
echo "    systemctl status soc-elasticsearch.service soc-kibana.service"
echo "    podman pod ps"
echo "    curl -u elastic:YOURPASSWORD http://localhost:9200"
echo ""
echo "Kibana:"
echo ""
echo "    http://$(hostname -I | awk '{print $1}'):5601"
echo "    Login: elastic / <your password>"
echo ""
