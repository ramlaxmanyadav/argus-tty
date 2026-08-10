#!/bin/bash
# list-ip.sh — show the current source-IP restriction (see allow-ip.sh) for
# one account, or every developer/admin/deployer account if none given.
#
# Usage: list-ip.sh [username]

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib"
# shellcheck source=../lib/common.sh
source "${LIB_DIR}/common.sh"

require_root

show_one() {
  local u="$1" home auth_keys restriction
  home="$(getent passwd "$u" | cut -d: -f6)"
  auth_keys="${home}/.ssh/authorized_keys"
  restriction="(no keys installed)"
  if [[ -s "$auth_keys" ]]; then
    restriction="$(grep -oE 'from="[^"]*"' "$auth_keys" 2>/dev/null | head -1 | sed -E 's/from="(.*)"/\1/')"
    [[ -n "$restriction" ]] || restriction="any IP"
  fi
  printf "%-16s %s\n" "$u" "$restriction"
}

if [[ $# -eq 1 ]]; then
  id "$1" &>/dev/null || error "No such user: $1"
  show_one "$1"
  exit 0
fi

printf "%-16s %s\n" "USERNAME" "ALLOWED FROM"
printf "%-16s %s\n" "--------" "------------"
for grp in "$AT_GROUP" "$AT_ADMIN_GROUP" "$AT_DEPLOYER_GROUP"; do
  gid="$(getent group "$grp" 2>/dev/null | cut -d: -f3)"
  [[ -n "$gid" ]] || continue
  for u in $(getent passwd | awk -F: -v gid="$gid" '$4==gid {print $1}'); do
    show_one "$u"
  done
done
