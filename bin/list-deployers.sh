#!/bin/bash
# list-deployers.sh — thin wrapper around list-developers.sh, scoped to the
# 'deployer' group.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${DIR}/.." && pwd)/lib"
# shellcheck source=../lib/common.sh
source "${LIB_DIR}/common.sh"
exec "${DIR}/list-developers.sh" --group "$AT_DEPLOYER_GROUP"
