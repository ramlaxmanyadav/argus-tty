#!/bin/bash
# allow-ip.sh — restrict a developer/admin/deployer account's SSH key(s) to
# only authenticate from specific source IP(s)/CIDR(s)/host patterns, using
# OpenSSH's native authorized_keys `from="..."` option — evaluated by sshd
# itself at authentication time, before ForceCommand/session start even
# runs, so there's nothing for argus-tty-wrapper to know about.
#
# Applies the SAME restriction to every key line in the account's
# authorized_keys — one IP allowlist per account, not per individual key.
# Safe to re-run: replaces any existing `from=` restriction rather than
# stacking multiple. Takes effect on the very NEXT connection attempt — no
# sshd reload needed.
#
# Usage: allow-ip.sh <username> <ip-or-cidr-or-host>[,<ip-or-cidr-or-host>...]
#   e.g. allow-ip.sh alice 203.0.113.5
#        allow-ip.sh alice 203.0.113.5,198.51.100.0/24
#
# OpenSSH's `from=` also accepts hostnames and shell-style wildcards
# (`*.example.com`, `10.0.0.*`) — validation below only sanity-checks for
# characters that would break out of the quoted string; it doesn't try to
# fully validate every possible pattern OpenSSH accepts.

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib"
# shellcheck source=../lib/common.sh
source "${LIB_DIR}/common.sh"

[[ $# -eq 2 ]] || { echo "Usage: $0 <username> <ip-or-cidr>[,<ip-or-cidr>...]"; exit 1; }
USERNAME="$1"; FROM_LIST="$2"

require_root
id "$USERNAME" &>/dev/null || error "No such user: $USERNAME"
[[ -n "$FROM_LIST" ]] || error "IP/CIDR list cannot be empty — use 'argus-tty clear-ip $USERNAME' to remove a restriction instead."
[[ "$FROM_LIST" != *'"'* && "$FROM_LIST" != *$'\n'* ]] \
  || error "IP/CIDR list cannot contain a double-quote or newline."

set_authorized_keys_from "$USERNAME" "$FROM_LIST"

info "Restricted '$USERNAME' to connect only from: $FROM_LIST"
warn "Takes effect on the NEXT connection attempt (no reload needed) — test it in a NEW terminal before closing any current session, in case the list is wrong."
