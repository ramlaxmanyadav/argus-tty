#!/bin/bash
# remove-developer.sh — offboard a developer account.
#
# Usage: remove-developer.sh <username> [--purge-home]
#   --purge-home  also delete the home directory (default: keep it, so the
#                 audit trail / any work files survive offboarding).

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib"
# shellcheck source=../lib/common.sh
source "${LIB_DIR}/common.sh"

[[ $# -ge 1 ]] || { echo "Usage: $0 <username> [--purge-home]"; exit 1; }
USERNAME="$1"; shift
PURGE_HOME=false
[[ "${1:-}" == "--purge-home" ]] && PURGE_HOME=true

require_root
id "$USERNAME" &>/dev/null || error "No such user: $USERNAME"

primary_group="$(id -gn "$USERNAME" 2>/dev/null || true)"
case "$primary_group" in
  "$AT_ADMIN_GROUP")    info "Removing ADMIN account '$USERNAME' (full sudo tier)." ;;
  "$AT_GROUP")          info "Removing developer account '$USERNAME'." ;;
  "$AT_DEPLOYER_GROUP") info "Removing deployer account '$USERNAME'." ;;
  *)                    warn "'$USERNAME' is not in '$AT_GROUP', '$AT_ADMIN_GROUP', or '$AT_DEPLOYER_GROUP' (primary group: ${primary_group:-unknown}) — removing anyway." ;;
esac

# Kill any live sessions before removing the account so audit uploads flush
# via the wrapper's own EXIT trap rather than being abruptly cut off.
pkill -TERM -u "$USERNAME" 2>/dev/null || true
sleep 1
pkill -KILL -u "$USERNAME" 2>/dev/null || true

if $PURGE_HOME; then
  userdel -r "$USERNAME"
  info "Removed '$USERNAME' and purged /home/$USERNAME."
else
  userdel "$USERNAME"
  info "Removed '$USERNAME'. Home directory /home/$USERNAME kept — pass --purge-home to delete it too."
fi
