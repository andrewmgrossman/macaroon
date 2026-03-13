#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname "$0")" && pwd)
HELPER_DIR="${SCRIPT_DIR}/helper"

if [[ -n "${ROON_HELPER_NODE:-}" ]]; then
  exec "${ROON_HELPER_NODE}" "${HELPER_DIR}/src/index.mjs"
fi

if command -v node >/dev/null 2>&1; then
  exec node "${HELPER_DIR}/src/index.mjs"
fi

echo '{"event":"error.raised","payload":{"code":"helper.node_missing","message":"Node.js is not available. Set ROON_HELPER_NODE to a bundled runtime or install node for development."}}'
sleep 1
