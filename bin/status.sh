#!/bin/bash
# status.sh — health check for the argus-tty install on this machine.
# Non-fatal by design: reports every check and exits non-zero only if
# something is actually broken, so it's safe to run anytime.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib"
# shellcheck source=../lib/common.sh
source "${LIB_DIR}/common.sh"

require_root

FAIL=0
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
bad()  { echo -e "  ${RED}✗${NC} $*"; FAIL=1; }

# common.sh already sources config.env defensively (for AT_GROUP/
# AT_ADMIN_GROUP/AT_DEPLOYER_GROUP) — EMAIL_ENABLED/GOOGLE_2FA_ENABLED/etc.
# come along with it, in time for the mailer-timer check right below.

section "Core install"
[[ -f "$AT_WRAPPER_PATH" ]] && ok "Wrapper installed at $AT_WRAPPER_PATH" || bad "Wrapper missing at $AT_WRAPPER_PATH"
[[ -x "$AT_WRAPPER_PATH" ]] && ok "Wrapper is readable+executable (required for bash to parse it — 711 would silently break every login)" \
  || bad "Wrapper is not executable — check permissions on $AT_WRAPPER_PATH"
[[ -f "$AT_FINALIZE_PATH" ]] && ok "Finalize helper installed at $AT_FINALIZE_PATH" || bad "Finalize helper missing at $AT_FINALIZE_PATH"
[[ -x "$AT_MAILER_PATH" ]] && ok "Mailer helper installed at $AT_MAILER_PATH" || bad "Mailer helper missing at $AT_MAILER_PATH"
for f in "$AT_WRAPPER_PATH" "$AT_FINALIZE_PATH" "$AT_MAILER_PATH"; do
  if lsattr "$f" &>/dev/null && lsattr "$f" 2>/dev/null | grep -q '^....i'; then
    ok "$(basename "$f") is immutable (chattr +i)"
  else
    warn "$(basename "$f") is not marked immutable — consider: chattr +i $f"
  fi
done
[[ -d "$AT_SESSION_DIR" ]] && ok "Session dir exists: $AT_SESSION_DIR" || bad "Session dir missing: $AT_SESSION_DIR"
[[ -d "$AT_NOTIFY_DIR" ]] && ok "Notification dir exists: $AT_NOTIFY_DIR" || bad "Notification dir missing: $AT_NOTIFY_DIR"
[[ -f "$AT_CONFIG_FILE" ]] && ok "Config present: $AT_CONFIG_FILE" || bad "Config missing: $AT_CONFIG_FILE — run 'argus-tty install'"
if [[ -f "$AT_SMTP_CREDS_FILE" ]]; then
  creds_mode=$(stat -c '%a' "$AT_SMTP_CREDS_FILE" 2>/dev/null)
  [[ "$creds_mode" == "600" ]] \
    && ok "SMTP credentials present and root-only (600): $AT_SMTP_CREDS_FILE" \
    || bad "SMTP credentials file mode is $creds_mode, expected 600: $AT_SMTP_CREDS_FILE"
else
  bad "SMTP credentials missing: $AT_SMTP_CREDS_FILE — run 'argus-tty install'"
fi
[[ -f "$AT_SUDOERS_FILE" ]] && ok "Developer sudoers whitelist present" || bad "Developer sudoers whitelist missing: $AT_SUDOERS_FILE"
[[ -f "$AT_ADMIN_SUDOERS_FILE" ]] && ok "Admin sudoers grant present" || bad "Admin sudoers grant missing: $AT_ADMIN_SUDOERS_FILE"
[[ -f "$AT_DEPLOYER_SUDOERS_FILE" ]] && ok "Deployer sudoers whitelist present" || bad "Deployer sudoers whitelist missing: $AT_DEPLOYER_SUDOERS_FILE"
[[ -f "$AT_LOGROTATE_CONF" ]] && ok "Logrotate config present" || bad "Logrotate config missing: $AT_LOGROTATE_CONF"

section "sshd"
if grep -q "^Match Group $AT_GROUP,$AT_ADMIN_GROUP,$AT_DEPLOYER_GROUP" "$AT_SSHD_CONF" 2>/dev/null; then
  ok "sshd_config has a 'Match Group $AT_GROUP,$AT_ADMIN_GROUP,$AT_DEPLOYER_GROUP...' block"
else
  bad "sshd_config is missing the 'Match Group $AT_GROUP,$AT_ADMIN_GROUP,$AT_DEPLOYER_GROUP...' block — run 'argus-tty install'"
fi
if grep -q "^AllowGroups .*\b${AT_GROUP}\b.*\b${AT_ADMIN_GROUP}\b.*\b${AT_DEPLOYER_GROUP}\b" "$AT_SSHD_CONF" 2>/dev/null; then
  ok "sshd_config has an AllowGroups line covering $AT_GROUP/$AT_ADMIN_GROUP/$AT_DEPLOYER_GROUP"
else
  bad "sshd_config is missing (or has an incomplete) AllowGroups line — run 'argus-tty install'. Without it, accounts outside developer/admin/deployer/ubuntu are NOT denied login."
fi
if sshd -t 2>/dev/null; then
  ok "sshd config is valid (sshd -t)"
else
  bad "sshd config failed validation (sshd -t) — do not reload until fixed"
fi

section "Two-factor authentication (Google Authenticator, gated by GOOGLE_2FA_ENABLED)"
if [[ "${GOOGLE_2FA_ENABLED:-false}" == "true" ]]; then
  if command -v google-authenticator &>/dev/null; then
    ok "libpam-google-authenticator is installed"
  else
    bad "GOOGLE_2FA_ENABLED=true but 'google-authenticator' is not installed — run 'argus-tty reconfigure'"
  fi
  if grep -qF "BEGIN argus-tty Google Authenticator" "$AT_PAM_SSHD" 2>/dev/null; then
    ok "$AT_PAM_SSHD has the managed Google Authenticator block"
  else
    bad "$AT_PAM_SSHD is missing the managed Google Authenticator block — run 'argus-tty reconfigure'"
  fi
  if grep -qE '^[[:space:]]*AuthenticationMethods[[:space:]]+publickey,keyboard-interactive' "$AT_SSHD_CONF" 2>/dev/null; then
    ok "sshd_config requires publickey,keyboard-interactive in the Match block"
  else
    bad "sshd_config is missing 'AuthenticationMethods publickey,keyboard-interactive' — run 'argus-tty reconfigure'"
  fi
  dev_gid_2fa="$(getent group "$AT_GROUP" 2>/dev/null | cut -d: -f3)"
  admin_gid_2fa="$(getent group "$AT_ADMIN_GROUP" 2>/dev/null | cut -d: -f3)"
  unenrolled=0
  for u in $(getent passwd | awk -F: -v d="${dev_gid_2fa:--1}" -v a="${admin_gid_2fa:--1}" '$4==d || $4==a {print $1}'); do
    home="$(getent passwd "$u" | cut -d: -f6)"
    [[ -n "$home" && -s "${home}/.google_authenticator" ]] || { warn "'$u' has no TOTP secret enrolled yet — will be locked out of SSH until 'argus-tty add $u' is re-run"; unenrolled=$((unenrolled + 1)); }
  done
  [[ "$unenrolled" -eq 0 ]] && ok "Every developer/admin account has a TOTP secret enrolled"
else
  ok "2FA disabled (GOOGLE_2FA_ENABLED=false) — publickey-only login, as before"
fi

section "Mail queue (argus-tty-mailer.timer, gated by EMAIL_ENABLED)"
if [[ "${EMAIL_ENABLED:-false}" == "true" ]]; then
  if systemctl is-active --quiet argus-tty-mailer.timer 2>/dev/null; then
    ok "argus-tty-mailer.timer is active (EMAIL_ENABLED=true)"
  else
    bad "EMAIL_ENABLED=true but argus-tty-mailer.timer is not active — run 'argus-tty reconfigure'"
  fi
else
  if systemctl is-active --quiet argus-tty-mailer.timer 2>/dev/null; then
    warn "argus-tty-mailer.timer is active but EMAIL_ENABLED=false — run 'argus-tty reconfigure' to disable it"
  else
    ok "argus-tty-mailer.timer is disabled (EMAIL_ENABLED=false — email notifications are turned off)"
  fi
fi
pending=$(find "$AT_NOTIFY_DIR" -maxdepth 1 -name '*.notify*' 2>/dev/null | wc -l | tr -d ' ')
failed=$(find "$AT_NOTIFY_DIR/failed" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
info "Notification queue: ${pending:-0} pending, ${failed:-0} failed (see $AT_NOTIFY_DIR/failed)"

section "Dependencies"
command -v script &>/dev/null && ok "'script' binary present" || bad "'script' binary missing — install bsdutils"
command -v aws &>/dev/null && ok "aws CLI present ($(aws --version 2>&1 | head -1))" \
  || warn "aws CLI missing — sessions still record locally under $AT_SESSION_DIR, but S3 upload is skipped"
command -v curl &>/dev/null && ok "curl present (needed for SMTP send)" || warn "curl missing — install it: apt-get install -y curl"

# AWS/SMTP connectivity is advisory only, not a FAIL: argus-tty-finalize and
# argus-tty-mailer already check readiness themselves before every attempt
# and degrade gracefully (skip, log a warning, keep data on disk/in queue)
# when aws/SMTP are missing or unconfigured — that's by design, not a broken
# install.
if [[ -f "$AT_CONFIG_FILE" ]]; then
  section "S3 connectivity (advisory — recording works either way)"
  if [[ "${S3_UPLOAD_ENABLED:-false}" != "true" ]]; then
    ok "S3 upload is disabled (S3_UPLOAD_ENABLED=false) — sessions record locally only under $AT_SESSION_DIR"
  elif ! command -v aws &>/dev/null; then
    warn "aws CLI not installed — skipping S3 check."
  elif ! AWS_METADATA_SERVICE_TIMEOUT=1 AWS_METADATA_SERVICE_NUM_ATTEMPTS=1 \
      timeout 3 aws sts get-caller-identity --region "${AWS_REGION:-us-east-1}" &>/dev/null; then
    warn "No usable AWS credentials/IAM role resolved — S3 upload will be skipped for every session."
  elif [[ -n "${S3_BUCKET:-}" ]]; then
    if aws s3 ls "s3://${S3_BUCKET}" --region "${AWS_REGION:-us-east-1}" &>/dev/null; then
      ok "S3 reachable: s3://${S3_BUCKET}"
    else
      warn "Cannot reach s3://${S3_BUCKET} — check IAM role has s3:PutObject/s3:ListBucket"
    fi
  else
    warn "S3_UPLOAD_ENABLED=true but S3_BUCKET is blank — nothing will be uploaded until it's set."
  fi

  if [[ "${EMAIL_ENABLED:-false}" == "true" ]]; then
    section "SMTP connectivity (advisory — recording works either way)"
    if [[ -z "${SMTP_HOST:-}" ]]; then
      warn "SMTP_HOST not set in $AT_CONFIG_FILE"
    elif timeout 5 bash -c "echo > /dev/tcp/${SMTP_HOST}/${SMTP_PORT:-587}" 2>/dev/null; then
      ok "SMTP endpoint reachable: ${SMTP_HOST}:${SMTP_PORT:-587}"
    else
      warn "Could not reach ${SMTP_HOST}:${SMTP_PORT:-587} — check network/security groups."
    fi
    if [[ -f "$AT_SMTP_CREDS_FILE" ]]; then
      # shellcheck disable=SC1090
      source "$AT_SMTP_CREDS_FILE"
      [[ -n "${SMTP_USER:-}" && -n "${SMTP_PASS:-}" ]] \
        && ok "SMTP_USER/SMTP_PASS are set" \
        || warn "SMTP_USER/SMTP_PASS not set in $AT_SMTP_CREDS_FILE — emails will fail until configured."
    fi
  fi
fi

section "Accounts"
dev_gid="$(getent group "$AT_GROUP" 2>/dev/null | cut -d: -f3)"
admin_gid="$(getent group "$AT_ADMIN_GROUP" 2>/dev/null | cut -d: -f3)"
deployer_gid="$(getent group "$AT_DEPLOYER_GROUP" 2>/dev/null | cut -d: -f3)"
dev_count=0; admin_count=0; deployer_count=0
[[ -n "$dev_gid" ]] && dev_count=$(getent passwd | awk -F: -v gid="$dev_gid" '$4==gid' | wc -l | tr -d ' ')
[[ -n "$admin_gid" ]] && admin_count=$(getent passwd | awk -F: -v gid="$admin_gid" '$4==gid' | wc -l | tr -d ' ')
[[ -n "$deployer_gid" ]] && deployer_count=$(getent passwd | awk -F: -v gid="$deployer_gid" '$4==gid' | wc -l | tr -d ' ')
info "$dev_count developer(s), $admin_count admin(s), $deployer_count deployer(s) onboarded — see 'argus-tty list' / 'argus-tty list-admins' / 'argus-tty list-deployers'"

section "Disk usage"
du -sh "$AT_SESSION_DIR" 2>/dev/null | awk '{print "  " $1 " used in " $2}'

echo ""
if [[ "$FAIL" -eq 0 ]]; then
  info "All checks passed."
else
  warn "One or more checks failed — see above."
fi
exit "$FAIL"
