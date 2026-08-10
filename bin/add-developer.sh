#!/bin/bash
# add-developer.sh — find-or-create ONE developer (or admin) account.
#
# Idempotent: safe to re-run for a user that already exists (e.g. to install
# a new key, or after re-running install.sh). This is the actual "one click"
# onboarding step; `argus-tty bulk-add` just loops this over a roster file.
#
# Usage:
#   add-developer.sh <username> [--name "Display Name"] [--pubkey <file>|-]
#                     [--no-key] [--print-key] [--group developer|admin]
#
#   --pubkey -      read the public key from stdin
#   --pubkey <file> read the public key from a file
#   (omit --pubkey) a new SSH keypair is GENERATED for this user (PEM-format
#                   private key, like a classic AWS EC2 .pem) and stored under
#                   AT_GENERATED_KEYS_DIR (see lib/common.sh) so you can hand
#                   it to the developer. Only the public half goes into
#                   authorized_keys; the private half never leaves this host
#                   automatically — copy it off (scp/secrets manager/etc.)
#                   and then remove it from the server yourself.
#   --no-key        create the account with no key at all (skip generation);
#                   add one later by re-running with --pubkey.
#   --print-key     also print the generated private key to stdout (only
#                   meaningful when a key is actually generated).
#   --group admin   onboard as a full-sudo ADMIN instead of a whitelisted
#                   developer (see add-admin.sh, a thin wrapper for this).
#                   Admin sessions are recorded exactly like developer ones.
#   --group deployer  onboard as a DEPLOYER instead: the narrowest tier,
#                   restricted to starting/stopping/restarting services —
#                   no console, rake, install, setup, apt-get, or docker
#                   (see add-deployer.sh, a thin wrapper for this). Sessions
#                   are recorded exactly like developer/admin ones.
#   --allow-from <ip-or-cidr>[,<ip-or-cidr>...]
#                   OPTIONAL: restrict this account's key(s) to only
#                   authenticate from the given source IP(s)/CIDR(s) (same
#                   mechanism as `argus-tty allow-ip`, just settable inline
#                   at onboarding time instead of as a separate step
#                   afterward). Omit entirely for no restriction (the
#                   default) — this is opt-in, never required.
#
# If GOOGLE_2FA_ENABLED=true in config.env, a TOTP secret is auto-generated
# and printed once for developer/admin accounts (never for deployer — see
# README.md "Two-factor authentication"). Re-running for an already-enrolled
# account leaves its existing secret alone.

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib"
# shellcheck source=../lib/common.sh
source "${LIB_DIR}/common.sh"
# common.sh already sources config.env defensively (for AT_GROUP/
# AT_ADMIN_GROUP/AT_DEPLOYER_GROUP) — GOOGLE_2FA_ENABLED comes along with it.

usage() {
  echo "Usage: $0 <username> [--name \"Display Name\"] [--pubkey <file>|-] [--no-key] [--print-key] [--group developer|admin|deployer] [--allow-from <ip-or-cidr>[,<ip-or-cidr>...]]"
  exit 1
}

[[ $# -ge 1 ]] || usage
USERNAME="$1"; shift
DISPLAY_NAME="$USERNAME"
PUBKEY_SRC=""
NO_KEY=false
PRINT_KEY=false
GROUP="$AT_GROUP"
ALLOW_FROM=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)       DISPLAY_NAME="$2"; shift 2 ;;
    --pubkey)     PUBKEY_SRC="$2"; shift 2 ;;
    --no-key)     NO_KEY=true; shift ;;
    --print-key)  PRINT_KEY=true; shift ;;
    --group)      GROUP="$2"; shift 2 ;;
    --allow-from) ALLOW_FROM="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ "$ALLOW_FROM" != *'"'* && "$ALLOW_FROM" != *$'\n'* ]] \
  || error "--allow-from cannot contain a double-quote or newline."

require_root
valid_username "$USERNAME" \
  || error "Invalid username '$USERNAME' (must match ^[a-z][a-z0-9_-]{0,31}$)."
valid_gecos "$DISPLAY_NAME" \
  || error "Invalid --name '$DISPLAY_NAME' — can't contain ':' or a newline (useradd's GECOS field, colon-delimited in /etc/passwd)."

extra_group_list=()
case "$GROUP" in
  "$AT_GROUP") ;;
  "$AT_ADMIN_GROUP") extra_group_list+=("sudo") ;;   # so PAM's su restriction (group=sudo) doesn't block admins
  "$AT_DEPLOYER_GROUP") ;;   # narrowest tier — no 'sudo' group, same as developer
  *) error "Unknown --group '$GROUP' (expected '$AT_GROUP', '$AT_ADMIN_GROUP', or '$AT_DEPLOYER_GROUP')." ;;
esac

# Every developer, admin, AND deployer gets deploy access to /var/www/<app>
# (webapps group) and, if RVM is installed, to its rubies/gemsets (rvm
# group) — see lib/common.sh. The clone/bundle install/symlink steps a
# deploy performs are plain file operations under these groups, not
# something sudo mediates, so a deployer needs them same as anyone else —
# your own deploy tooling's own role checks are what keep a deployer-only
# account from using that same file access to run console/rake/install
# instead. RVM's group is only joined if it already exists: this toolkit
# doesn't install RVM itself, so on a box without it there's nothing to join
# yet.
extra_group_list+=("$AT_WEBAPPS_GROUP")
getent group "$AT_RVM_GROUP" &>/dev/null && extra_group_list+=("$AT_RVM_GROUP")
EXTRA_GROUPS="$(IFS=,; echo "${extra_group_list[*]}")"

# ── Group ────────────────────────────────────────────────────────────────────

if ! getent group "$GROUP" &>/dev/null; then
  groupadd "$GROUP"
  info "Created group '$GROUP'."
fi
if ! getent group "$AT_WEBAPPS_GROUP" &>/dev/null; then
  groupadd "$AT_WEBAPPS_GROUP"
  info "Created group '$AT_WEBAPPS_GROUP'."
fi

# ── Find or create the account ──────────────────────────────────────────────

if id "$USERNAME" &>/dev/null; then
  info "User '$USERNAME' already exists — ensuring group membership."
  usermod -g "$GROUP" "$USERNAME"
  # EXTRA_GROUPS is always non-empty now (webapps at minimum) — usermod -aG
  # only ADDS groups, so dropping 'sudo' on demotion has to be a separate,
  # unconditional step below rather than the old if/elif (which would have
  # silently stopped firing once EXTRA_GROUPS could no longer be empty).
  usermod -aG "$EXTRA_GROUPS" "$USERNAME"
  if [[ "$GROUP" == "$AT_GROUP" || "$GROUP" == "$AT_DEPLOYER_GROUP" ]]; then
    # Demoting an existing admin back to developer/deployer: also drop
    # 'sudo' membership so PAM/su and default Ubuntu sudo grants are
    # revoked too, not just our own group-based whitelist.
    gpasswd -d "$USERNAME" sudo &>/dev/null || true
  fi
else
  useradd_args=(--create-home --shell /bin/bash --gid "$GROUP" --comment "$DISPLAY_NAME")
  [[ -n "$EXTRA_GROUPS" ]] && useradd_args+=(--groups "$EXTRA_GROUPS")
  useradd "${useradd_args[@]}" "$USERNAME"
  passwd -l "$USERNAME" >/dev/null   # lock password — SSH key auth only
  info "Created '$USERNAME' ($DISPLAY_NAME) [$GROUP] — password locked, SSH key auth only."
fi

# ── Home directory hardening ────────────────────────────────────────────────

home_dir="/home/$USERNAME"
chmod 750 "$home_dir"
chown "$USERNAME:$GROUP" "$home_dir"

ssh_dir="$home_dir/.ssh"
mkdir -p "$ssh_dir"
chmod 700 "$ssh_dir"
chown "$USERNAME:$GROUP" "$ssh_dir"

auth_keys="$ssh_dir/authorized_keys"
touch "$auth_keys"
chmod 600 "$auth_keys"
chown "$USERNAME:$GROUP" "$auth_keys"

# ── SSH key ──────────────────────────────────────────────────────────────────
# Three ways this can go: a key file/stdin was passed in; no key was passed
# and one already exists (leave it alone); no key was passed and none exists
# yet, so generate one (unless --no-key).

generated_key_path=""

if [[ -n "$PUBKEY_SRC" ]]; then
  if [[ "$PUBKEY_SRC" == "-" ]]; then
    pub_key="$(cat)"
  else
    [[ -f "$PUBKEY_SRC" ]] || error "Pubkey file not found: $PUBKEY_SRC"
    pub_key="$(cat "$PUBKEY_SRC")"
  fi
  if valid_pubkey "$pub_key"; then
    echo "$pub_key" >> "$auth_keys"
    sort -u -o "$auth_keys" "$auth_keys"
    info "SSH key installed for '$USERNAME'."
  else
    error "That doesn't look like a valid SSH public key (expected ssh-rsa/ssh-ed25519/ecdsa/sk-ssh-ed25519)."
  fi
elif [[ -s "$auth_keys" ]]; then
  info "'$USERNAME' already has a key installed — leaving it as-is."
elif $NO_KEY; then
  warn "No SSH key for '$USERNAME' (--no-key). Add one later:"
  warn "  sudo $0 $USERNAME --pubkey <file>"
else
  command -v ssh-keygen &>/dev/null || error "ssh-keygen not found — install openssh-client, or pass --pubkey/--no-key."

  mkdir -p "$AT_GENERATED_KEYS_DIR"
  chown root:root "$AT_GENERATED_KEYS_DIR"
  chmod 700 "$AT_GENERATED_KEYS_DIR"

  generated_key_path="${AT_GENERATED_KEYS_DIR}/${USERNAME}.pem"
  if [[ -e "$generated_key_path" ]]; then
    warn "A previously generated key already exists at $generated_key_path — reusing it rather than overwriting."
  else
    ssh-keygen -t rsa -b 4096 -m PEM -N "" -C "${USERNAME}@argus-tty" -f "$generated_key_path" -q
    info "Generated a new PEM keypair for '$USERNAME'."
  fi
  chmod 600 "$generated_key_path" "${generated_key_path}.pub"
  chown root:root "$generated_key_path" "${generated_key_path}.pub"

  pub_key="$(cat "${generated_key_path}.pub")"
  echo "$pub_key" >> "$auth_keys"
  sort -u -o "$auth_keys" "$auth_keys"
fi

key_status="MISSING"
[[ -s "$auth_keys" ]] && key_status="installed"
[[ -n "$generated_key_path" ]] && key_status="generated"

# --allow-from is entirely opt-in: only applied if given, and only if there's
# actually a key to restrict. Same rewrite helper `argus-tty allow-ip` uses —
# just settable inline here instead of as a required separate step.
allow_from_status="not restricted (connects from anywhere)"
if [[ -n "$ALLOW_FROM" ]]; then
  if [[ -s "$auth_keys" ]]; then
    set_authorized_keys_from "$USERNAME" "$ALLOW_FROM"
    allow_from_status="$ALLOW_FROM"
  else
    warn "--allow-from given but '$USERNAME' has no key installed yet — nothing to restrict. Re-run with --pubkey, or use 'argus-tty allow-ip $USERNAME ...' once a key exists."
  fi
fi

# ── Google Authenticator (TOTP) 2FA ─────────────────────────────────────────
# Gated by GOOGLE_2FA_ENABLED (config.env) and never applied to the deployer
# tier — see README.md "Two-factor authentication" for why. Mirrors the
# generated-SSH-key flow above: a secret is auto-provisioned non-
# interactively and printed ONCE for the admin to hand off; re-running this
# command for an already-enrolled account leaves the existing secret alone.

totp_status="not required (2FA disabled — GOOGLE_2FA_ENABLED=false)"
totp_secret_file="${home_dir}/.google_authenticator"
totp_output=""

if [[ "$GROUP" == "$AT_DEPLOYER_GROUP" ]]; then
  totp_status="not required (deployer tier is exempt from 2FA)"
elif [[ "${GOOGLE_2FA_ENABLED:-false}" == "true" ]]; then
  if [[ -s "$totp_secret_file" ]]; then
    totp_status="already enrolled — leaving existing secret as-is"
  else
    command -v google-authenticator &>/dev/null \
      || error "GOOGLE_2FA_ENABLED=true but 'google-authenticator' isn't installed — run 'sudo argus-tty reconfigure' first (installs libpam-google-authenticator), then re-run this command."
    totp_output="$(sudo -u "$USERNAME" google-authenticator -t -d -f -r 3 -R 30 -w 3 -Q UTF8 2>&1)"
    [[ -s "$totp_secret_file" ]] \
      || error "google-authenticator ran but $totp_secret_file was not created — check the output above."
    chmod 400 "$totp_secret_file"
    chown "${USERNAME}:${GROUP}" "$totp_secret_file"
    totp_status="generated — printed below, save it now (shown only this once)"
  fi
fi

echo ""
info "Account ready:"
printf "  %-14s %s\n" "User:"    "$USERNAME ($DISPLAY_NAME)"
printf "  %-14s %s\n" "Home:"    "$home_dir  (750)"
printf "  %-14s %s\n" "Group:"   "$GROUP${EXTRA_GROUPS:+, $EXTRA_GROUPS}"
printf "  %-14s %s\n" "SSH key:" "$key_status"
printf "  %-14s %s\n" "Allowed from:" "$allow_from_status"
printf "  %-14s %s\n" "2FA (TOTP):" "$totp_status"
printf "  %-14s %s\n" "Connect:" "ssh $USERNAME@<host>"

if [[ -n "$totp_output" ]]; then
  echo ""
  warn "Google Authenticator secret generated for '$USERNAME' — shown ONLY this once, $totp_secret_file is root/user-readable only (400):"
  echo "── BEGIN ${USERNAME} TOTP enrollment (copy everything below until END) ──"
  echo "$totp_output"
  echo "── END ${USERNAME} TOTP enrollment ──"
  warn "Have them scan the QR code above (or enter the secret key manually) into Google Authenticator/Authy/1Password, and save the emergency scratch codes somewhere safe — each is single-use if they lose their device."
fi

if [[ -n "$generated_key_path" ]]; then
  echo ""
  warn "Private key stored at: $generated_key_path (root-only, 600)"
  warn "Share it with the developer over a secure channel, e.g.:"
  warn "  scp $generated_key_path yourlaptop:~/Downloads/${USERNAME}.pem"
  warn "Then have them connect with:"
  warn "  chmod 600 ${USERNAME}.pem && ssh -i ${USERNAME}.pem $USERNAME@<host>"
  warn "Once handed off, consider removing the copy on this server:"
  warn "  sudo shred -u $generated_key_path"
  if $PRINT_KEY; then
    echo ""
    echo "── BEGIN ${USERNAME}.pem (copy everything below until END) ──"
    cat "$generated_key_path"
    echo "── END ${USERNAME}.pem ──"
  fi
fi
