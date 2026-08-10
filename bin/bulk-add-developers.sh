#!/bin/bash
# bulk-add-developers.sh — onboard a roster of developers (or admins/
# deployers) in one run. Loops add-developer.sh over a
# developer_users.conf-format file.
#
# Usage: bulk-add-developers.sh <roster-file> [--group developer|admin|deployer]
# Roster format: username:display_name[:ssh_public_key]  (see
# developer_users.conf.example). Entries with no third field get a PEM
# keypair auto-generated, same as running add-developer.sh directly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)/lib"
# shellcheck source=../lib/common.sh
source "${LIB_DIR}/common.sh"

[[ $# -ge 1 ]] || { echo "Usage: $0 <roster-file> [--group developer|admin]"; exit 1; }
ROSTER="$1"; shift
GROUP="$AT_GROUP"
[[ "${1:-}" == "--group" ]] && GROUP="${2:-$AT_GROUP}"
require_root
[[ -f "$ROSTER" ]] || error "Roster file not found: $ROSTER"

count=0
while IFS= read -r line; do
  [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

  username="${line%%:*}"
  rest="${line#*:}"
  display_name="${rest%%:*}"
  pub_key="${rest#*:}"
  [[ "$pub_key" == "$display_name" ]] && pub_key=""   # no third field

  if ! valid_username "$username"; then
    warn "Skipping invalid username '$username'."
    continue
  fi

  section "$username"
  if [[ -n "$pub_key" ]]; then
    tmp_key="$(mktemp)"
    printf '%s\n' "$pub_key" > "$tmp_key"
    "${SCRIPT_DIR}/add-developer.sh" "$username" --name "$display_name" --pubkey "$tmp_key" --group "$GROUP"
    rm -f "$tmp_key"
  else
    "${SCRIPT_DIR}/add-developer.sh" "$username" --name "$display_name" --group "$GROUP"
  fi
  count=$((count + 1))
done < "$ROSTER"

[[ "$count" -gt 0 ]] || error "No active entries found in $ROSTER."
echo ""
info "Processed $count account(s) from $ROSTER into group '$GROUP'."
