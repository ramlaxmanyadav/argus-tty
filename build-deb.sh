#!/bin/bash
# build-deb.sh — assemble argus-tty's FHS-correct file layout and build a
# real, installable .deb package with dpkg-deb.
#
# Run this after editing any source file (bin/, lib/, config/, sudoers/,
# logrotate/, systemd/, packaging/DEBIAN/) to produce an updated package.
# Requires dpkg-deb (macOS: `brew install dpkg`; Ubuntu/Debian: already
# present, or `apt-get install dpkg-dev`).
#
# Rails app deployment is out of scope for this package — it provisions
# developer/admin/deployer accounts, sudo whitelists, and a shared
# `webapps`/`rvm` group scaffolding for whatever deploy tooling you layer
# on top, but doesn't install or require any specific one itself.
#
# Usage: ./build-deb.sh
# Output: dist/argus-tty_<version>_all.deb

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

command -v dpkg-deb &>/dev/null || {
  echo "[ERROR] dpkg-deb not found." >&2
  echo "  macOS:  brew install dpkg" >&2
  echo "  Ubuntu: sudo apt-get install dpkg-dev" >&2
  exit 1
}

VERSION="$(tr -d '[:space:]' < VERSION)"
[[ -n "$VERSION" ]] || { echo "[ERROR] VERSION file is empty." >&2; exit 1; }

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

echo "==> Building argus-tty ${VERSION} in ${STAGING}"

# ── Directory skeleton ──────────────────────────────────────────────────────

install -d -m 755 \
  "${STAGING}/DEBIAN" \
  "${STAGING}/usr/bin" \
  "${STAGING}/usr/sbin" \
  "${STAGING}/usr/lib/argus-tty/bin" \
  "${STAGING}/usr/lib/argus-tty/lib" \
  "${STAGING}/usr/lib/systemd/system" \
  "${STAGING}/usr/share/argus-tty" \
  "${STAGING}/usr/share/doc/argus-tty" \
  "${STAGING}/etc/argus-tty" \
  "${STAGING}/etc/logrotate.d"

# ── CLI entrypoint ───────────────────────────────────────────────────────────

install -m 755 argus-tty "${STAGING}/usr/bin/argus-tty"

# ── Standalone binaries (referenced by absolute path from sshd_config /
#    systemd units, so they must land at exactly these paths) ──────────────

install -m 755 bin/argus-tty-wrapper.sh  "${STAGING}/usr/sbin/argus-tty-wrapper"
install -m 755 bin/argus-tty-finalize.sh "${STAGING}/usr/sbin/argus-tty-finalize"
install -m 700 bin/argus-tty-mailer.sh   "${STAGING}/usr/sbin/argus-tty-mailer"

# ── systemd units (vendor location — NOT /etc/systemd/system) ──────────────

install -m 644 systemd/argus-tty-mailer.service "${STAGING}/usr/lib/systemd/system/"
install -m 644 systemd/argus-tty-mailer.timer   "${STAGING}/usr/lib/systemd/system/"

# ── CLI helper scripts + shared lib (same bin/../lib relative layout as the
#    loose checkout, so they need zero code changes to work packaged) ──────

for f in add-developer.sh bulk-add-developers.sh remove-developer.sh list-developers.sh \
         add-admin.sh bulk-add-admins.sh remove-admin.sh list-admins.sh \
         add-deployer.sh bulk-add-deployers.sh remove-deployer.sh list-deployers.sh \
         allow-ip.sh clear-ip.sh list-ip.sh export-users.sh import-users.sh status.sh; do
  install -m 755 "bin/${f}" "${STAGING}/usr/lib/argus-tty/bin/${f}"
done
install -m 644 lib/common.sh       "${STAGING}/usr/lib/argus-tty/lib/common.sh"
install -m 755 lib/reconfigure.sh  "${STAGING}/usr/lib/argus-tty/lib/reconfigure.sh"

# ── Config conffiles (shipped with real default content — dpkg preserves
#    local edits across upgrades and prompts on conflicts, same as any
#    other package's /etc files) ─────────────────────────────────────────────

install -m 644 config/config.env.example          "${STAGING}/etc/argus-tty/config.env"
install -m 600 config/smtp-credentials.env.example "${STAGING}/etc/argus-tty/smtp-credentials.env"
install -m 644 logrotate/argus-tty               "${STAGING}/etc/logrotate.d/argus-tty"
# /etc/profile.d/developer-restrictions.sh is NOT shipped here — postinst's
# call into lib/reconfigure.sh generates it directly from the resolved tier
# group names on every install/upgrade (see reconfigure.sh's "Profile:
# umask" section).

# ── Sudoers samples — read-only reference; lib/reconfigure.sh (via postinst,
#    or `sudo argus-tty reconfigure`) is what actually installs
#    /etc/sudoers.d/{developer,admin,deployer}, from these or a per-host
#    override at /etc/argus-tty/{developer,admin,deployer}.sudoers. NOT
#    shipped directly as /etc/sudoers.d/* conffiles — reconfigure.sh
#    re-derives those on every run, which would fight with dpkg's own
#    conffile-preservation semantics if we shipped them there too. ─────────

install -m 644 sudoers/developer.sudoers.sample "${STAGING}/usr/share/argus-tty/developer.sudoers.sample"
install -m 644 sudoers/admin.sudoers.sample     "${STAGING}/usr/share/argus-tty/admin.sudoers.sample"
install -m 644 sudoers/deployer.sudoers.sample  "${STAGING}/usr/share/argus-tty/deployer.sudoers.sample"

# ── Docs ─────────────────────────────────────────────────────────────────────

install -m 644 developer_users.conf.example        "${STAGING}/usr/share/doc/argus-tty/"
install -m 644 README.md                           "${STAGING}/usr/share/doc/argus-tty/"

# ── DEBIAN control area ──────────────────────────────────────────────────────

sed "s/__VERSION__/${VERSION}/" packaging/DEBIAN/control > "${STAGING}/DEBIAN/control"
install -m 644 packaging/DEBIAN/conffiles "${STAGING}/DEBIAN/conffiles"
for script in preinst postinst prerm postrm; do
  install -m 755 "packaging/DEBIAN/${script}" "${STAGING}/DEBIAN/${script}"
done

# ── Build ────────────────────────────────────────────────────────────────────

mkdir -p dist
OUT="dist/argus-tty_${VERSION}_all.deb"
dpkg-deb --build --root-owner-group "$STAGING" "$OUT"

echo ""
echo "==> Built ${OUT}"
dpkg-deb --info "$OUT"
