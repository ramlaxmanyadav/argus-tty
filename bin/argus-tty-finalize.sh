#!/bin/bash
# argus-tty-finalize — detached S3 upload helper.
#
# Installed to /usr/sbin/argus-tty-finalize. Invoked by
# argus-tty-wrapper via `setsid` (and `timeout` where available) so it runs
# in a session of its own, fully detached from the SSH channel — a slow or
# unreachable S3 endpoint here can never delay a developer's login or hold
# their connection open at logout. It reads session details from the
# environment (set by the wrapper) rather than argv:
#   AUDIT_USER, SESSION_ID, HOSTNAME_VAL, META_FILE, TTY_FILE, HIST_FILE
#
# Email notifications are NOT handled here — they go through
# argus-tty-mailer instead (a separate, root-only, systemd-timer-driven
# process), because SMTP needs real credentials that a developer-owned
# process must never be able to read. This helper only ever needs the
# instance's IAM role, so it's fine to run as the connecting developer's uid.
#
# Every failure mode degrades gracefully: if the aws CLI isn't installed, or
# no credentials/IAM role can be resolved, this exits quietly after a syslog
# note — it never uploads and never errors loudly. Session files are left in
# place under $SESSION_DIR when that happens, so nothing is lost; a later
# run (e.g. after aws is installed) can pick them up manually with
# `aws s3 cp`.
#
# Do NOT invoke directly.

set -u

CONFIG_FILE="/etc/argus-tty/config.env"
# Default true (not false) so a config.env from before S3_UPLOAD_ENABLED
# existed (preserved as-is across upgrades — it's a dpkg conffile) keeps its
# old behavior of "upload whenever S3_BUCKET is set", instead of silently
# going quiet. Fresh installs ship config.env.example with this explicitly
# set to false, matching EMAIL_ENABLED's opt-in default.
S3_UPLOAD_ENABLED="true"
S3_BUCKET=""
S3_PREFIX="argus-tty"
AWS_REGION="us-east-1"
# shellcheck disable=SC1090
[[ -r "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

AUDIT_USER="${AUDIT_USER:-unknown}"
SESSION_ID="${SESSION_ID:-unknown}"
HOSTNAME_VAL="${HOSTNAME_VAL:-$(hostname)}"
META_FILE="${META_FILE:-}"
TTY_FILE="${TTY_FILE:-}"
HIST_FILE="${HIST_FILE:-}"

# Bound IMDS/credential-resolution latency so "no role, no network" fails in
# ~1s instead of the default multi-second retry/backoff.
export AWS_METADATA_SERVICE_TIMEOUT=1
export AWS_METADATA_SERVICE_NUM_ATTEMPTS=1

_with_timeout() {
  if command -v timeout &>/dev/null; then
    timeout "$@"
  elif command -v gtimeout &>/dev/null; then
    gtimeout "$@"
  else
    local _secs="$1"; shift
    "$@"
  fi
}

# _aws_ready — cheap, bounded check that the CLI is present AND some
# credential provider (instance role, env vars, ~/.aws/credentials, ...)
# actually resolves. Checked once; gates every upload below so we never even
# attempt a doomed network call.
_aws_ready() {
  command -v aws &>/dev/null || return 1
  _with_timeout 3 aws sts get-caller-identity --region "$AWS_REGION" &>/dev/null
}

upload_to_s3() {
  local file="$1"
  [[ -n "$file" && -f "$file" && -s "$file" ]] || return 0
  [[ -n "$S3_BUCKET" ]] || return 0
  if _with_timeout 30 aws s3 cp "$file" \
    "s3://${S3_BUCKET}/${S3_PREFIX}/${HOSTNAME_VAL}/${AUDIT_USER}/${SESSION_ID}/$(basename "$file")" \
    --region "$AWS_REGION" --quiet 2>/dev/null; then
    rm -f "$file"
  else
    logger -t argus-tty -p local6.warn "S3 upload failed: $file"
  fi
}

if [[ "$S3_UPLOAD_ENABLED" != "true" ]]; then
  logger -t argus-tty -p local6.info \
    "S3 upload disabled (S3_UPLOAD_ENABLED=false) — skipping for session ${SESSION_ID} (files left under \$SESSION_DIR)"
  exit 0
fi

if ! _aws_ready; then
  logger -t argus-tty -p local6.warn \
    "aws CLI missing or no usable credentials — skipping S3 upload for session ${SESSION_ID} (files left under \$SESSION_DIR)"
  exit 0
fi

upload_to_s3 "$META_FILE"
upload_to_s3 "$TTY_FILE"
upload_to_s3 "$HIST_FILE"
