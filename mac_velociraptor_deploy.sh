#!/bin/bash
set -e

# === Velociraptor Agent macOS Installer Script ===
# Auto-detects architecture, downloads correct binary, installs, codesigns, and registers LaunchDaemon.
#
# Usage:
#   sudo ./velociraptor_installer.sh install               # auto-download
#   sudo ./velociraptor_installer.sh install /path/agent   # use local agent
#   sudo ./velociraptor_installer.sh uninstall

BASE_URL="http://emeraldmare.jdclabs.io:8080/mac"
AGENT_DEST="/usr/local/bin/velociraptor"
PLIST_PATH="/Library/LaunchDaemons/com.velociraptor.velociraptor.plist"
LOG_DIR="/var/log"
OUT_LOG="${LOG_DIR}/velociraptor.out.log"
ERR_LOG="${LOG_DIR}/velociraptor.err.log"

check_root() {
  if [[ "$EUID" -ne 0 ]]; then
    echo "❌ This script must be run as root. Please use sudo." >&2
    exit 1
  fi
}

download_agent() {
  ARCH=$(uname -m)
  case "$ARCH" in
    arm64)
      AGENT_FILE="velociraptor_agent_arm64"
      ;;
    x86_64)
      AGENT_FILE="velociraptor_agent_amd64"
      ;;
    *)
      echo "❌ Unsupported architecture: $ARCH" >&2
      exit 1
      ;;
  esac

  USER_HOME=$(eval echo ~${SUDO_USER})
  TMP_DL="${USER_HOME}/Downloads/${AGENT_FILE}"
  AGENT_URL="${BASE_URL}/${AGENT_FILE}"

  echo "🌐 Downloading ${AGENT_FILE} from ${AGENT_URL}..." >&2
  if curl -fsSL -o "$TMP_DL" "$AGENT_URL"; then
    chmod +x "$TMP_DL"
    echo "$TMP_DL"
  else
    echo "❌ Failed to download agent from $AGENT_URL" >&2
    exit 1
  fi
}

codesign_agent() {
  echo "🔐 Codesigning Velociraptor binary for macOS System Policy..."
  if codesign --force --deep --sign - "$AGENT_DEST"; then
    echo "✅ Codesigning completed successfully."
  else
    echo "❌ Codesigning failed. macOS may refuse to run the binary."
    exit 1
  fi
}

install_velociraptor() {
  AGENT_SRC="$1"

  if [[ -z "$AGENT_SRC" ]]; then
    AGENT_SRC=$(download_agent)
  elif [[ ! -f "$AGENT_SRC" ]]; then
    echo "❌ Error: '$AGENT_SRC' does not exist." >&2
    exit 1
  fi

  echo "📦 Installing Velociraptor client binary to $AGENT_DEST..."
  cp "$AGENT_SRC" "$AGENT_DEST"
  chmod 755 "$AGENT_DEST"

  codesign_agent

  echo "🗂 Creating log files..."
  touch "$OUT_LOG" "$ERR_LOG"
  chmod 644 "$OUT_LOG" "$ERR_LOG"

  echo "🛠 Creating LaunchDaemon plist at $PLIST_PATH..."
  cat <<EOF > "$PLIST_PATH"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.velociraptor.velociraptor</string>
  <key>ProgramArguments</key>
  <array>
    <string>${AGENT_DEST}</string>
    <string>client</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${OUT_LOG}</string>
  <key>StandardErrorPath</key>
  <string>${ERR_LOG}</string>
</dict>
</plist>
EOF

  chmod 644 "$PLIST_PATH"

  echo "🚀 Loading launch daemon..."
  launchctl unload "$PLIST_PATH" 2>/dev/null || true
  launchctl load "$PLIST_PATH"

  echo "⏳ Starting Velociraptor agent manually..."
  "${AGENT_DEST}" client &

  sleep 2

  if pgrep -f "${AGENT_DEST} client" > /dev/null; then
    echo "✅ Velociraptor agent is now running."
  else
    echo "❌ Velociraptor agent did not start correctly. Check logs:"
    echo "   - ${OUT_LOG}"
    echo "   - ${ERR_LOG}"
  fi
}

uninstall_velociraptor() {
  echo "🧹 Unloading and removing Velociraptor client..."

  if [[ -f "$PLIST_PATH" ]]; then
    launchctl unload "$PLIST_PATH" || true
    rm -f "$PLIST_PATH"
    echo "🗑 Removed LaunchDaemon plist."
  fi

  if [[ -f "$AGENT_DEST" ]]; then
    pkill -f "${AGENT_DEST} client" || true
    rm -f "$AGENT_DEST"
    echo "🗑 Removed binary from $AGENT_DEST."
  fi

  rm -f "$OUT_LOG" "$ERR_LOG"

  echo "✅ Velociraptor client uninstalled."
}

# --- Main ---
check_root

ACTION="$1"

case "$ACTION" in
  install)
    install_velociraptor "$2"
    ;;
  uninstall)
    uninstall_velociraptor
    ;;
  *)
    echo "Usage:"
    echo "  sudo $0 install               # auto-detect and download correct agent"
    echo "  sudo $0 install /path/agent   # use local binary"
    echo "  sudo $0 uninstall"
    exit 1
    ;;
esac
