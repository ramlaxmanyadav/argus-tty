#!/bin/bash
# export-users.sh — dump every developer/admin/deployer account on this
# machine (username, display name, source-IP restriction, and EVERY SSH
# public key in their authorized_keys) into a single portable roster file
# that import-users.sh can replay on another machine.
#
# Usage: export-users.sh [output-file]
#   (omit, or pass "-")   write to stdout
#
# What's included:  username, display name (GECOS), tier (developer/admin/
#   deployer — written using the CANONICAL tier name, not a customized
#   DEVELOPER_GROUP_NAME/ADMIN_GROUP_NAME/DEPLOYER_GROUP_NAME, so the file
#   stays portable to a machine with different tier names configured — see
#   import-users.sh), the allow-ip `from=` restriction (if any), and every
#   key currently in authorized_keys.
#
# What's deliberately NOT included (by design, not an oversight):
#   - Private keys. Only the PUBLIC half ever lives in authorized_keys —
#     this file only ever contains what sshd itself would accept.
#   - Google Authenticator (TOTP) secrets. A 2FA secret is tied to one
#     enrolled device; carrying it to a new machine wouldn't let the user
#     authenticate there anyway. Re-run 'argus-tty add <username>' on the
#     target machine (with GOOGLE_2FA_ENABLED=true) to re-enroll.
#
# Output format, one line per account:
#   tier|username|display_name|allow_from|keys
#     tier         developer, admin, or deployer (canonical name)
#     allow_from   empty if unrestricted, else the same comma-separated
#                  ip-or-cidr list 'argus-tty allow-ip' accepts
#     keys         every authorized_keys key line for this account (the
#                  "from=..." option, if any, stripped — allow_from above
#                  is what carries that restriction), multiple keys joined
#                  with a literal backslash-n
# Blank lines and lines starting with # are ignored by import-users.sh.

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib"
# shellcheck source=../lib/common.sh
source "${LIB_DIR}/common.sh"

OUT="${1:--}"

require_root

_export_tier() {
  local tier="$1" group="$2"
  getent group "$group" &>/dev/null || return 0

  local gid
  gid="$(getent group "$group" | cut -d: -f3)"
  local user home auth_keys display_name allow_from keys_blob line key_part from_val
  for user in $(getent passwd | awk -F: -v gid="$gid" '$4==gid {print $1}'); do
    home="$(getent passwd "$user" | cut -d: -f6)"
    display_name="$(getent passwd "$user" | cut -d: -f5)"
    [[ -n "$display_name" ]] || display_name="$user"

    auth_keys="${home}/.ssh/authorized_keys"
    allow_from=""
    keys_blob=""
    if [[ -s "$auth_keys" ]]; then
      while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        key_part="$(grep -oE "${AT_PUBKEY_TYPES} .*" <<<"$line" || true)"
        [[ -n "$key_part" ]] || continue
        if [[ -z "$allow_from" ]]; then
          from_val="$(grep -oE 'from="[^"]*"' <<<"$line" | sed -E 's/from="(.*)"/\1/' || true)"
          [[ -n "$from_val" ]] && allow_from="$from_val"
        fi
        keys_blob="${keys_blob:+${keys_blob}\\n}${key_part}"
      done < "$auth_keys"
    fi

    if [[ "$display_name" == *'|'* || "$allow_from" == *'|'* || "$keys_blob" == *'|'* ]]; then
      warn "Skipping '$user' in export — a field contains '|', which this format can't carry. Export manually."
      continue
    fi

    printf '%s|%s|%s|%s|%s\n' "$tier" "$user" "$display_name" "$allow_from" "$keys_blob"
  done
}

tmp="$(mktemp)"
{
  echo "# argus-tty user export — generated $(date -u '+%Y-%m-%dT%H:%M:%SZ') on $(hostname)"
  echo "# Format: tier|username|display_name|allow_from|keys (see export-users.sh header)"
  echo "# Import on another machine with: sudo argus-tty import <this-file>"
  _export_tier developer "$AT_GROUP"
  _export_tier admin "$AT_ADMIN_GROUP"
  _export_tier deployer "$AT_DEPLOYER_GROUP"
} > "$tmp" || { rm -f "$tmp"; error "Export failed."; }

if [[ "$OUT" == "-" ]]; then
  cat "$tmp"
  rm -f "$tmp"
else
  mv "$tmp" "$OUT"
  chmod 600 "$OUT"
  count="$(grep -cv '^\(#\|$\)' "$OUT" || true)"
  info "Exported $count account(s) to $OUT"
  warn "Contains every developer/admin/deployer's public key(s) — no private keys or 2FA secrets. Still, keep it as controlled as any other account roster (600, root-only, by default)."
fi
