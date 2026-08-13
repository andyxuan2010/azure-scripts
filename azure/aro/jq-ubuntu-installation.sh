#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=aro-lib.sh
source "$SCRIPT_DIR/aro-lib.sh"

UPDATE=1
while (($#)); do
    case $1 in
        --no-update) UPDATE=0; shift ;;
        --help|-h)
            printf 'Usage: jq-ubuntu-installation.sh [--no-update]\n'
            exit 0
            ;;
        *) aro_die "Unknown argument: $1" ;;
    esac
done

if command -v jq >/dev/null 2>&1; then
    aro_log INFO "jq is already installed: $(jq --version)"
    exit 0
fi

aro_require_cmd apt-get
aro_require_cmd sudo
if ((UPDATE)); then
    sudo apt-get update
fi
sudo apt-get install --yes jq
aro_require_cmd jq
aro_log INFO "jq installation completed: $(jq --version)"
