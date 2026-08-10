#!/bin/bash
# add-deployer.sh — thin wrapper around add-developer.sh: onboard a DEPLOYER
# account instead of a whitelisted developer or full-sudo admin one. Mirrors
# add-developer.sh's usage exactly (same flags: --name, --pubkey, --no-key,
# --print-key, --allow-from) — only the group differs.
#
# Deployers are the narrowest tier: starting/stopping/restarting services
# via sudo, nothing else — no console, rake, install, setup, apt-get, or
# docker (see sudoers/deployer.sudoers.sample). Any finer-grained
# restriction on top of that (e.g. "only a deploy/cleanup subcommand") is up
# to your own deploy tooling's own role checks, not something this toolkit
# enforces itself. Their SSH sessions are STILL forced through the same
# recorder as developers/admins (see the 'Match Group
# developer,admin,deployer' block in sshd_config) — narrower privilege,
# same audit trail.
#
# Usage: add-deployer.sh <username> [--name "Display Name"] [--pubkey <file>|-] [--no-key] [--print-key] [--allow-from <ip-or-cidr>[,...]]

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${DIR}/.." && pwd)/lib"
# shellcheck source=../lib/common.sh
source "${LIB_DIR}/common.sh"
exec "${DIR}/add-developer.sh" "$@" --group "$AT_DEPLOYER_GROUP"
