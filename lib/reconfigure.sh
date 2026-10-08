#!/bin/bash
# lib/reconfigure.sh — idempotent system-level configuration for argus-tty.
#
# Shared by two callers:
#   1. install.sh (manual/loose-folder install) — copies files into place
#      first, then calls this script to do the actual system wiring.
#   2. the .deb package's postinst — dpkg has already unpacked every file at
#      its canonical location (including conffiles), so postinst calls this
#      script directly with nothing to copy.
#
# This script assumes every file the toolkit ships already exists at its
# canonical path (AT_WRAPPER_PATH, AT_CONFIG_FILE, sudoers files, etc.) — it
# never copies anything itself. What it does do: create the developer/admin
# groups, lock down the installed binaries (chattr +i), create the runtime
# session/notification directories, wire up PAM su restriction, install the
# sshd Match block, enable the mailer timer, and run advisory AWS/SMTP
# checks. It never touches developer/admin accounts.
#
# Safe to re-run any time — every step here is idempotent.

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${LIB_DIR}/common.sh"

require_root

section "Required system packages"
ensure_required_packages

command -v visudo &>/dev/null || error "'visudo' not found. Install sudo: apt-get install -y sudo"

# ── Groups ───────────────────────────────────────────────────────────────────
# _ensure_group <canonical> <configured> — create the tier's Linux group, or
# RENAME it in place if a *_GROUP_NAME override in config.env moved it away
# from the canonical developer/admin/deployer default and accounts already
# exist under the old name. `groupmod -n` (not groupadd, leaving the old
# group behind) is what makes this safe: it preserves the GID and every
# existing member's primary-group reference in one atomic step, so nobody
# gets orphaned in a stale group the instant the sshd AllowGroups/Match
# block below switches to the new name.

_ensure_group() {
  local canonical="$1" configured="$2"
  if getent group "$configured" &>/dev/null; then
    info "Group '$configured' already exists — skipping."
  elif [[ "$configured" != "$canonical" ]] && getent group "$canonical" &>/dev/null; then
    groupmod -n "$configured" "$canonical"
    warn "Renamed Linux group '$canonical' -> '$configured' to match config.env — existing accounts keep their access."
  else
    groupadd "$configured"
    info "Created group '$configured'."
  fi
}

section "Groups: $AT_GROUP, $AT_ADMIN_GROUP, $AT_DEPLOYER_GROUP, $AT_WEBAPPS_GROUP"
_ensure_group developer "$AT_GROUP"
_ensure_group admin     "$AT_ADMIN_GROUP"
_ensure_group deployer  "$AT_DEPLOYER_GROUP"
if getent group "$AT_WEBAPPS_GROUP" &>/dev/null; then
  info "Group '$AT_WEBAPPS_GROUP' already exists — skipping."
else
  groupadd "$AT_WEBAPPS_GROUP"
  info "Created group '$AT_WEBAPPS_GROUP'."
fi

# ── Sudoers: developer/deployer whitelists + admin full-sudo, override-aware
# /etc/sudoers.d/{developer,admin,deployer} are RE-DERIVED on every run from
# either the shipped sample or a per-host override at
# /etc/argus-tty/{developer,admin,deployer}.sudoers — see
# sudoers/developer.sudoers.sample's header for the full mechanism. Editing
# /etc/sudoers.d/developer directly is NOT durable: the next reconfigure
# overwrites it from whichever of these two sources applies.
#
# Deliberately does not silently fall back to the default on an invalid
# override — if you broke your override's syntax, reconfigure fails loudly
# so you fix it, rather than quietly reverting your customization without
# telling you.

section "Sudoers: developer + admin + deployer (override-aware)"

install_sudoers() {
  local tier="$1" sample="$2" override="$3" target="$4" group_name="$5" src="$2"
  if [[ -f "$override" ]]; then
    info "Using override for '$tier' sudoers: $override"
    src="$override"
  else
    [[ -f "$sample" ]] || error "$sample not found — installation is incomplete."
    info "Using shipped default for '$tier' sudoers: $sample"
  fi
  local visudo_out tmp content
  tmp="$(mktemp)"
  cp "$src" "$tmp"

  # Substitute the canonical %<tier> token (e.g. %developer) for the
  # actually-configured group name (e.g. %sre, from ADMIN_GROUP_NAME) —
  # keeps a sample or an override copied from it working after a rename,
  # since either still says %developer/%admin/%deployer literally.
  if [[ "$group_name" != "$tier" ]]; then
    sed -i "s/%${tier}\b/%${group_name}/g" "$tmp"
    info "Renamed sudoers group token '%${tier}' -> '%${group_name}' for '$tier'."
  fi

  if ! visudo_out="$(visudo -c -f "$tmp" 2>&1)"; then
    # log_output/logfile need the sudo I/O-logging plugin, which
    # implementations like sudo-rs don't support and reject outright rather
    # than ignore. That's only supplemental logging here — the SSH TTY
    # recorder (see admin.sudoers.sample's header) is the real audit trail —
    # so drop those two lines and retry instead of failing the whole install.
    if grep -qE "unknown setting: '(log_output|logfile)'" <<<"$visudo_out"; then
      warn "'$tier' sudoers uses log_output/logfile (sudo I/O logging), which this host's sudo doesn't support — dropping those two lines. The SSH TTY recorder remains the primary audit trail."
      # Filter $tmp (the working copy, already through the group-token
      # substitution above), NOT $src (the original) — filtering $src here
      # would silently discard that substitution on any host whose sudo
      # lacks log_output support.
      content="$(grep -Ev '^[[:space:]]*Defaults:%[A-Za-z0-9_]+[[:space:]]+(log_output|logfile=)' "$tmp")"
      printf '%s\n' "$content" > "$tmp"
      visudo_out="$(visudo -c -f "$tmp" 2>&1)" || {
        rm -f "$tmp"
        error "$src still has invalid sudoers syntax after dropping log_output/logfile:
${visudo_out}
Fix the issue above and re-run reconfigure."
      }
    else
      rm -f "$tmp"
      error "$src has invalid sudoers syntax:
${visudo_out}
Fix the issue above and re-run reconfigure."
    fi
  fi

  cp "$tmp" "$target"
  rm -f "$tmp"
  chmod 440 "$target"
  chown root:root "$target"
  info "Installed $target"
}

install_sudoers developer "$AT_DEV_SUDOERS_SAMPLE"      "$AT_DEV_SUDOERS_OVERRIDE"      "$AT_SUDOERS_FILE"      "$AT_GROUP"
install_sudoers admin     "$AT_ADMIN_SUDOERS_SAMPLE"    "$AT_ADMIN_SUDOERS_OVERRIDE"    "$AT_ADMIN_SUDOERS_FILE" "$AT_ADMIN_GROUP"
install_sudoers deployer  "$AT_DEPLOYER_SUDOERS_SAMPLE" "$AT_DEPLOYER_SUDOERS_OVERRIDE" "$AT_DEPLOYER_SUDOERS_FILE" "$AT_DEPLOYER_GROUP"

# Computed once, used below both for the service account and the retrofit
# loop: RVM's gems/rubies under AT_RVM_ROOT are group-owned by 'rvm', not
# 'webapps' — anything that needs to actually RUN a ruby process (the
# service account, every developer/admin) needs both groups, not just
# webapps, or gem loading fails with permission denied at runtime.
if getent group "$AT_RVM_GROUP" &>/dev/null; then
  rvm_suffix=",${AT_RVM_GROUP}"
else
  rvm_suffix=""
  info "'$AT_RVM_GROUP' group not found — RVM not installed yet, skipping (re-run after installing it)."
fi

# ── Service account for running app processes (puma/sidekiq) ───────────────
# Not an SSH-able developer/admin account — no shell (nologin blocks
# interactive login/su, NOT `sudo -u webapp-svc <command>`, which never
# needs a login shell), just an identity for systemd units to run app
# processes as, AND (since a deploy tool's console/rake entrypoint may
# elevate to it) for interactive-ish bundle/rails invocations too. It
# DOES need a real home directory for that second role: bundler/irb/etc
# write to $HOME, and a homeless account makes bundler print "`/home/
# webapp-svc` is not a directory" and fall back to a throwaway /tmp dir on
# every single invocation. Member of webapps so it can read/write
# shared/.env, shared/log, shared/tmp/sockets like a developer can, and of
# rvm (once installed) so it can actually load the gems that run the app —
# without it, puma/sidekiq fail at runtime with a permission error reading
# RVM's gem directories.

section "Service account: $AT_WEBAPPS_SVC_USER"
if id "$AT_WEBAPPS_SVC_USER" &>/dev/null; then
  info "'$AT_WEBAPPS_SVC_USER' already exists — ensuring group membership."
else
  useradd --system --create-home --shell /usr/sbin/nologin \
    --gid "$AT_WEBAPPS_GROUP" --comment "argus-tty - runs app processes (puma/sidekiq)" \
    "$AT_WEBAPPS_SVC_USER"
  info "Created system account '$AT_WEBAPPS_SVC_USER' (no login, gid=$AT_WEBAPPS_GROUP)."
fi
# Unconditional, even when the account already existed: an account created
# by an older version of this script (--no-create-home) needs this
# retrofitted, same idiom as the webapps/rvm retrofit loop below.
AT_WEBAPPS_SVC_HOME="$(getent passwd "$AT_WEBAPPS_SVC_USER" | cut -d: -f6)"
if [[ -n "$AT_WEBAPPS_SVC_HOME" && ! -d "$AT_WEBAPPS_SVC_HOME" ]]; then
  mkdir -p "$AT_WEBAPPS_SVC_HOME"
  chown "${AT_WEBAPPS_SVC_USER}:${AT_WEBAPPS_GROUP}" "$AT_WEBAPPS_SVC_HOME"
  chmod 750 "$AT_WEBAPPS_SVC_HOME"
  info "Created missing home directory $AT_WEBAPPS_SVC_HOME for '$AT_WEBAPPS_SVC_USER' (was created without one by an older version)."
fi
if [[ -n "$rvm_suffix" ]]; then
  usermod -aG "$AT_RVM_GROUP" "$AT_WEBAPPS_SVC_USER"
  info "'$AT_WEBAPPS_SVC_USER' is in '$AT_RVM_GROUP' — can load gems at runtime."
fi
# No group needed for shared/.env access — grant AT_WEBAPPS_SVC_USER a
# per-file ACL read entry on each app's env file directly (via setfacl),
# instead of a group every app's .env would need to belong to.

# ── Profile: umask for developer/admin/deployer accounts ───────────────────
# Regenerated fresh every run (not just copied once at install time) so it
# always reflects the CURRENT tier names — same idempotent-rewrite pattern
# as the sudoers files and the sshd Match block below. Not a dpkg conffile
# for the same reason those aren't: a file this script overwrites on every
# run would make every future `apt upgrade` prompt about a "locally
# modified" conffile.

section "Profile: umask for $AT_GROUP/$AT_ADMIN_GROUP/$AT_DEPLOYER_GROUP accounts"
cat > "$AT_PROFILE_D" <<EOF
# /etc/profile.d/developer-restrictions.sh
# Managed by argus-tty reconfigure.sh — do NOT edit manually. Regenerated
# from DEVELOPER_GROUP_NAME/ADMIN_GROUP_NAME/DEPLOYER_GROUP_NAME in
# config.env on every reconfigure run.

# Apply umask 027 for developer, admin, AND deployer accounts:
#   owner: rwx (7), group: r-x (5), others: --- (0)
#   New files: 640 | New dirs: 750 — not readable by other users.
if id -nG 2>/dev/null | tr ' ' '\\n' | grep -qxE '${AT_GROUP}|${AT_ADMIN_GROUP}|${AT_DEPLOYER_GROUP}'; then
  umask 027
fi
EOF
chmod 644 "$AT_PROFILE_D"
chown root:root "$AT_PROFILE_D"
info "$AT_PROFILE_D regenerated."

# ── Retrofit existing developer/admin/deployer accounts into webapps (+
# rvm, if installed) ─────────────────────────────────────────────────────────
# New accounts get this from add-developer.sh automatically; this loop is
# only needed for accounts onboarded before this feature existed.

section "Retrofitting existing accounts onto webapps/rvm"
retrofit_groups="${AT_WEBAPPS_GROUP}${rvm_suffix}"
retrofit_count=0
# Membership in developer/admin/deployer is via PRIMARY gid (add-developer.sh
# does `useradd --gid`/`usermod -g`), not the secondary-member list `getent
# group` exposes — that list would be empty here. Match on /etc/passwd's gid
# field instead.
dev_gid="$(getent group "$AT_GROUP" | cut -d: -f3)"
admin_gid="$(getent group "$AT_ADMIN_GROUP" | cut -d: -f3)"
deployer_gid="$(getent group "$AT_DEPLOYER_GROUP" | cut -d: -f3)"
for u in $(getent passwd | awk -F: -v d="$dev_gid" -v a="$admin_gid" -v p="$deployer_gid" '$4==d || $4==a || $4==p {print $1}'); do
  usermod -aG "$retrofit_groups" "$u"
  retrofit_count=$((retrofit_count + 1))
done
info "Retrofitted $retrofit_count existing developer/admin/deployer account(s) onto: $retrofit_groups"

# ── Lock down the installed binaries ────────────────────────────────────────

section "Locking down installed binaries"
for f in "$AT_WRAPPER_PATH" "$AT_FINALIZE_PATH" "$AT_MAILER_PATH"; do
  [[ -f "$f" ]] || error "$f not found — installation is incomplete."
  chattr +i "$f" 2>/dev/null || warn "chattr +i not supported on this filesystem — $(basename "$f") is not immutable."
done
info "Wrapper/finalize/mailer locked (writable only by root; chattr +i where supported)."

# ── Session + notification directories ──────────────────────────────────────

section "Session and notification directories"
mkdir -p "$AT_SESSION_DIR"
chown root:root "$AT_SESSION_DIR"
chmod 1777 "$AT_SESSION_DIR"   # world-writable + sticky: devs create files, can't delete others'
info "$AT_SESSION_DIR ready (S3 upload is the durable record; local copies are deleted after upload)."

mkdir -p "$AT_NOTIFY_DIR/failed"
chown root:root "$AT_NOTIFY_DIR" "$AT_NOTIFY_DIR/failed"
chmod 1777 "$AT_NOTIFY_DIR"       # world-writable + sticky: devs queue their own notifications
chmod 700 "$AT_NOTIFY_DIR/failed" # root-only: where the mailer parks sends it gave up on
info "$AT_NOTIFY_DIR ready for queued email notifications."

load_config

# ── PAM: block su for non-sudo users (developers stay blocked; admins are
# added to the 'sudo' group by add-developer.sh --group admin, so this
# doesn't restrict them) ─────────────────────────────────────────────────────

section "PAM: restrict su to sudo group"
if grep -q 'pam_wheel\.so group=sudo' "$AT_PAM_SU" 2>/dev/null; then
  info "PAM already restricts su to the sudo group — skipping."
else
  cp "$AT_PAM_SU" "${AT_PAM_SU}.bak.$(date '+%Y%m%d%H%M%S')"
  if grep -q 'pam_wheel\.so' "$AT_PAM_SU"; then
    sed -i 's|^#\?[[:space:]]*.*pam_wheel\.so.*$|auth required pam_wheel.so group=sudo|' "$AT_PAM_SU"
  else
    sed -i '/pam_rootok\.so/a auth required pam_wheel.so group=sudo' "$AT_PAM_SU"
  fi
  info "Updated $AT_PAM_SU (backup saved alongside it)."
fi

# ── PAM: Google Authenticator (TOTP) 2FA for SSH, gated by
# GOOGLE_2FA_ENABLED — a real master switch, same posture as EMAIL_ENABLED/
# S3_UPLOAD_ENABLED. Exempts the deployer tier AND every username in
# LITE_RECORDING_USERS (e.g. the cloud-init 'ubuntu' account) — neither goes
# through argus-tty add's onboarding pipeline, so neither ever gets a TOTP
# secret provisioned; making 2FA mandatory for them too would just lock them
# out the moment this flag flips on. See README.md "Two-factor
# authentication" for the full picture. ─────────────────────────────────────

section "PAM: Google Authenticator 2FA for SSH (gated by GOOGLE_2FA_ENABLED)"

PAM_2FA_MARKER_START="# BEGIN argus-tty Google Authenticator (managed by reconfigure.sh)"
PAM_2FA_MARKER_END="# END argus-tty Google Authenticator"
# Tagged so this exact line can be found again and restored when the flag
# is turned back off — @include common-auth (pam_unix) would otherwise
# always fail the keyboard-interactive phase for these accounts, since
# their passwords are locked (`passwd -l`) at onboarding.
COMMON_AUTH_DISABLED_LINE="#@include common-auth # argus-tty: disabled by GOOGLE_2FA_ENABLED=true, see reconfigure.sh"

if [[ -f "$AT_PAM_SSHD" ]]; then
  cp "$AT_PAM_SSHD" "${AT_PAM_SSHD}.bak.$(date '+%Y%m%d%H%M%S')"

  # Always start from a clean slate — strip any previously-managed block and
  # restore @include common-auth if we're the ones who disabled it — so
  # toggling GOOGLE_2FA_ENABLED off (or on, then off, then on again) never
  # leaves stale or duplicate lines behind.
  if grep -qF "$PAM_2FA_MARKER_START" "$AT_PAM_SSHD"; then
    awk -v start="$PAM_2FA_MARKER_START" -v end="$PAM_2FA_MARKER_END" '
      $0 == start {skip=1}
      !skip {print}
      $0 == end {skip=0}
    ' "$AT_PAM_SSHD" > "${AT_PAM_SSHD}.tmp"
    mv "${AT_PAM_SSHD}.tmp" "$AT_PAM_SSHD"
  fi
  if grep -qF "$COMMON_AUTH_DISABLED_LINE" "$AT_PAM_SSHD"; then
    sed -i "s|^${COMMON_AUTH_DISABLED_LINE//\//\\/}\$|@include common-auth|" "$AT_PAM_SSHD"
  fi

  if [[ "${GOOGLE_2FA_ENABLED:-false}" == "true" ]]; then
    if ! (command -v dpkg &>/dev/null && dpkg -s libpam-google-authenticator &>/dev/null); then
      info "Installing libpam-google-authenticator..."
      _apt_get update || warn "'apt-get update' failed (no network/mirror reachable?) — trying install anyway with the existing package index."
      _apt_get install -y libpam-google-authenticator \
        || error "Failed to install libpam-google-authenticator. Check network/mirror reachability, or install it manually on an air-gapped host, then re-run reconfigure."
    fi
    command -v google-authenticator &>/dev/null \
      || error "libpam-google-authenticator is installed but 'google-authenticator' still isn't on PATH — installation looks broken."

    sed -i 's|^@include[[:space:]]\+common-auth[[:space:]]*$|'"${COMMON_AUTH_DISABLED_LINE//\//\\/}"'|' "$AT_PAM_SSHD"

    # Each exemption is an independent OR condition — meeting ANY one of
    # them must skip all the way past every OTHER exemption check AND the
    # final pam_google_authenticator.so line. [success=N] jumps forward N
    # lines on success, so line i (0-indexed) needs N = (total - i) — NOT a
    # flat success=1 for every line, which would only ever skip the single
    # line immediately below it. Confirmed by an actual failed SSH login in
    # testing: with 2+ exemption lines all set to success=1, an exempt
    # account's condition matched (logged by pam_succeed_if) but execution
    # still fell through into pam_google_authenticator.so right after it.
    skip_conditions=("user ingroup ${AT_DEPLOYER_GROUP}")
    for u in ${LITE_RECORDING_USERS:-}; do
      skip_conditions+=("user = ${u}")
    done
    total_skip=${#skip_conditions[@]}
    skip_block=""
    for i in "${!skip_conditions[@]}"; do
      remaining=$(( total_skip - i ))
      line="auth [success=${remaining} default=ignore] pam_succeed_if.so ${skip_conditions[$i]}"
      skip_block="${skip_block:+${skip_block}$'\n'}${line}"
    done

    {
      echo ""
      echo "$PAM_2FA_MARKER_START"
      echo "$skip_block"
      echo "auth required pam_google_authenticator.so"
      # pam_succeed_if succeeding on its OWN doesn't finalize the stack as
      # authenticated — it only decides whether to skip forward. Without a
      # terminal module to land on, an exempt account's jump sails past the
      # end of the stack with nothing having explicitly asserted success,
      # and PAM denies the login anyway ("PAM: Permission denied", confirmed
      # by an actual failed SSH login for an exempt deployer account in
      # testing). pam_permit.so unconditionally succeeds — this is the same
      # jump-to-permit idiom Debian's own common-auth uses (pam_unix jumps
      # past pam_deny, lands on pam_permit).
      echo "auth required pam_permit.so"
      echo "$PAM_2FA_MARKER_END"
    } >> "$AT_PAM_SSHD"

    info "GOOGLE_2FA_ENABLED=true — TOTP required for developer/admin SSH sessions."
    info "Exempt from 2FA: '$AT_DEPLOYER_GROUP' group${LITE_RECORDING_USERS:+, and LITE_RECORDING_USERS ($LITE_RECORDING_USERS)}."
    warn "'@include common-auth' in $AT_PAM_SSHD is now disabled (required so locked-password accounts don't fail the keyboard-interactive phase via pam_unix) — reversible: set GOOGLE_2FA_ENABLED=false and re-run reconfigure."
    warn "New developer/admin accounts get a TOTP secret auto-provisioned by 'argus-tty add'/'add-admin'. EXISTING accounts do not — re-run 'argus-tty add <username>' for each one, or they'll be locked out at their next login."
  else
    info "GOOGLE_2FA_ENABLED=false — no TOTP required; $AT_PAM_SSHD left at its normal (publickey-only) stack."
  fi
else
  warn "$AT_PAM_SSHD not found — skipping Google Authenticator PAM wiring (unusual sshd install?)."
fi

# ── sshd: force every developer, admin, AND deployer session through the
# recorder; restrict SSH login to ONLY these tiers (+ ubuntu, recorded too —
# see argus-tty-wrapper's lite-recording mode for why it's still forced
# through the same ForceCommand despite skipping full .tty capture) so no
# other system/service account can log in interactively at all ────────────
# Marker text is kept stable across versions on purpose — it's how re-runs
# find and replace their own previous block instead of appending a duplicate.

# Resolved dynamically, never hardcoded as a guessed group name: an
# AllowGroups/Match entry for the wrong group could either lock ubuntu out
# or (worse) silently match nothing while looking correct. Skipped entirely
# (with a warning) if the 'ubuntu' account doesn't exist on this host.
UBUNTU_LOGIN_GROUP=""
if id ubuntu &>/dev/null; then
  UBUNTU_LOGIN_GROUP="$(id -gn ubuntu 2>/dev/null || true)"
  [[ -n "$UBUNTU_LOGIN_GROUP" ]] || warn "'ubuntu' account exists but its primary group could not be resolved — skipping it in AllowGroups/Match."
else
  info "No 'ubuntu' account on this host — skipping it in AllowGroups/Match (nothing to do)."
fi
# NOTE: AllowGroups takes a SPACE-separated list; Match Group takes a
# COMMA-separated list — genuinely different syntax for the two directives,
# not a typo either way. Using the wrong separator for AllowGroups doesn't
# fail `sshd -t` (a comma-joined string like "developer,admin,deployer" is
# still a syntactically valid single group-name PATTERN) — it just matches
# no real group, silently denying every account's login. Two separate
# variables here on purpose so that mistake can't happen again.
ALLOWED_LOGIN_GROUPS_SPACE="${AT_GROUP} ${AT_ADMIN_GROUP} ${AT_DEPLOYER_GROUP}${UBUNTU_LOGIN_GROUP:+ ${UBUNTU_LOGIN_GROUP}}"
ALLOWED_LOGIN_GROUPS_COMMA="${AT_GROUP},${AT_ADMIN_GROUP},${AT_DEPLOYER_GROUP}${UBUNTU_LOGIN_GROUP:+,${UBUNTU_LOGIN_GROUP}}"

section "sshd: AllowGroups $ALLOWED_LOGIN_GROUPS_SPACE + Match Group (recorder)"

AGENT_FWD="${ALLOW_AGENT_FORWARDING:-no}"
TCP_FWD="${ALLOW_TCP_FORWARDING:-no}"
X11_FWD="${ALLOW_X11_FORWARDING:-no}"

# Upstream OpenSSH renamed ChallengeResponseAuthentication to
# KbdInteractiveAuthentication in 8.7 (Aug 2021); confirmed on a real
# Ubuntu 20.04 container that Ubuntu's own OpenSSH 8.2p1 package already
# backports recognizing the newer name, so this isn't fixing an active
# break on stock Ubuntu — it's a defensive fallback for other builds
# (vanilla upstream OpenSSH, other distros) that only understand the
# original name and would fail `sshd -t` outright on the newer one
# ("Bad configuration option"). Detect the actual version and emit
# exactly the directive this host's sshd understands; defaults to the
# older, universally-supported name if detection fails for any reason
# (still valid, just deprecated, on newer OpenSSH too).
KBD_INTERACTIVE_DIRECTIVE="ChallengeResponseAuthentication"
if [[ "$(sshd -V 2>&1)" =~ OpenSSH_([0-9]+)\.([0-9]+) ]]; then
  ssh_major="${BASH_REMATCH[1]}"; ssh_minor="${BASH_REMATCH[2]}"
  if (( ssh_major > 8 || (ssh_major == 8 && ssh_minor >= 7) )); then
    KBD_INTERACTIVE_DIRECTIVE="KbdInteractiveAuthentication"
  fi
fi
if [[ "${GOOGLE_2FA_ENABLED:-false}" == "true" ]]; then
  info "Detected OpenSSH ${ssh_major:-?}.${ssh_minor:-?} — using '$KBD_INTERACTIVE_DIRECTIVE' for the keyboard-interactive (2FA) directive."
fi

MARKER_START="# BEGIN argus-tty Match block (managed by install.sh)"
MARKER_END="# END argus-tty Match block"

cp "$AT_SSHD_CONF" "${AT_SSHD_CONF}.bak.$(date '+%Y%m%d%H%M%S')"

# sshd_config directives OUTSIDE a Match block use FIRST-occurrence-wins,
# not last. Our own ChallengeResponseAuthentication/KbdInteractiveAuthentication
# override is emitted inside the managed block APPENDED at the end of this
# file (below) — so if an earlier line in the file already sets it, that
# earlier line silently wins and ours is ignored outright. Stock Ubuntu
# ships `ChallengeResponseAuthentication no` by default, which is exactly
# this collision. Confirmed empirically (real Ubuntu 20.04 container):
# without neutralizing it, sshd logs 'Disabled method "keyboard-interactive"
# in AuthenticationMethods list' and refuses EVERY login attempt with "no
# authentication methods enabled" — including deployer/LITE_RECORDING_USERS
# accounts that should never even see a 2FA prompt, since the method itself
# never becomes available at all, not even to skip.
#
# Always restore first (clean slate), same idiom as the PAM common-auth
# line — so toggling GOOGLE_2FA_ENABLED off (or on, then off, then on
# again) never leaves a stale neutralized line behind.
SSHD_KBDINT_DISABLED_TAG="# argus-tty: disabled by GOOGLE_2FA_ENABLED=true, see reconfigure.sh -- "
sed -i "s@^${SSHD_KBDINT_DISABLED_TAG}@@" "$AT_SSHD_CONF"
if [[ "${GOOGLE_2FA_ENABLED:-false}" == "true" ]]; then
  sed -i -E "s@^([[:space:]]*(ChallengeResponseAuthentication|KbdInteractiveAuthentication)[[:space:]].*)@${SSHD_KBDINT_DISABLED_TAG}\1@" "$AT_SSHD_CONF"
fi

if grep -qF "$MARKER_START" "$AT_SSHD_CONF"; then
  # Replace the existing managed block in place.
  awk -v start="$MARKER_START" -v end="$MARKER_END" '
    $0 == start {skip=1}
    !skip {print}
    $0 == end {skip=0}
  ' "$AT_SSHD_CONF" > "${AT_SSHD_CONF}.tmp"
  mv "${AT_SSHD_CONF}.tmp" "$AT_SSHD_CONF"
  info "Removed previous managed Match block before rewriting it."
fi

{
  echo ""
  echo "$MARKER_START"
  # Global directives — MUST stay before the Match block below (once a
  # Match block starts, subsequent lines are scoped to it, not global) —
  # this is a hard login gate: any account NOT in one of these groups is
  # refused SSH access outright, before ForceCommand or anything else
  # applies.
  if [[ "${GOOGLE_2FA_ENABLED:-false}" == "true" ]]; then
    echo "$KBD_INTERACTIVE_DIRECTIVE yes"
  fi
  echo "AllowGroups $ALLOWED_LOGIN_GROUPS_SPACE"
  echo "Match Group $ALLOWED_LOGIN_GROUPS_COMMA"
  echo "    ForceCommand $AT_WRAPPER_PATH"
  echo "    AllowAgentForwarding $AGENT_FWD"
  echo "    AllowTcpForwarding $TCP_FWD"
  echo "    X11Forwarding $X11_FWD"
  echo "    PermitTTY yes"
  if [[ "${GOOGLE_2FA_ENABLED:-false}" == "true" ]]; then
    # Applies to the whole Match block (developer/admin/deployer[/ubuntu]) —
    # deployer and LITE_RECORDING_USERS accounts still pass through this
    # keyboard-interactive step, but the PAM skip lines above mean it
    # succeeds instantly for them with no OTP prompt.
    echo "    AuthenticationMethods publickey,keyboard-interactive"
  fi
  echo "$MARKER_END"
} >> "$AT_SSHD_CONF"

info "Validating sshd config..."
if sshd -t; then
  info "sshd config OK — reloading sshd"
  systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || service ssh reload 2>/dev/null || true
else
  error "sshd config validation failed — restore from ${AT_SSHD_CONF}.bak.* before reloading."
fi

warn "AllowGroups now restricts SSH login to: $ALLOWED_LOGIN_GROUPS_SPACE — test a NEW connection as each tier (including ubuntu, if present) in a SEPARATE terminal before closing this session. Getting locked out means console/out-of-band access to fix sshd_config."

# ── systemd: enable/disable the mailer timer, gated by EMAIL_ENABLED ────────
# EMAIL_ENABLED is a real master switch, not just advisory: the timer is only
# ever running on a box where email notifications are actually turned on, so
# a box with EMAIL_ENABLED=false never attempts an SMTP connection at all.

section "Mailer timer (systemctl gated by EMAIL_ENABLED)"
if [[ -f "${AT_SYSTEMD_DIR}/argus-tty-mailer.timer" ]]; then
  # Migrate away from an earlier version that (incorrectly) installed units
  # directly under /etc/systemd/system.
  if [[ -f "${AT_SYSTEMD_LEGACY_DIR}/argus-tty-mailer.timer" ]]; then
    systemctl disable --now argus-tty-mailer.timer 2>/dev/null || true
    rm -f "${AT_SYSTEMD_LEGACY_DIR}/argus-tty-mailer.service" "${AT_SYSTEMD_LEGACY_DIR}/argus-tty-mailer.timer"
    info "Migrated argus-tty-mailer units from ${AT_SYSTEMD_LEGACY_DIR} to ${AT_SYSTEMD_DIR}."
  fi
  systemctl daemon-reload
  if [[ "${EMAIL_ENABLED:-false}" == "true" ]]; then
    systemctl enable --now argus-tty-mailer.timer
    info "EMAIL_ENABLED=true — argus-tty-mailer.timer enabled and running (drains queued notifications every 30s)."
  else
    systemctl disable --now argus-tty-mailer.timer 2>/dev/null || true
    info "EMAIL_ENABLED=false — argus-tty-mailer.timer disabled (no SMTP connection will ever be attempted). Set EMAIL_ENABLED=true in $AT_CONFIG_FILE and re-run reconfigure to turn it on."
  fi
else
  warn "${AT_SYSTEMD_DIR}/argus-tty-mailer.timer not found — mailer will not run."
fi

# ── Verify AWS CLI / S3, gated by S3_UPLOAD_ENABLED ─────────────────────────
# Same master-switch pattern as EMAIL_ENABLED above: S3 upload has no
# long-running daemon to enable/disable via systemctl, so S3_UPLOAD_ENABLED
# instead gates the upload logic itself inside argus-tty-finalize — this
# section is just the advisory connectivity check that mirrors that gate.

section "AWS CLI / S3"
if [[ "${S3_UPLOAD_ENABLED:-false}" != "true" ]]; then
  info "S3_UPLOAD_ENABLED=false — S3 upload disabled, sessions record locally only under $AT_SESSION_DIR. Set S3_UPLOAD_ENABLED=true in $AT_CONFIG_FILE (with S3_BUCKET/AWS_REGION filled in) to turn it on."
elif command -v aws &>/dev/null; then
  info "aws CLI found: $(aws --version 2>&1 | head -1)"
  if [[ -n "${S3_BUCKET:-}" ]]; then
    info "Testing S3 access to s3://$S3_BUCKET ..."
    if aws s3 ls "s3://$S3_BUCKET" --region "${AWS_REGION:-us-east-1}" &>/dev/null; then
      info "S3 access OK"
    else
      warn "S3 access check failed — verify the instance's IAM role has s3:PutObject on s3://$S3_BUCKET/${S3_PREFIX:-argus-tty}/*"
    fi
  else
    warn "S3_UPLOAD_ENABLED=true but S3_BUCKET is blank in $AT_CONFIG_FILE — nothing will be uploaded until it's set."
  fi
else
  warn "aws CLI not found — install it so sessions can be uploaded to S3:"
  warn "  curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip"
  warn "  unzip /tmp/awscliv2.zip -d /tmp && sudo /tmp/aws/install"
fi

command -v script &>/dev/null || warn "'script' binary not found — install bsdutils: sudo apt-get install -y bsdutils"

# ── Verify SMTP setup ────────────────────────────────────────────────────────

section "Email (SMTP via argus-tty-mailer)"
if [[ "${EMAIL_ENABLED:-false}" == "true" ]]; then
  command -v curl &>/dev/null || warn "curl not found — install it: sudo apt-get install -y curl"
  [[ -n "${SMTP_HOST:-}" ]] || warn "SMTP_HOST not set in $AT_CONFIG_FILE"

  # `|| true` so a missing/unset var here can't abort the rest of this
  # script under `set -e` — this whole section is advisory.
  ( # shellcheck disable=SC1090
    source "$AT_SMTP_CREDS_FILE" 2>/dev/null
    [[ -n "${SMTP_USER:-}" && -n "${SMTP_PASS:-}" ]]
  ) && info "SMTP credentials are set in $AT_SMTP_CREDS_FILE" \
    || warn "SMTP_USER/SMTP_PASS not set in $AT_SMTP_CREDS_FILE — emails will fail until configured."

  if [[ -n "${SMTP_HOST:-}" ]]; then
    if timeout 5 bash -c "echo > /dev/tcp/${SMTP_HOST}/${SMTP_PORT:-587}" 2>/dev/null; then
      info "SMTP endpoint reachable: ${SMTP_HOST}:${SMTP_PORT:-587}"
    else
      warn "Could not reach ${SMTP_HOST}:${SMTP_PORT:-587} — check network/security groups."
    fi
  fi
else
  info "Email notifications disabled (EMAIL_ENABLED=false in $AT_CONFIG_FILE)."
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "══════════════════════════════════════════════════════════════"
info "Configuration complete."
echo ""
info "Onboard a developer:  sudo argus-tty add <username> --pubkey <file>"
info "Onboard an admin:     sudo argus-tty add-admin <username> --pubkey <file>"
info "Onboard a deployer:   sudo argus-tty add-deployer <username> --pubkey <file>"
info "Bulk onboard:         sudo argus-tty bulk-add developer_users.conf"
info "Check health anytime: sudo argus-tty status"
info "Customize sudo perms: cp $AT_DEV_SUDOERS_SAMPLE $AT_DEV_SUDOERS_OVERRIDE, edit, then reconfigure again"
info "2FA (Google Authenticator): set GOOGLE_2FA_ENABLED=true in $AT_CONFIG_FILE, re-run reconfigure, then re-run 'argus-tty add <username>' for each EXISTING developer/admin to provision their TOTP secret."
echo ""
warn "Test a developer/admin connection in a NEW terminal before closing your"
warn "current session — if sshd_config is wrong you could get locked out."
echo "══════════════════════════════════════════════════════════════"
