#!/bin/bash
# argus-tty-mailer — root-only SMTP sender for argus-tty notifications.
#
# Runs periodically via the argus-tty-mailer.timer systemd unit (every 30s)
# — it is NEVER invoked by a developer session directly. It drains
# /var/log/argus-tty/notify/ for pending session start/end notifications
# queued by argus-tty-wrapper and sends each over SMTP via curl.
#
# This is the ONLY place SMTP credentials are ever read (from
# /etc/argus-tty/smtp-credentials.env, root:root 600) — a developer-owned
# process can queue a notification file, but it can never see SMTP_USER or
# SMTP_PASS, because it never runs as root and never reads that file.
#
# Every failure mode degrades gracefully and never touches a live SSH
# session: if curl is missing, SMTP is unreachable, or credentials are wrong,
# a notification is retried on the next few timer ticks (up to MAX_ATTEMPTS)
# and then moved to notify/failed/ with a syslog warning — it is never lost
# silently, and it never blocks anything, since this process is fully
# decoupled from SSH.
#
# Do NOT invoke directly.

set -u

CONFIG_FILE="/etc/argus-tty/config.env"
CREDS_FILE="/etc/argus-tty/smtp-credentials.env"
NOTIFY_DIR="/var/log/argus-tty/notify"
MAX_ATTEMPTS=5

EMAIL_ENABLED="false"
EMAIL_TO=""
EMAIL_FROM=""
SMTP_HOST=""
SMTP_PORT="587"
SMTP_USER=""
SMTP_PASS=""

# shellcheck disable=SC1090
[[ -r "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
# shellcheck disable=SC1090
[[ -r "$CREDS_FILE" ]] && source "$CREDS_FILE"

[[ "$EMAIL_ENABLED" == "true" ]] || exit 0

mkdir -p "$NOTIFY_DIR/failed" 2>/dev/null || true

_with_timeout() {
  if command -v timeout &>/dev/null; then
    timeout "$@"
  else
    local _secs="$1"; shift
    "$@"
  fi
}

_send_one() {
  local file="$1"
  local subject_b64 body_b64 subject body

  subject_b64=$(grep -m1 '^subject_b64=' "$file" | cut -d= -f2-)
  body_b64=$(grep -m1 '^body_b64=' "$file" | cut -d= -f2-)
  subject=$(printf '%s' "$subject_b64" | base64 -d 2>/dev/null)
  body=$(printf '%s' "$body_b64" | base64 -d 2>/dev/null)
  [[ -n "$subject" ]] || subject="[Argus TTY] notification"

  command -v curl &>/dev/null || { logger -t argus-tty -p local6.warn "curl not found — cannot send SMTP email"; return 1; }
  [[ -n "$EMAIL_TO" && -n "$EMAIL_FROM" && -n "$SMTP_HOST" ]] \
    || { logger -t argus-tty -p local6.warn "SMTP not fully configured — skipping $(basename "$file")"; return 1; }

  local curl_args=(
    --silent --show-error --ssl-reqd
    --url "smtp://${SMTP_HOST}:${SMTP_PORT}"
    --mail-from "$EMAIL_FROM"
    --mail-rcpt "$EMAIL_TO"
    --upload-file -
  )
  [[ -n "$SMTP_USER" ]] && curl_args+=(--user "${SMTP_USER}:${SMTP_PASS}")

  _with_timeout 15 curl "${curl_args[@]}" <<EOF
From: $EMAIL_FROM
To: $EMAIL_TO
Subject: $subject

$body
EOF
}

shopt -s nullglob
for f in "$NOTIFY_DIR"/*.notify "$NOTIFY_DIR"/*.notify.attempt*; do
  [[ -f "$f" ]] || continue

  if _send_one "$f" >/dev/null 2>&1; then
    rm -f "$f"
    continue
  fi

  attempt=1
  if [[ "$f" =~ \.attempt([0-9]+)$ ]]; then
    attempt="${BASH_REMATCH[1]}"
  fi
  next=$((attempt + 1))

  base="${f%.attempt*}"
  if [[ "$next" -gt "$MAX_ATTEMPTS" ]]; then
    mv -f "$f" "${NOTIFY_DIR}/failed/$(basename "$base").failed" 2>/dev/null || true
    logger -t argus-tty -p local6.warn "Giving up on notification after $MAX_ATTEMPTS attempts: $(basename "$base")"
  else
    mv -f "$f" "${base}.attempt${next}" 2>/dev/null || true
  fi
done
