#!/bin/bash
# remove-deployer.sh — thin wrapper around remove-developer.sh. Offboarding
# logic is identical regardless of tier (remove-developer.sh already detects
# and reports whether the account was a developer, admin, or deployer).
#
# Usage: remove-deployer.sh <username> [--purge-home]

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${DIR}/remove-developer.sh" "$@"
