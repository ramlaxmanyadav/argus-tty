#!/bin/bash
# argus-tty-wrapper — session recorder, installed as the sshd ForceCommand
# for the `developer` and `admin` groups (see the "Match Group
# developer,admin" block install.sh writes into sshd_config — admins are
# recorded exactly like developers). sshd invokes this as the authenticated
# user's own uid — it is never handed an argument, so the audited identity
# is read straight from the OS (`id -un`), not from anything the client
# supplied.
#
# Records: full TTY session (.tty), command history (.hist), metadata (.meta)
# under $SESSION_DIR. S3 upload is handed off to argus-tty-finalize as a
# fully detached background process (see _dispatch_s3_upload below) — this
# script itself never talks to AWS or waits on a network call, so a slow or
# unreachable S3 endpoint can never delay login or hold the SSH connection
# open at logout. Email notifications are just queued as a small local file
# under $NOTIFY_DIR (an instant, network-free write) for argus-tty-mailer
# — a separate, root-only, systemd-timer-driven process — to actually send
# over SMTP; this script never sees SMTP credentials and never waits on
# SMTP either. If the finalize helper, `setsid`, aws credentials, or the
# notify dir are missing, all of this degrades to silent no-ops and the
# session recording still happens locally.
#
# Do NOT invoke directly.

set -u

AUDIT_USER="$(id -un)"
SESSION_DIR="/var/log/argus-tty/sessions"
NOTIFY_DIR="/var/log/argus-tty/notify"
FINALIZE_BIN="/usr/sbin/argus-tty-finalize"

# Optional: NO_CAPTURE_COMMAND_PATTERN from config.env — a non-interactive
# `ssh user@host 'command'` matching this ERE skips `script` TTY capture
# (see _is_no_capture_command below). Deliberately does NOT affect .meta,
# the session-start/end notifications, or the `logger` events further
# down — those always fire regardless, so the exact command, who ran it,
# when, and its exit code are still fully on record either way. Sourced
# defensively: config.env missing or unreadable just means no exclusions
# apply, never a login failure.
AT_CONFIG_FILE="/etc/argus-tty/config.env"
# shellcheck disable=SC1091
[[ -r "$AT_CONFIG_FILE" ]] && source "$AT_CONFIG_FILE" 2>/dev/null

mkdir -p "$SESSION_DIR" 2>/dev/null || SESSION_DIR=""

SSH_FROM="${SSH_CLIENT%% *}"
PID=$$
SESSION_ID="$(date '+%Y%m%d-%H%M%S')_${AUDIT_USER}_${PID}"
START_EPOCH="$(date +%s)"
START_TIME="$(date '+%Y-%m-%d %H:%M:%S %Z')"
HOSTNAME_VAL="$(hostname)"
SESSION_TYPE="${SSH_ORIGINAL_COMMAND:+command}"
SESSION_TYPE="${SESSION_TYPE:-interactive}"

TTY_FILE="${SESSION_DIR}/${SESSION_ID}.tty"
META_FILE="${SESSION_DIR}/${SESSION_ID}.meta"
HIST_FILE="${SESSION_DIR}/${SESSION_ID}.hist"

# Write initial metadata
if [[ -n "$SESSION_DIR" ]]; then
  cat > "$META_FILE" <<META
session_id=${SESSION_ID}
audit_user=${AUDIT_USER}
ssh_from=${SSH_FROM:-local}
hostname=${HOSTNAME_VAL}
pid=${PID}
start_time=${START_TIME}
start_epoch=${START_EPOCH}
session_type=${SESSION_TYPE}
ssh_original_command=${SSH_ORIGINAL_COMMAND:-none}
META
  chmod 640 "$META_FILE" 2>/dev/null || true
fi

logger -t argus-tty -p local6.info \
  "EVENT=session_start session_id=${SESSION_ID} user=${AUDIT_USER} ssh_from=${SSH_FROM:-local} type=${SESSION_TYPE} pid=${PID}" &

# ── Hand off S3 upload to the detached finalize helper ─────────────────────
# Fire-and-forget by design: this function never blocks the caller and never
# fails loudly. `setsid` moves the finalizer into its own session so sshd
# closing this session's pty/channel can't SIGHUP it mid-upload; `timeout`
# (when available) puts a hard ceiling on how long an unreachable AWS
# endpoint can linger as an orphan process.

_dispatch_s3_upload() {
  local meta="$1" tty="$2" hist="$3"

  [[ -x "$FINALIZE_BIN" ]] || return 0
  command -v setsid &>/dev/null || return 0

  local runner=(setsid)
  command -v timeout &>/dev/null && runner=(setsid timeout 90)

  env \
    AUDIT_USER="$AUDIT_USER" SESSION_ID="$SESSION_ID" HOSTNAME_VAL="$HOSTNAME_VAL" \
    META_FILE="$meta" TTY_FILE="$tty" HIST_FILE="$hist" \
    "${runner[@]}" "$FINALIZE_BIN" </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

# ── Queue an email notification for argus-tty-mailer ─────────────────────
# Just a local file write into a sticky, world-writable spool dir — no
# network call, so this can run synchronously without ever risking a delay.
# Never fails loudly: a missing notify dir or missing `base64` just means the
# notification is skipped (logged), not that the session breaks.

_queue_notification() {
  local event="$1" subject="$2" body="$3"

  [[ -d "$NOTIFY_DIR" ]] || return 0
  if ! command -v base64 &>/dev/null; then
    logger -t argus-tty -p local6.warn "base64 not found — skipping ${event} notification for session ${SESSION_ID}"
    return 0
  fi

  local subject_b64 body_b64
  subject_b64=$(printf '%s' "$subject" | base64 | tr -d '\n')
  body_b64=$(printf '%s' "$body" | base64 | tr -d '\n')

  {
    echo "event=${event}"
    echo "audit_user=${AUDIT_USER}"
    echo "session_id=${SESSION_ID}"
    echo "hostname=${HOSTNAME_VAL}"
    echo "subject_b64=${subject_b64}"
    echo "body_b64=${body_b64}"
  } > "${NOTIFY_DIR}/${SESSION_ID}.${event}.notify" 2>/dev/null || true
}

# ── Session-start notification (never blocks login) ─────────────────────────

_queue_notification "start" \
  "[Argus TTY] ${AUDIT_USER} CONNECTED on ${HOSTNAME_VAL}" \
  "$(printf 'Shell Session Started\n\nUser       : %s\nSession ID : %s\nSSH From   : %s\nHostname   : %s\nStart Time : %s\nType       : %s\nCommand    : %s' \
    "$AUDIT_USER" "$SESSION_ID" "${SSH_FROM:-local}" "$HOSTNAME_VAL" \
    "$START_TIME" "$SESSION_TYPE" "${SSH_ORIGINAL_COMMAND:-interactive bash}")"

# ── Session-end trap ─────────────────────────────────────────────────────────

# _prettify_hist_timestamps <hist-file> — bash's HISTFILE, when HISTTIMEFORMAT
# is set (it is, see _AUDIT_RC below), stores a raw `#<unix-epoch>` comment
# line before each command — HISTTIMEFORMAT only reformats those for DISPLAY
# when a user runs the interactive `history` builtin, it never changes what's
# actually written to disk. Anyone reviewing the raw .hist file directly
# (cat, S3 download, grep) would otherwise see epoch seconds instead of a
# date. Rewrites those comment lines in place, one time, at session end.
_prettify_hist_timestamps() {
  local hist_file="$1" tmp
  [[ -s "$hist_file" ]] || return 0
  tmp="$(mktemp)" || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^#([0-9]{9,10})$ ]]; then
      local pretty
      pretty="$(date -d "@${BASH_REMATCH[1]}" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null \
        || date -r "${BASH_REMATCH[1]}" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null)"
      printf '#%s\n' "${pretty:-${BASH_REMATCH[1]}}" >> "$tmp"
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$hist_file"
  cat "$tmp" > "$hist_file" 2>/dev/null
  rm -f "$tmp"
}

finish() {
  local exit_code=$?
  local end_epoch end_time duration
  end_epoch="$(date +%s)"
  end_time="$(date '+%Y-%m-%d %H:%M:%S %Z')"
  duration=$(( end_epoch - START_EPOCH ))

  if [[ -n "$SESSION_DIR" ]]; then
    {
      echo "end_time=${end_time}"
      echo "end_epoch=${end_epoch}"
      echo "duration_sec=${duration}"
      echo "exit_code=${exit_code}"
    } >> "$META_FILE" 2>/dev/null || true
    _prettify_hist_timestamps "$HIST_FILE"
    chmod 440 "$TTY_FILE" "$META_FILE" "$HIST_FILE" 2>/dev/null || true
  fi

  logger -t argus-tty -p local6.info \
    "EVENT=session_end session_id=${SESSION_ID} user=${AUDIT_USER} duration=${duration}s exit_code=${exit_code}" &

  _queue_notification "end" \
    "[Argus TTY] ${AUDIT_USER} DISCONNECTED from ${HOSTNAME_VAL}" \
    "$(printf 'Shell Session Ended\n\nUser       : %s\nSession ID : %s\nSSH From   : %s\nHostname   : %s\nStart Time : %s\nEnd Time   : %s\nDuration   : %ss\nExit Code  : %s' \
      "$AUDIT_USER" "$SESSION_ID" "${SSH_FROM:-local}" "$HOSTNAME_VAL" \
      "$START_TIME" "$end_time" "$duration" "$exit_code")"

  _dispatch_s3_upload "$META_FILE" "$TTY_FILE" "$HIST_FILE"

  # No `wait` here, on purpose: the S3 upload hand-off above is fully
  # detached, so this trap returns immediately and sshd closes the
  # connection right away instead of waiting on a network call. The
  # notification above is just a local file write, so it never needed
  # detaching in the first place.
}
trap finish EXIT INT TERM HUP

# ── Build bash init file that injects audit hooks ──────────────────────────
# Sources the user's normal bashrc first so their prompt/aliases are intact,
# then overlays audit-specific HIST settings and PROMPT_COMMAND hook.

_AUDIT_RC=$(mktemp /tmp/.argus-tty-rc.XXXXXX 2>/dev/null) || _AUDIT_RC=""

if [[ -n "$_AUDIT_RC" ]]; then
  cat > "$_AUDIT_RC" <<RCEOF
# Audit rc — sources normal bashrc then adds audit hooks
[[ -f /etc/bash.bashrc ]] && source /etc/bash.bashrc 2>/dev/null
[[ -f ~/.bashrc ]] && source ~/.bashrc 2>/dev/null
# This rc file — not a login shell, and not the usual bash-completion hook
# locations — is the ONLY thing sourced for a forced session, so completion
# scripts relying on /etc/profile.d or the bash-completion package's own
# dynamic loader never fire here unless sourced explicitly. If your own
# deploy tooling ships a bash-completion file, `source` it here the same
# way, guarded by `[[ -f ... ]]` so it's a no-op on hosts that don't have it.
export HISTFILE="${HIST_FILE}"
export HISTTIMEFORMAT="[%F %T] "
export HISTCONTROL=""
export HISTSIZE=100000
export HISTFILESIZE=100000
PROMPT_COMMAND="history -a\${PROMPT_COMMAND:+; \${PROMPT_COMMAND}}"
# Only for an actually-interactive shell (bash --rcfile with no -c, attached
# to a real session) — NEVER for a non-interactive exec channel (bash
# running this rc THEN a specific command, which is exactly how scp/sftp/
# rsync/git-over-ssh connect). Any stray stdout on those breaks their binary
# protocol handshake outright ("Ensure the remote shell produces no output
# for non-interactive sessions" is scp's actual error for this). \$- contains
# 'i' only for a genuinely interactive shell, so this is safe regardless of
# which path sourced this rc file.
[[ \$- == *i* ]] && echo "[argus-tty] Session ${SESSION_ID} — all commands are recorded."
RCEOF
  chmod 400 "$_AUDIT_RC" 2>/dev/null || true
fi

# ── Launch ───────────────────────────────────────────────────────────────────

_launch_with_recording() {
  local cmd="$1"
  if command -v script &>/dev/null && [[ -n "$SESSION_DIR" ]]; then
    script -q -c "$cmd" "$TTY_FILE"
  else
    eval "$cmd"
  fi
}

# _is_protocol_command <original-command> — true for wire-protocol commands
# a CLIENT TOOL issues automatically over the exec channel (scp/rsync/
# git-over-ssh) — never something a human types themselves. ALWAYS skips
# `script` TTY capture, unconditionally, and is NOT affected by
# NO_CAPTURE_COMMAND_PATTERN below (that knob REPLACES _is_no_capture_command
# entirely — fine for a policy choice like log-tailing, but this isn't one:
# `script` PTY-wraps whatever it runs, and PTYs do line-discipline
# processing a raw pipe doesn't. Wrapping a binary protocol in one risks
# corrupting it outright — scp's own error for exactly this is "Ensure the
# remote shell produces no output for non-interactive sessions" — not just
# growing the .tty file. .meta/.hist/logger events still fully audit these
# regardless; only the raw byte capture is skipped.
_is_protocol_command() {
  [[ "$1" =~ ^(scp|rsync|git-upload-pack|git-receive-pack|git-upload-archive)([[:space:]]|$) ]]
}

# _is_no_capture_command <original-command> — true if this command should
# skip `script` TTY capture for POLICY reasons (e.g. a long-running log-tail
# subcommand from your own deploy tooling, whose live-streamed byte-for-byte
# output isn't meaningful to store and would otherwise grow the .tty file
# unbounded for as long as the connection stays open). No built-in default —
# every command gets full capture unless NO_CAPTURE_COMMAND_PATTERN in
# config.env opts one in. Deliberately conservative either way: a false
# negative (something that could have skipped capture but didn't) just means
# the normal, safe, fully-recorded behavior; only a false positive would
# actually reduce the audit trail, so keep whatever pattern you set narrow.
_is_no_capture_command() {
  return 1
}
if [[ -n "${NO_CAPTURE_COMMAND_PATTERN:-}" ]]; then
  _is_no_capture_command() {
    [[ "$1" =~ $NO_CAPTURE_COMMAND_PATTERN ]]
  }
fi

# _is_lite_recording_user — true if AUDIT_USER is in LITE_RECORDING_USERS
# (config.env, space-separated, exact match). Same audit guarantee as
# _is_no_capture_command's exclusions: only the byte-for-byte .tty
# transcript is skipped — .hist, .meta, session-start/end notifications,
# and the `logger` events all fire completely unchanged for this user.
_is_lite_recording_user() {
  local u="$1" listed
  for listed in ${LITE_RECORDING_USERS:-}; do
    [[ "$u" == "$listed" ]] && return 0
  done
  return 1
}
SKIP_TTY_CAPTURE=false
_is_lite_recording_user "$AUDIT_USER" && SKIP_TTY_CAPTURE=true

if [[ -n "${SSH_ORIGINAL_COMMAND:-}" ]]; then
  # Non-interactive: user ran "ssh dev1@host 'some command'"
  # Write to a temp file to safely handle any quoting in the original command.
  _CMD_FILE=$(mktemp /tmp/.argus-tty-cmd.XXXXXX 2>/dev/null) || _CMD_FILE=""
  if [[ -n "$_CMD_FILE" && -n "$_AUDIT_RC" ]]; then
    printf '#!/bin/bash\nsource %q\n%s\n' "$_AUDIT_RC" "$SSH_ORIGINAL_COMMAND" > "$_CMD_FILE"
    chmod +x "$_CMD_FILE"
    if $SKIP_TTY_CAPTURE || _is_protocol_command "$SSH_ORIGINAL_COMMAND" || _is_no_capture_command "$SSH_ORIGINAL_COMMAND"; then
      # Still fully audited otherwise: .meta already has the exact command,
      # timestamps, and (once finish() runs) the exit code; session-start/
      # end notifications and `logger` events below fire unchanged. Only
      # the byte-for-byte .tty transcript is skipped.
      [[ -n "$SESSION_DIR" ]] && echo "[argus-tty] TTY capture skipped for this command (see .meta for the audit record)" > "$TTY_FILE" 2>/dev/null
      bash "$_CMD_FILE"
      _ec=$?
    else
      _launch_with_recording "bash '$_CMD_FILE'"
      _ec=$?
    fi
    rm -f "$_CMD_FILE" "$_AUDIT_RC"
    exit $_ec
  else
    # Fallback if mktemp failed
    bash -c "$SSH_ORIGINAL_COMMAND"
    exit $?
  fi
else
  # Interactive shell
  if [[ -n "$_AUDIT_RC" ]]; then
    if $SKIP_TTY_CAPTURE; then
      [[ -n "$SESSION_DIR" ]] && echo "[argus-tty] TTY capture skipped for this user (see .meta/.hist for the audit record)" > "$TTY_FILE" 2>/dev/null
      bash --rcfile "$_AUDIT_RC"
      _ec=$?
    else
      _launch_with_recording "bash --rcfile '$_AUDIT_RC'"
      _ec=$?
    fi
    rm -f "$_AUDIT_RC"
    exit $_ec
  else
    _launch_with_recording "bash --login"
  fi
fi
