#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/oc-cli-install-common.sh" \
    --install-root "$HOME/opt/openshift" \
    --persist-shell "${SHELL_RC:-$HOME/.bashrc}" "$@"
