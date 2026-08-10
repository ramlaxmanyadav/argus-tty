#!/bin/bash
# bulk-add-deployers.sh — thin wrapper around bulk-add-developers.sh, scoped
# to the 'deployer' group.
#
# Usage: bulk-add-deployers.sh <roster-file>

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${DIR}/.." && pwd)/lib"
# shellcheck source=../lib/common.sh
source "${LIB_DIR}/common.sh"
exec "${DIR}/bulk-add-developers.sh" "$1" --group "$AT_DEPLOYER_GROUP"
