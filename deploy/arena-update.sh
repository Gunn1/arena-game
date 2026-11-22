#!/usr/bin/env bash
# Keep the server on the latest release. Run by arena-update.timer every 5 minutes.
# Only updates when nobody is connected, so it never kills a match in progress.
set -euo pipefail

REPO="Gunn1/arena-game"
STATE=/opt/arena/VERSION
latest="$(curl -fsSL --retry 2 "https://api.github.com/repos/${REPO}/releases/latest" \
    | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
[[ -n "${latest}" ]] || { echo "could not read the latest release"; exit 0; }
current="$(cat "${STATE}" 2>/dev/null || echo none)"
[[ "${latest}" == "${current}" ]] && exit 0

players="$(ss -Htn state established '( sport = :7777 )' | wc -l)"
if (( players > 0 )); then
    echo "${latest} is out (running ${current}), but ${players} player(s) connected: trying again later"
    exit 0
fi

echo "updating ${current} -> ${latest}"
ARENA_VERSION="${latest}" /opt/arena/install.sh
echo "${latest}" > "${STATE}"
