#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ---------- Inputs (from CloudFormation parameters / Environment) ----------
DOMAIN="${DomainName:-example.com}"
HOSTNAME="${Hostname:-vr01}"
OAUTH_CLIENT_ID="${OAuthClientID:-}"
OAUTH_CLIENT_SECRET="${OAuthClientSecret:-}"
TENANT_ID="${TenantID:-}"
USERLIST="${UserList:-}"                # comma-separated users (no spaces)
USER_PASSWORD="${UserPassword:-changeme}"
AWS_REGION="${AwsRegion:-us-east-1}"
VELOX_SECRET_NAME="VelociraptorAdminPassword-${Hostname}"
VELOX_USER="vradmin"
PORT_FRONTEND=443
PORT_GUI=8000

# ---------- Paths ----------
BASE_DIR="/opt/velociraptor"
PATH_CERTCACHE="/velociraptor/cert_cache"
PATH_CLIENTS="/velociraptor/clients"
PATH_DATASTORE="/velociraptor"
PATH_FILESTORE="/velociraptor"
PATH_LOG="/velociraptor/logs"
PATH_PUBLIC="public"

# ---------- Helpers ----------
log() { printf '%s %s\n' "$(date -Is)" "$*"; }
fatal() { log "FATAL: $*"; exit 1; }
retry() {
  local n=0 max=5 delay=3
  until "$@"; do
    ((n++))
    if (( n >= max )); then
      return 1
    fi
    log "Command failed — retry $n/$max in ${delay}s..."
    sleep $delay
  done
  return 0
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fatal "Required command not found: $1"
}

# trap to print a message if we exit due to error
trap 'rc=$?; if [[ $rc -ne 0 ]]; then log "Script failed with exit code $rc"; fi' EXIT

# ---------- Validate prerequisites ----------
for c in apt-get curl wget jq rsync nginx systemctl dpkg; do require_cmd "$c"; done || true
# (apt-get may not be present before install; below we install packages)

log "Starting velociraptor install on $HOSTNAME.$DOMAIN"

# Update and install packages (safe & noninteractive)
export DEBIAN_FRONTEND=noninteractive
retry apt-get update -y
retry apt-get install -y awscli curl wget jq rsync nginx ca-certificates

# Set hostname
if [[ "$(hostnamectl --static)" != "$HOSTNAME" ]]; then
  hostnamectl set-hostname "$HOSTNAME"
fi

# Create directories
mkdir -p "$BASE_DIR"
for arch in bsd linux mac windows; do mkdir -p "$BASE_DIR/$arch"; done
mkdir -p "$PATH_CERTCACHE" "$PATH_CLIENTS" "$PATH_DATASTORE" "$PATH_FILESTORE" "$PATH_LOG" "/velociraptor" "$BASE_DIR/tmp"

# Retrieve admin password from Secrets Manager (optional)
VELOX_PASS=""
if aws --version >/dev/null 2>&1; then
  if retry aws secretsmanager get-secret-value --secret-id "$VELOX_SECRET_NAME" --region "$AWS_REGION" --query SecretString --output text >/dev/null 2>&1; then
    VELOX_PASS=$(aws secretsmanager get-secret-value --secret-id "$VELOX_SECRET_NAME" --query SecretString --region "$AWS_REGION" --output text || true)
    log "Loaded admin password from Secrets Manager"
  else
    log "No secret found named $VELOX_SECRET_NAME in $AWS_REGION (continuing, using fallback password)"
    VELOX_PASS="${VELOX_PASS:-$USER_PASSWORD}"
  fi
else
  log "aws cli not available, using USER_PASSWORD"
  VELOX_PASS="${VELOX_PASS:-$USER_PASSWORD}"
fi
: "${VELOX_PASS:=$USER_PASSWORD}"   # final fallback

# ---------- Download latest release assets (with validation) ----------
GH_API="https://api.github.com/repos/velocidex/velociraptor/releases/latest"
log "Fetching release metadata from $GH_API"
release_json="$(retry curl -sSfL "$GH_API")" || fatal "Could not fetch release metadata"

get_asset_url() {
  local pattern="$1"
  printf '%s' "$release_json" | jq -r --arg p "$pattern" '.assets[].browser_download_url | select(contains($p))' | head -n1
}

BSD_BIN_AMD="$(get_asset_url 'freebsd-amd64' )"
LINUX_BIN_AMD="$(get_asset_url 'linux-amd64' )"
LINUX_BIN_AMD_MUSL="$(get_asset_url 'linux-amd64-musl' )"
LINUX_BIN_ARM="$(get_asset_url 'linux-arm64' )"
MAC_BIN_AMD="$(get_asset_url 'darwin-amd64' )"
MAC_BIN_ARM="$(get_asset_url 'darwin-arm64' )"
WINDOWS_EXE="$(get_asset_url 'windows-amd64.exe' )"
WINDOWS_MSI="$(get_asset_url 'windows-amd64.msi' )"

log "Discovered assets:"
log "  BSD: $BSD_BIN_AMD"
log "  LINUX: $LINUX_BIN_AMD"
log "  LINUX MUSL: $LINUX_BIN_AMD_MUSL"
log "  LINUX ARM: $LINUX_BIN_ARM"
log "  MAC AMD: $MAC_BIN_AMD"
log "  MAC ARM: $MAC_BIN_ARM"
log "  WINDOWS EXE: $WINDOWS_EXE"
log "  WINDOWS MSI: $WINDOWS_MSI"

dl() {
  local url="$1" out="$2"
  if [[ -z "$url" || "$url" == "null" ]]; then
    log "Skipping download (no URL): $out"
    return 0
  fi
  log "Downloading $url -> $out"
  retry curl -fSL --retry 5 --retry-delay 2 "$url" -o "$out" || return 1
  # quick sanity check
  if [[ ! -s "$out" ]]; then
    log "Download produced empty file: $out"
    return 1
  fi
  return 0
}

dl "$BSD_BIN_AMD" "$BASE_DIR/bsd/velociraptor_client_amd64" \
  || log "BSD binary missing or failed"
dl "$LINUX_BIN_AMD" "$BASE_DIR/linux/velociraptor_client_amd64" || fatal "Missing linux-amd64 client"
dl "$LINUX_BIN_AMD_MUSL" "$BASE_DIR/linux/velociraptor_client_amd64_musl" || true
dl "$LINUX_BIN_ARM" "$BASE_DIR/linux/velociraptor_client_arm64" || true
dl "$MAC_BIN_AMD" "$BASE_DIR/mac/velociraptor_client_amd64" || true
dl "$MAC_BIN_ARM" "$BASE_DIR/mac/velociraptor_client_arm64" || true
dl "$WINDOWS_EXE" "$BASE_DIR/windows/velociraptor_client.exe" || true
dl "$WINDOWS_MSI" "$BASE_DIR/windows/velociraptor_client.msi" || true

chmod +x "$BASE_DIR"/linux/velociraptor_client_amd64 || true

# Place the server binary in working directory so we can run ./velociraptor
cp -v "$BASE_DIR/linux/velociraptor_client_amd64" /usr/local/bin/velociraptor || true
chmod +x /usr/local/bin/velociraptor

# ---------- Build server config (YAML) ----------
SERVER_HOSTNAME="${HOSTNAME}.${DOMAIN}"
SERVER_CONFIG_PATH="/velociraptor/server.config.yaml"

log "Generating server config at $SERVER_CONFIG_PATH"

# Use a here-doc to create YAML. Include authenticator only if TENANT_ID is set.
cat > "$SERVER_CONFIG_PATH" <<EOF
autocert_cert_cache: "$PATH_CERTCACHE"
Frontend:
  public_path: "$PATH_PUBLIC"
  hostname: "$SERVER_HOSTNAME"
  bind_port: $PORT_FRONTEND
Logging:
  output_directory: "$PATH_LOG"
  separate_logs_per_component: true
Client:
  server_urls:
    - "https://$SERVER_HOSTNAME/"
Datastore:
  location: "$PATH_DATASTORE"
  filestore_directory: "$PATH_FILESTORE"
GUI:
  bind_address: "0.0.0.0"
  bind_port: $PORT_GUI
  public_url: "https://$SERVER_HOSTNAME"
EOF

if [[ -n "${TENANT_ID:-}" ]]; then
  cat >> "$SERVER_CONFIG_PATH" <<EOF

authenticator:
  type: azure
  oauth_client_id: "$OAUTH_CLIENT_ID"
  oauth_client_secret: "$OAUTH_CLIENT_SECRET"
  tenant: "$TENANT_ID"
  auth_redirect_template: "https://$SERVER_HOSTNAME/auth/azure/callback"
  default_roles_for_unknown_user:
    - investigator
EOF
  log "Appended azure authenticator to config"
fi

# set permissions
chown -R root:root /velociraptor || true
chmod 640 "$SERVER_CONFIG_PATH" || true

# ---------- Run velociraptor config generation steps ----------
cd /opt/velociraptor || true

log "Generating server config with velociraptor (this may produce artifacts dir)"
/usr/local/bin/velociraptor config generate --merge "$SERVER_CONFIG_PATH" > /dev/null 2>&1 || log "config generate returned non-zero (continuing)"

log "Generating client config"
if ! /usr/local/bin/velociraptor --config "$SERVER_CONFIG_PATH" config client > /velociraptor/client.config.yaml 2>/dev/null; then
  log "WARN: client config generation failed; will continue if client.config.yaml already exists"
fi

# Build deb package for Debian (if supported)
log "Attempting to build Debian package"
if /usr/local/bin/velociraptor --config "$SERVER_CONFIG_PATH" debian server --binary /usr/local/bin/velociraptor >/dev/null 2>&1; then
  log "Debian package built"
else
  log "Debian package build failed (continuing)"
fi

# Make sure admin user exists
log "Adding admin user '$VELOX_USER' (if not present)"
if ! /usr/local/bin/velociraptor --config "$SERVER_CONFIG_PATH" user list | grep -q "^$VELOX_USER\$"; then
  /usr/local/bin/velociraptor --config "$SERVER_CONFIG_PATH" user add "$VELOX_USER" "$VELOX_PASS" --role administrator || log "Failed to add admin user (may already exist)"
else
  log "Admin user $VELOX_USER already exists"
fi

# Collect artifacts (non-fatal)
log "Collecting Server.Import.ArtifactExchange artifacts"
/usr/local/bin/velociraptor --config "$SERVER_CONFIG_PATH" artifacts collect Server.Import.ArtifactExchange >/dev/null 2>&1 || log "Artifact collection returned non-zero"

# Remove any 'Red' artifact definitions if present (safe-fail)
if [[ -d artifact_definitions ]]; then
  find artifact_definitions -name "*Red*" -exec rm -f {} \; || true
fi

# If dpkg artifacts created, install them (safe)
if compgen -G "velociraptor*.deb" >/dev/null 2>&1; then
  dpkg -i velociraptor*.deb || log "dpkg install had issues (continuing)"
fi

# Repack clients for each platform if client.config.yaml exists
CLIENT_CFG="/velociraptor/client.config.yaml"
if [[ -f "$CLIENT_CFG" ]]; then
  repack_if_possible() {
    local exe="$1" out="$2" extra="$3"
    if [[ -x "$exe" ]]; then
      /usr/local/bin/velociraptor config repack --exe "$exe" "$CLIENT_CFG" "$out" || log "repack failed for $exe -> $out"
    else
      log "Skipping repack; executable not present: $exe"
    fi
  }
  repack_if_possible "$BASE_DIR/bsd/velociraptor_client_amd64" "$BASE_DIR/bsd/velociraptor_agent_amd64"
  repack_if_possible "$BASE_DIR/linux/velociraptor_client_amd64" "$BASE_DIR/linux/velociraptor_agent_amd64"
  repack_if_possible "$BASE_DIR/linux/velociraptor_client_amd64_musl" "$BASE_DIR/linux/velociraptor_agent_amd64_musl"
  repack_if_possible "$BASE_DIR/linux/velociraptor_client_arm64" "$BASE_DIR/linux/velociraptor_agent_arm64"
  repack_if_possible "$BASE_DIR/mac/velociraptor_client_amd64" "$BASE_DIR/mac/velociraptor_agent_amd64"
  repack_if_possible "$BASE_DIR/mac/velociraptor_client_arm64" "$BASE_DIR/mac/velociraptor_agent_arm64"
  repack_if_possible "$BASE_DIR/windows/velociraptor_client.exe" "$BASE_DIR/windows/velociraptor_agent.exe"
  # MSI repack (special)
  if [[ -f "$BASE_DIR/windows/velociraptor_client.msi" ]]; then
    /usr/local/bin/velociraptor config repack --msi "$BASE_DIR/windows/velociraptor_client.msi" "$CLIENT_CFG" "$BASE_DIR/windows/velociraptor_agent.msi" || log "msi repack failed"
  fi
else
  log "No client config at $CLIENT_CFG — skipping repack"
fi

# Copy prebuilt clients into clients directory (safe copy)
mkdir -p "$PATH_CLIENTS"/{bsd,linux,mac,windows}
rsync -a "$BASE_DIR/bsd/" "$PATH_CLIENTS/bsd/" || true
rsync -a "$BASE_DIR/linux/" "$PATH_CLIENTS/linux/" || true
rsync -a "$BASE_DIR/mac/" "$PATH_CLIENTS/mac/" || true
rsync -a "$BASE_DIR/windows/" "$PATH_CLIENTS/windows/" || true

# Nginx site (simple public listing)
NGINX_SITE="/etc/nginx/sites-available/${DOMAIN}"
cat > "$NGINX_SITE" <<NGCONF
server {
  listen 8080 default_server;
  server_name ${SERVER_HOSTNAME};
  root /opt/velociraptor;
  location / {
    autoindex on;
  }
}
NGCONF
rm -f /etc/nginx/sites-enabled/default
ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/"$DOMAIN"
systemctl reload nginx || log "nginx reload failed"

# Fix ownerships (try to be permissive but safe)
chown -R root:root /opt/velociraptor || true
chown -R velociraptor:velociraptor /velociraptor || true
chgrp -R www-data /opt/velociraptor || true
find /opt/velociraptor -name "*client" -exec rm -f {} \; || true
find /opt/velociraptor -name "*agent*" -exec chmod 644 {} \; || true

# ---------- Add users from CSV if provided ----------
if [[ -n "$USERLIST" ]]; then
  IFS=',' read -r -a user_array <<< "$USERLIST"
  for user in "${user_array[@]}"; do
    user_trimmed="$(echo "$user" | xargs)"  # trim whitespace
    if [[ -z "$user_trimmed" ]]; then continue; fi
    log "Adding user $user_trimmed as investigator"
    if ! /usr/local/bin/velociraptor --config "$SERVER_CONFIG_PATH" user add "$user_trimmed" "$USER_PASSWORD" --role investigator >/dev/null 2>&1; then
      log "WARN: failed to add user $user_trimmed (may already exist)"
    fi
  done
fi

log "Velociraptor setup finished (check logs and /velociraptor for outputs)."
exit 0