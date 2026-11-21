#!/usr/bin/env bash
# Install or update the Arena dedicated server. Run ON the server (Debian/Ubuntu LXC) as root.
# Safe to run again: it only re-downloads the latest release and restarts the service.
#
#   ./install.sh                        # latest release
#   ARENA_VERSION=v0.3.0 ./install.sh   # a specific release tag
set -euo pipefail

REPO="Gunn1/arena-game"
INSTALL_DIR="/opt/arena"
UNIT_PATH="/etc/systemd/system/arena-server.service"
ARENA_VERSION="${ARENA_VERSION:-latest}"

if [[ "${ARENA_VERSION}" == "latest" ]]; then
    ZIP_URL="https://github.com/${REPO}/releases/latest/download/arena-server-linux.zip"
else
    ZIP_URL="https://github.com/${REPO}/releases/download/${ARENA_VERSION}/arena-server-linux.zip"
fi
UNIT_URL="https://raw.githubusercontent.com/${REPO}/main/deploy/arena-server.service"

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this as root." >&2
    exit 1
fi

# 1. Tools we need
missing=()
for cmd in curl unzip; do
    command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
done
if (( ${#missing[@]} )); then
    echo "Installing: ${missing[*]}"
    apt-get update -q
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${missing[@]}"
fi

# 2. Service user (no login shell, no home under /home)
if ! id -u arena >/dev/null 2>&1; then
    echo "Creating user arena"
    useradd --system --user-group --home-dir /var/lib/arena --no-create-home \
        --shell /usr/sbin/nologin arena
fi

# 3. Download and unpack into a temp dir, then move into place
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

echo "Downloading ${ZIP_URL}"
curl -fsSL --retry 3 -o "${tmp}/arena-server-linux.zip" "${ZIP_URL}"
unzip -tq "${tmp}/arena-server-linux.zip"
unzip -q -o "${tmp}/arena-server-linux.zip" -d "${tmp}/out"
test -f "${tmp}/out/arena-server.x86_64"

# Binary is owned by root and read-only for the service user.
install -d -m 0755 -o root -g root "${INSTALL_DIR}"
install -m 0755 -o root -g root "${tmp}/out/arena-server.x86_64" "${INSTALL_DIR}/arena-server.x86_64.new"
mv -f "${INSTALL_DIR}/arena-server.x86_64.new" "${INSTALL_DIR}/arena-server.x86_64"

# 4. systemd unit: use the copy next to this script if there is one, else fetch it from main
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [[ -f "${script_dir}/arena-server.service" ]]; then
    install -m 0644 -o root -g root "${script_dir}/arena-server.service" "${UNIT_PATH}"
else
    echo "Downloading ${UNIT_URL}"
    curl -fsSL --retry 3 -o "${tmp}/arena-server.service" "${UNIT_URL}"
    install -m 0644 -o root -g root "${tmp}/arena-server.service" "${UNIT_PATH}"
fi

systemctl daemon-reload
systemctl enable arena-server.service
systemctl restart arena-server.service

sleep 2
if systemctl is-active --quiet arena-server.service; then
    echo "arena-server is running. Logs: journalctl -u arena-server -f"
else
    echo "arena-server failed to start:" >&2
    journalctl -u arena-server -n 30 --no-pager >&2 || true
    exit 1
fi
