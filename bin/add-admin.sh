#!/bin/bash
# add-admin.sh — thin wrapper around add-developer.sh: onboard a full-sudo
# ADMIN account instead of a whitelisted developer one. Mirrors
# add-developer.sh's usage exactly (same flags: --name, --pubkey, --no-key,
# --print-key, --allow-from) — only the group differs.
#
# Admins get unrestricted sudo (equivalent to the default 'ubuntu' cloud-init
# user), but their SSH sessions are STILL forced through the same recorder as
# developers (see the 'Match Group developer,admin' block in sshd_config) —
# more privilege, same audit trail.
#
# Usage: add-admin.sh <username> [--name "Display Name"] [--pubkey <file>|-] [--no-key] [--print-key] [--allow-from <ip-or-cidr>[,...]]

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${DIR}/.." && pwd)/lib"
# shellcheck source=../lib/common.sh
source "${LIB_DIR}/common.sh"
exec "${DIR}/add-developer.sh" "$@" --group "$AT_ADMIN_GROUP"
