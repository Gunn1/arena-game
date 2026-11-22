#!/usr/bin/env bash
# Give the web export's files versioned names (index.pck -> arena-0.5.4.pck, ...), so a browser
# can never mix a cached old game with a new page. Run after exporting to build/web.
#   usage: tools/version_web.sh build/web
set -euo pipefail
dir="${1:-build/web}"
ver="$(sed -n 's/^const GAME_VERSION := "\(.*\)"/\1/p' godot/scripts/config.gd)"
[[ -n "${ver}" ]] || { echo "no GAME_VERSION in config.gd"; exit 1; }
name="arena-${ver}"
cd "${dir}"
for f in index.js index.wasm index.pck index.audio.worklet.js index.audio.position.worklet.js; do
    [[ -f "${f}" ]] && mv -f "${f}" "${name}${f#index}"
done
sed -i -e "s/\"executable\":\"index\"/\"executable\":\"${name}\"/" \
       -e "s/\"index\.pck\":/\"${name}.pck\":/" -e "s/\"index\.wasm\":/\"${name}.wasm\":/" \
       -e "s/src=\"index\.js\"/src=\"${name}.js\"/" index.html
grep -q "\"executable\":\"${name}\"" index.html && grep -q "src=\"${name}.js\"" index.html
echo "web files renamed to ${name}.*"
