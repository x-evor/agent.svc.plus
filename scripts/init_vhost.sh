#!/bin/bash
set -e

echo "[DEPRECATED] scripts/init_vhost.sh has been renamed to scripts/setup-proxy.sh"
exec "$(cd "$(dirname "$0")" && pwd)/setup-proxy.sh" "$@"
