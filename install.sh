#!/bin/bash
# install.sh — manual, non-packaged installer for the argus-tty toolkit.
#
# If you can use the .deb package instead (see README.md → "Installing"),
# prefer that — it gives you upgrade/removal semantics via dpkg/apt for
# free. This script exists for machines where you can't use a .deb: it
# copies every file this toolkit ships to its canonical system location
# (mirroring exactly what the package's data.tar contains), then hands off
# to lib/reconfigure.sh — the SAME idempotent system-configuration script
# the package's postinst calls — to do the actual wiring (groups, PAM,
# sshd, systemd, sudoers validation, advisory AWS/SMTP checks).
#
# Usage (files MUST be in a root-owned, non-world-writable directory):
#   sudo cp -r /path/to/user_audit /root/argus-tty
#   sudo chmod 700 /root/argus-tty
#   sudo /root/argus-tty/install.sh
#
# Safe to re-run any time (e.g. after editing config.env) — every step here
# is idempotent. It does NOT touch developer/admin accounts; use
# './argus-tty add <username>' or './argus-tty add-admin <username>' for
# that.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
refuse_unsafe_dir "$SCRIPT_DIR"

section "Required system packages"
ensure_required_packages

for f in bin/argus-tty-wrapper.sh bin/argus-tty-finalize.sh bin/argus-tty-mailer.sh \
         systemd/argus-tty-mailer.service systemd/argus-tty-mailer.timer \
         config/config.env.example config/smtp-credentials.env.example \
         sudoers/developer.sudoers.sample sudoers/admin.sudoers.sample \
         sudoers/deployer.sudoers.sample logrotate/argus-tty \
         lib/reconfigure.sh; do
  [[ -f "${SCRIPT_DIR}/${f}" ]] || error "${f} not found under ${SCRIPT_DIR} — incomplete checkout?"
done

# ── Install the three standalone binaries ───────────────────────────────────

section "Session recorder"
mkdir -p "$(dirname "$AT_WRAPPER_PATH")"
chattr -i "$AT_WRAPPER_PATH" 2>/dev/null || true   # allow overwrite on re-install
cp "${SCRIPT_DIR}/bin/argus-tty-wrapper.sh" "$AT_WRAPPER_PATH"
chown root:root "$AT_WRAPPER_PATH"
# 755, not 711: a shebang script needs read access for bash to parse it, so
# an execute-only script silently fails with "permission denied" for every
# non-root invoker. Writable only by root; chattr +i (applied later by
# reconfigure.sh) is the real tamper protection, not the read bit.
chmod 755 "$AT_WRAPPER_PATH"
info "Installed → $AT_WRAPPER_PATH"

section "Finalize helper (detached S3 upload)"
chattr -i "$AT_FINALIZE_PATH" 2>/dev/null || true
cp "${SCRIPT_DIR}/bin/argus-tty-finalize.sh" "$AT_FINALIZE_PATH"
chown root:root "$AT_FINALIZE_PATH"
chmod 755 "$AT_FINALIZE_PATH"
info "Installed → $AT_FINALIZE_PATH"

section "Mailer (root-only SMTP sender)"
chattr -i "$AT_MAILER_PATH" 2>/dev/null || true
cp "${SCRIPT_DIR}/bin/argus-tty-mailer.sh" "$AT_MAILER_PATH"
chown root:root "$AT_MAILER_PATH"
chmod 700 "$AT_MAILER_PATH"   # root-only: invoked exclusively by the systemd timer
info "Installed → $AT_MAILER_PATH"

section "Systemd units"
mkdir -p "$AT_SYSTEMD_DIR"
cp "${SCRIPT_DIR}/systemd/argus-tty-mailer.service" "${AT_SYSTEMD_DIR}/argus-tty-mailer.service"
cp "${SCRIPT_DIR}/systemd/argus-tty-mailer.timer" "${AT_SYSTEMD_DIR}/argus-tty-mailer.timer"
chown root:root "${AT_SYSTEMD_DIR}/argus-tty-mailer.service" "${AT_SYSTEMD_DIR}/argus-tty-mailer.timer"
chmod 644 "${AT_SYSTEMD_DIR}/argus-tty-mailer.service" "${AT_SYSTEMD_DIR}/argus-tty-mailer.timer"
info "Installed → ${AT_SYSTEMD_DIR}/argus-tty-mailer.{service,timer}"

# ── Config files (only if not already present — never clobber edits) ───────

section "Config"
mkdir -p "$AT_ETC_DIR"
chmod 755 "$AT_ETC_DIR"
if [[ -f "$AT_CONFIG_FILE" ]]; then
  info "$AT_CONFIG_FILE already exists — leaving it untouched."
else
  cp "${SCRIPT_DIR}/config/config.env.example" "$AT_CONFIG_FILE"
  warn "Installed default config → $AT_CONFIG_FILE — EDIT IT before onboarding developers:"
  warn "  sudo \${EDITOR:-vi} $AT_CONFIG_FILE"
fi
chown root:root "$AT_CONFIG_FILE"
# 644, not 600: argus-tty-wrapper and argus-tty-finalize run as the
# connecting developer's own uid and need to read this file, and nothing in
# it is actually secret (S3 auth is via the instance's IAM role, and
# SMTP_HOST/PORT are just an endpoint address — see config.env.example).
chmod 644 "$AT_CONFIG_FILE"

if [[ -f "$AT_SMTP_CREDS_FILE" ]]; then
  info "$AT_SMTP_CREDS_FILE already exists — leaving it untouched."
else
  cp "${SCRIPT_DIR}/config/smtp-credentials.env.example" "$AT_SMTP_CREDS_FILE"
  warn "Installed placeholder SMTP credentials → $AT_SMTP_CREDS_FILE — EDIT IT before enabling email:"
  warn "  sudo \${EDITOR:-vi} $AT_SMTP_CREDS_FILE"
fi
chown root:root "$AT_SMTP_CREDS_FILE"
# 600, root-only: this is the one file in the whole toolkit that holds a
# real secret. Only argus-tty-mailer (root, via systemd) ever reads it.
chmod 600 "$AT_SMTP_CREDS_FILE"

# ── Logrotate ────────────────────────────────────────────────────────────────

section "Logrotate"
cp "${SCRIPT_DIR}/logrotate/argus-tty" "$AT_LOGROTATE_CONF"
chown root:root "$AT_LOGROTATE_CONF"
chmod 644 "$AT_LOGROTATE_CONF"
info "Logrotate config → $AT_LOGROTATE_CONF"

# ── Sudoers samples ──────────────────────────────────────────────────────────
# Just seeds the read-only reference copies. lib/reconfigure.sh (called at
# the end of this script, and by `sudo argus-tty reconfigure` any time
# after) decides whether to actually install these or a per-host override
# from /etc/argus-tty/{developer,admin}.sudoers into /etc/sudoers.d/ — see
# sudoers/developer.sudoers.sample's own header for the override mechanism.

section "Sudoers samples (defaults)"
mkdir -p "$(dirname "$AT_DEV_SUDOERS_SAMPLE")"
cp "${SCRIPT_DIR}/sudoers/developer.sudoers.sample" "$AT_DEV_SUDOERS_SAMPLE"
cp "${SCRIPT_DIR}/sudoers/admin.sudoers.sample" "$AT_ADMIN_SUDOERS_SAMPLE"
cp "${SCRIPT_DIR}/sudoers/deployer.sudoers.sample" "$AT_DEPLOYER_SUDOERS_SAMPLE"
chmod 644 "$AT_DEV_SUDOERS_SAMPLE" "$AT_ADMIN_SUDOERS_SAMPLE" "$AT_DEPLOYER_SUDOERS_SAMPLE"
chown root:root "$AT_DEV_SUDOERS_SAMPLE" "$AT_ADMIN_SUDOERS_SAMPLE" "$AT_DEPLOYER_SUDOERS_SAMPLE"
info "Sudoers samples → $AT_DEV_SUDOERS_SAMPLE, $AT_ADMIN_SUDOERS_SAMPLE, $AT_DEPLOYER_SUDOERS_SAMPLE"

# umask profile (/etc/profile.d/developer-restrictions.sh) is NOT copied here
# — lib/reconfigure.sh (called below) generates it directly from the
# resolved tier group names, same idempotent-rewrite treatment as the
# sudoers files and the sshd Match block.

# ── Hand off to the shared idempotent configuration script ─────────────────

"${SCRIPT_DIR}/lib/reconfigure.sh"
