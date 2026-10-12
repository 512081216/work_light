#!/bin/sh
set -eu
bridge_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -x /opt/homebrew/bin/node ]; then
  bridge_node=/opt/homebrew/bin/node
elif [ -x /Users/tan/.nvm/versions/node/v20.20.1/bin/node ]; then
  bridge_node=/Users/tan/.nvm/versions/node/v20.20.1/bin/node
else
  bridge_node=$(command -v node)
fi
exec "$bridge_node" "$bridge_dir/codex-runtime-bridge.js" "$@"
