#!/bin/bash
# import-users.sh — replay a roster produced by export-users.sh (or hand-
# written in the same format) on THIS machine: creates/updates every
# developer/admin/deployer account it lists, installing every key the
# export captured and reapplying any allow-ip restriction. Idempotent —
# built on add-developer.sh, same as bulk-add-developers.sh, so re-running
# it (e.g. after editing the file) just reconciles.
#
# Usage: import-users.sh <roster-file>
#
# Format, one line per account (see export-users.sh's header for the full
# spec): tier|username|display_name|allow_from|keys
#   tier is the CANONICAL name (developer/admin/deployer) regardless of
#   this machine's DEVELOPER_GROUP_NAME/ADMIN_GROUP_NAME/DEPLOYER_GROUP_NAME
#   customization — resolved to the actual configured group below, same as
#   a roster exported from a machine with different tier names.
#
# Does NOT touch Google Authenticator (TOTP) enrollment — export-users.sh
# never captures 2FA secrets (see its header for why). If
# GOOGLE_2FA_ENABLED=true here, each imported developer/admin gets a fresh
# secret auto-provisioned and printed, exactly like running 'argus-tty add'
# for a brand-new account.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)/lib"
# shellcheck source=../lib/common.sh
source "${LIB_DIR}/common.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <roster-file>"; exit 1; }
ROSTER="$1"

require_root
[[ -f "$ROSTER" ]] || error "Roster file not found: $ROSTER"

count=0
skipped=0
while IFS='|' read -r tier username display_name allow_from keys_blob; do
  [[ -z "${tier:-}" || "$tier" == \#* ]] && continue

  case "$tier" in
    developer) GROUP="$AT_GROUP" ;;
    admin)     GROUP="$AT_ADMIN_GROUP" ;;
    deployer)  GROUP="$AT_DEPLOYER_GROUP" ;;
    *)
      warn "Skipping line for '${username:-?}' — unknown tier '$tier' (expected developer/admin/deployer)."
      skipped=$((skipped + 1))
      continue
      ;;
  esac

  if ! valid_username "$username"; then
    warn "Skipping invalid username '$username'."
    skipped=$((skipped + 1))
    continue
  fi

  section "$username ($tier)"
  args=(--name "${display_name:-$username}" --group "$GROUP")
  [[ -n "$allow_from" ]] && args+=(--allow-from "$allow_from")

  tmp_key=""
  if [[ -n "$keys_blob" ]]; then
    tmp_key="$(mktemp)"
    printf '%s\n' "${keys_blob//\\n/$'\n'}" > "$tmp_key"
    args+=(--pubkey "$tmp_key")
  else
    args+=(--no-key)
  fi

  "${SCRIPT_DIR}/add-developer.sh" "$username" "${args[@]}"
  [[ -n "$tmp_key" ]] && rm -f "$tmp_key"
  count=$((count + 1))
done < "$ROSTER"

[[ "$count" -gt 0 ]] || error "No active entries found in $ROSTER."
echo ""
if [[ "$skipped" -gt 0 ]]; then
  info "Imported $count account(s) from $ROSTER. Skipped $skipped invalid line(s)."
else
  info "Imported $count account(s) from $ROSTER."
fi
