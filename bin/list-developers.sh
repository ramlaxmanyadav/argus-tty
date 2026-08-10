#!/bin/bash
# list-developers.sh — show the current developer (or admin/deployer) roster
# on this machine.
#
# Usage: list-developers.sh [--group developer|admin|deployer]

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib"
# shellcheck source=../lib/common.sh
source "${LIB_DIR}/common.sh"

GROUP="$AT_GROUP"
[[ "${1:-}" == "--group" ]] && GROUP="${2:-$AT_GROUP}"

require_root
getent group "$GROUP" &>/dev/null || error "Group '$GROUP' doesn't exist yet — run 'argus-tty install' first."

# Members are looked up by PRIMARY gid (how add-developer.sh assigns
# accounts), not getent's supplementary-member list, which would miss them.
gid="$(getent group "$GROUP" | cut -d: -f3)"
members="$(getent passwd | awk -F: -v gid="$gid" '$4==gid {print $1}')"

[[ -n "$members" ]] || { info "No accounts in '$GROUP' yet. Run: argus-tty add <username>"; exit 0; }

printf "%-16s %-10s %-24s %s\n" "USERNAME" "KEY" "LAST LOGIN" "HOME"
printf "%-16s %-10s %-24s %s\n" "--------" "---" "----------" "----"
for user in $members; do
  auth_keys="/home/$user/.ssh/authorized_keys"
  key_status="missing"
  [[ -s "$auth_keys" ]] && key_status="installed"

  if command -v lastlog &>/dev/null; then
    last="$(lastlog -u "$user" 2>/dev/null | tail -1 | awk '{$1=""; print $0}' | sed 's/^ *//' || true)"
    [[ -z "$last" || "$last" == *"Never logged in"* ]] && last="never"
  else
    last="n/a (no lastlog)"
  fi

  printf "%-16s %-10s %-24s %s\n" "$user" "$key_status" "$last" "/home/$user"
done
