#!/bin/bash
# clear-ip.sh — remove a developer/admin/deployer account's source-IP
# restriction (see allow-ip.sh), reverting their key(s) to connect from
# anywhere. Takes effect on the very next connection attempt.
#
# Usage: clear-ip.sh <username>

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib"
# shellcheck source=../lib/common.sh
source "${LIB_DIR}/common.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <username>"; exit 1; }
USERNAME="$1"

require_root
id "$USERNAME" &>/dev/null || error "No such user: $USERNAME"

set_authorized_keys_from "$USERNAME" ""

info "Removed IP restriction for '$USERNAME' — can now connect from anywhere (still needs their key)."
