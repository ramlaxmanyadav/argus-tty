# lib/common.sh — shared helpers for the argus-tty toolkit.
# Sourced by install.sh and everything under bin/. Not meant to be run directly.

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
section() { echo -e "\n${CYAN}── $* ──${NC}"; }

# Standard install locations, shared by every script in the package. Used
# identically whether argus-tty was installed via the .deb or copied
# manually — one canonical path either way, so sshd_config/systemd never
# need to care which install method was used.
AT_INSTALL_ROOT="/usr/sbin"
AT_WRAPPER_PATH="${AT_INSTALL_ROOT}/argus-tty-wrapper"
AT_FINALIZE_PATH="${AT_INSTALL_ROOT}/argus-tty-finalize"
AT_MAILER_PATH="${AT_INSTALL_ROOT}/argus-tty-mailer"
AT_SESSION_DIR="/var/log/argus-tty/sessions"
AT_NOTIFY_DIR="/var/log/argus-tty/notify"
AT_ETC_DIR="/etc/argus-tty"
AT_CONFIG_FILE="${AT_ETC_DIR}/config.env"
AT_SMTP_CREDS_FILE="${AT_ETC_DIR}/smtp-credentials.env"
AT_SUDOERS_FILE="/etc/sudoers.d/developer"
AT_ADMIN_SUDOERS_FILE="/etc/sudoers.d/admin"
AT_DEPLOYER_SUDOERS_FILE="/etc/sudoers.d/deployer"
# Shipped defaults (read-only reference — never overwritten after install) vs.
# optional per-host overrides (admin-created, empty by default). reconfigure.sh
# uses the override if present, else the sample, and ALWAYS re-derives
# AT_SUDOERS_FILE/AT_ADMIN_SUDOERS_FILE/AT_DEPLOYER_SUDOERS_FILE from whichever
# applies on every run — editing AT_SUDOERS_FILE directly gets overwritten on
# the next reconfigure, the override file at AT_DEV_SUDOERS_OVERRIDE is the
# only durable way to customize developer/admin/deployer sudo permissions.
AT_DEV_SUDOERS_SAMPLE="/usr/share/argus-tty/developer.sudoers.sample"
AT_ADMIN_SUDOERS_SAMPLE="/usr/share/argus-tty/admin.sudoers.sample"
AT_DEPLOYER_SUDOERS_SAMPLE="/usr/share/argus-tty/deployer.sudoers.sample"
AT_DEV_SUDOERS_OVERRIDE="${AT_ETC_DIR}/developer.sudoers"
AT_ADMIN_SUDOERS_OVERRIDE="${AT_ETC_DIR}/admin.sudoers"
AT_DEPLOYER_SUDOERS_OVERRIDE="${AT_ETC_DIR}/deployer.sudoers"
AT_PAM_SU="/etc/pam.d/su"
AT_PAM_SSHD="/etc/pam.d/sshd"
AT_PROFILE_D="/etc/profile.d/developer-restrictions.sh"
AT_LOGROTATE_CONF="/etc/logrotate.d/argus-tty"
AT_SSHD_CONF="/etc/ssh/sshd_config"
# Vendor-shipped units belong in /usr/lib/systemd/system, NOT /etc/systemd/system
# (that path is reserved for local sysadmin overrides/symlinks and ranks above
# vendor units in systemd's search order) — `systemctl enable` creates the
# necessary /etc/systemd/system/timers.target.wants/ symlink on its own.
AT_SYSTEMD_DIR="/usr/lib/systemd/system"
AT_SYSTEMD_LEGACY_DIR="/etc/systemd/system"
# Tier group names — 'developer'/'admin'/'deployer' by default, but every
# script threads these variables through (never the literal words) so an
# org can rename the terms via DEVELOPER_GROUP_NAME/ADMIN_GROUP_NAME/
# DEPLOYER_GROUP_NAME in config.env (see config.env.example and README.md
# "Customizing the developer/admin/deployer tier names"). Sourced
# defensively — same idiom used elsewhere in this toolkit (e.g.
# argus-tty-wrapper.sh) — so a missing/unreadable config.env just means the
# canonical defaults apply, never a hard failure for scripts that source
# this file. On-disk paths below (AT_SUDOERS_FILE, AT_DEV_SUDOERS_SAMPLE,
# etc.) intentionally stay on the canonical developer/admin/deployer names
# regardless of this — they're internal identifiers, not the customer-
# facing term.
AT_GROUP="developer"
AT_ADMIN_GROUP="admin"
AT_DEPLOYER_GROUP="deployer"
if [[ -f "$AT_CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$AT_CONFIG_FILE"
  AT_GROUP="${DEVELOPER_GROUP_NAME:-developer}"
  AT_ADMIN_GROUP="${ADMIN_GROUP_NAME:-admin}"
  AT_DEPLOYER_GROUP="${DEPLOYER_GROUP_NAME:-deployer}"
fi
# Deploy-only tier: no console/rake/logs/install/setup, no apt-get/
# docker/kill — just a `systemctl start/stop/restart` whitelist (see
# sudoers/deployer.sudoers.sample). Also gets AT_WEBAPPS_GROUP/AT_RVM_GROUP
# like developer/admin (add-developer.sh) since the actual clone/bundle
# install/symlink steps a deploy performs are plain file operations under
# those groups, not something sudo mediates.
# Generic app-deploy tree — not installed or required by this toolkit
# itself, just scaffolding for whatever Rails/app-deployment tooling you
# layer on top of these accounts. One shared group across every app under
# AT_WEBAPPS_ROOT; every developer/admin/deployer gets added to it (same
# tier model as everything else in this toolkit — per-app isolation is a
# future extension, not implemented here).
AT_WEBAPPS_ROOT="/var/www"
AT_WEBAPPS_GROUP="webapps"
# No dedicated "secrets" group: shared/.env (app secrets — DATABASE_URL,
# SECRET_KEY_BASE, etc.) is root:root 600 with a single named-user ACL grant
# for AT_WEBAPPS_SVC_USER (see reconfigure.sh) — a group can't
# express "some webapps members can read this, others can't" (developer/
# deployer ARE webapps members and must NOT read it), so a per-file ACL
# entry does the same job as a whole extra group, with less machinery.
# Admin needs no grant at all here — full sudo already covers view/edit.
# RVM's own multi-user installer (https://rvm.io, "multi-user installation")
# creates this group and makes rubies/gemsets group-writable under it. This
# toolkit does NOT install RVM — it only adds developer/admin accounts to
# the group if/once RVM has been installed, so `ruby`/`bundle`/`rails` work
# without sudo. If the group doesn't exist yet, membership is simply skipped.
AT_RVM_GROUP="rvm"
# Unprivileged, no-login SYSTEM account that a deployed app's own service
# processes (e.g. puma/sidekiq) run as. Deliberately NOT one of the
# developer/admin SSH accounts and NOT root: the process that serves
# requests shouldn't run as a human's account or with sudo rights, it just
# needs read/write on its own app's shared/.env, shared/log,
# shared/tmp/sockets — which group membership in AT_WEBAPPS_GROUP already
# grants it, same as any developer.
AT_WEBAPPS_SVC_USER="webapp-svc"
# Canonical path of RVM's multi-user (system-wide) install. Its per-ruby,
# per-gemset "wrapper scripts" under $AT_RVM_ROOT/wrappers/<ruby>@<gemset>/
# are the RVM-documented way to run something under a specific ruby/gemset
# from systemd/cron without sourcing any shell functions first.
AT_RVM_ROOT="/usr/local/rvm"
# Where auto-generated developer/admin private keys are stored — deliberately
# OUTSIDE the replicable package directory so `scp -r` to another machine
# never drags another machine's private keys along with it.
AT_GENERATED_KEYS_DIR="/root/argus-tty-developer-keys"

# require_root — fail unless running as uid 0.
require_root() {
  [[ "$(id -u)" -eq 0 ]] || error "Must run as root (use: sudo $0 $*)"
}

# System packages argus-tty's own scripts call directly (chattr/lsattr from
# e2fsprogs, visudo from sudo, script from bsdutils, curl, logrotate,
# systemctl from systemd, sshd from openssh-server, setfacl/getfacl from acl
# — used for the per-file ACL grant on a deployed app's shared/.env, see
# reconfigure.sh). Mirrors Depends: in debian/control and
# packaging/DEBIAN/control — keep all three in sync. The .deb gets these for
# free via `apt install ./argus-tty.deb` (apt resolves Depends before dpkg
# ever unpacks), but install.sh's manual path has no dependency resolution
# of its own — this is what gives it the same guarantee.
AT_REQUIRED_PACKAGES=(openssh-server sudo passwd bsdutils e2fsprogs curl logrotate systemd acl)

# _apt_get <args...> — every apt-get call this toolkit makes on the user's
# own behalf goes through this, never a bare `apt-get`:
#   - DEBIAN_FRONTEND=noninteractive + </dev/null: a package whose postinst
#     would otherwise prompt (a debconf question) can't block waiting on a
#     TTY that isn't there during an unattended install/reconfigure run.
#   - -qq -o Dpkg::Use-Pty=0: without this, apt/dpkg assume an interactive
#     terminal and emit a redrawing progress bar as raw control characters
#     — harmless on a real TTY, but when this script's output is captured
#     to a log (cloud-init, CI, `script`, a provisioning tool) that becomes
#     thousands of near-unreadable lines. This is the standard fix.
_apt_get() {
  DEBIAN_FRONTEND=noninteractive apt-get -qq -o Dpkg::Use-Pty=0 "$@" </dev/null
}

# ensure_required_packages — install any of AT_REQUIRED_PACKAGES not already
# present, via apt-get. Idempotent; safe to call on every run. Called by
# both install.sh and reconfigure.sh, so a later `argus-tty reconfigure`
# also recovers if a required package was removed by hand after install.
ensure_required_packages() {
  command -v dpkg &>/dev/null || {
    warn "Not a dpkg-based system — skipping automatic dependency install. Ensure these are installed manually: ${AT_REQUIRED_PACKAGES[*]}"
    return
  }

  local pkg missing=()
  for pkg in "${AT_REQUIRED_PACKAGES[@]}"; do
    dpkg -s "$pkg" &>/dev/null || missing+=("$pkg")
  done
  [[ ${#missing[@]} -eq 0 ]] && return

  command -v apt-get &>/dev/null \
    || error "Missing required package(s): ${missing[*]} — install them manually (no apt-get on this system)."

  info "Installing missing required package(s): ${missing[*]}..."
  # A stale/empty package index (common on a freshly-booted cloud image) is
  # the single most common reason the install below fails outright — update
  # first so this is actually hands-off. Non-fatal: an air-gapped host with
  # no reachable mirror still gets a chance to install from whatever's
  # already cached.
  _apt_get update || warn "'apt-get update' failed (no network/mirror reachable?) — trying install anyway with the existing package index."
  _apt_get install -y "${missing[@]}" \
    || error "Failed to install: ${missing[*]}. Check network/mirror reachability, or install them manually on an air-gapped host."
}

# refuse_unsafe_dir <dir> — reject /tmp-like or non-root-owned/world-writable
# deploy directories. A developer with write access to the deploy dir could
# swap these files for malicious versions before root runs them.
refuse_unsafe_dir() {
  local dir="$1"
  case "$dir" in
    /tmp*|/var/tmp*|/dev/shm*)
      error "Refusing to run from '$dir'. Copy the package to /root/argus-tty/ and run from there." ;;
  esac

  local owner
  owner=$(stat -c '%U' "$dir" 2>/dev/null) || error "Cannot stat '$dir'."
  [[ "$owner" == "root" ]] \
    || error "'$dir' is owned by '$owner', not root. Move the package to /root/argus-tty/."

  local mode
  mode=$(stat -c '%a' "$dir" 2>/dev/null)
  case "${mode: -1}" in
    2|3|6|7) error "'$dir' is world-writable (mode $mode). Run: chmod o-w '$dir'" ;;
  esac
}

# valid_username <name> — same convention used for all Linux accounts this
# toolkit creates: lowercase, starts with a letter, max 32 chars.
valid_username() {
  [[ "$1" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]
}

# valid_gecos <comment> — useradd's GECOS/--comment field can't contain a
# colon (it's the field delimiter in /etc/passwd) or a newline. useradd
# rejects both with a raw "invalid comment" error and no context — check
# first so callers can fail with a clear message instead.
valid_gecos() {
  [[ "$1" != *:* && "$1" != *$'\n'* ]]
}

# valid_pubkey <key-line> — quick sanity check before writing to authorized_keys.
valid_pubkey() {
  echo "$1" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|sk-ssh-ed25519) '
}

# Key-type tokens authorized_keys lines can start with, once any leading
# OpenSSH "options" (from=, command=, etc.) are stripped — same set
# valid_pubkey checks, used here to find where those options end and the
# actual key begins.
AT_PUBKEY_TYPES='(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|sk-ssh-ed25519)'

# set_authorized_keys_from <username> <from-value-or-empty> — rewrites
# every recognized key line in <username>'s authorized_keys, replacing any
# existing authorized_keys "options" prefix (this toolkit only ever sets
# `from=`, but a line could have picked up something else by hand) with a
# fresh `from="<from-value>"` — or with nothing at all, reverting to
# unrestricted, if from-value is empty. One restriction applies to every
# key line for the account, not per individual key. Takes effect on the
# NEXT connection attempt; sshd re-reads authorized_keys per auth attempt,
# no reload needed (unlike sshd_config changes).
set_authorized_keys_from() {
  local username="$1" from_value="$2"
  local home group auth_keys tmp changed=0 line key_part

  home="$(getent passwd "$username" | cut -d: -f6)"
  [[ -n "$home" && -d "$home" ]] || error "Could not resolve home directory for '$username'."
  group="$(id -gn "$username")"
  auth_keys="${home}/.ssh/authorized_keys"
  [[ -f "$auth_keys" ]] || error "$auth_keys not found — does '$username' have a key installed yet?"

  tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -z "$line" || "$line" == \#* ]]; then
      printf '%s\n' "$line" >> "$tmp"
      continue
    fi
    key_part="$(grep -oE "${AT_PUBKEY_TYPES} .*" <<<"$line" || true)"
    if [[ -z "$key_part" ]]; then
      # Doesn't look like a key line this toolkit recognizes — leave as-is
      # rather than risk mangling something added by hand.
      printf '%s\n' "$line" >> "$tmp"
      continue
    fi
    if [[ -n "$from_value" ]]; then
      printf 'from="%s" %s\n' "$from_value" "$key_part" >> "$tmp"
    else
      printf '%s\n' "$key_part" >> "$tmp"
    fi
    changed=$((changed + 1))
  done < "$auth_keys"

  if [[ "$changed" -eq 0 ]]; then
    rm -f "$tmp"
    error "No recognized key lines found in $auth_keys — nothing to update."
  fi

  cat "$tmp" > "$auth_keys"
  rm -f "$tmp"
  chmod 600 "$auth_keys"
  chown "${username}:${group}" "$auth_keys"
}

# load_config — source the installed config.env. Callers that need config
# values (status.sh, add-developer.sh for defaults) call this; the wrapper
# does its own sourcing since it must never fail loudly mid-session.
load_config() {
  [[ -f "$AT_CONFIG_FILE" ]] || error "$AT_CONFIG_FILE not found — run 'argus-tty install' first."
  # shellcheck disable=SC1090
  source "$AT_CONFIG_FILE"
}
