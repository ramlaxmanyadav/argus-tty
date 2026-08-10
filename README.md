# Argus TTY

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

One package to find-or-create a developer's (or admin's) Linux account,
provision their SSH key, force every session through a TTY recorder, and
ship the logs to S3 — with an email ping on connect/disconnect. Ships as a
real, installable/upgradable/removable `.deb` package, so rolling it out to
a fleet is `apt install`, not `scp -r` and hope.

Open source under the [MIT license](LICENSE) — see
[PACKAGING.md](PACKAGING.md) if you want to build and publish your own
Launchpad PPA build of this project.

## Who this is for

You're provisioning SSH access for a team onto one or more Ubuntu/Debian
boxes and need an audit trail — every keystroke, every command, who ran it,
when — without hand-rolling `sshd_config` + PAM + a TTY recorder yourself,
and without resorting to a single shared root/deploy account that nobody
can attribute actions to individually. Typical users:

- **SREs/DevOps engineers** standing up SSH access for a small-to-mid-size
  engineering team across a fleet of VMs, who want `apt install` + a config
  file, not a bespoke Ansible role.
- **Security/compliance-minded teams** who need to answer "who ran what,
  when, and what did the session actually contain" after the fact — session
  recordings ship to S3, and every action is logged via `logger -t
  argus-tty` for ingestion into your existing log pipeline.

It assumes comfort with basic Linux administration (users/groups, SSH,
sudoers, systemd) — it automates the wiring, but you're still the one
deciding who gets which tier of access.

## How it works

- Every account is a **real Linux account** (not a shared one), in one of
  three tiers:
  - **`developer`** — scoped sudo via a *whitelist* (only specific
    service/package/process/docker commands are allowed as root).
    `sudo su`, `sudo -s`, `sudo bash` are all blocked because they're simply
    not on the list, and PAM blocks direct `su` outright for anyone not in
    the `sudo` group.
  - **`admin`** — full, unrestricted `sudo` (equivalent to what the default
    `ubuntu` cloud-init user gets out of the box), and also added to the
    `sudo` group so direct `su` works too. This is a fully trusted tier —
    onboard sparingly.
  - **`deployer`** — the narrowest tier: a *whitelist* even tighter than
    developer's, scoped to starting/stopping/restarting services only — no
    console, rake, install, setup, `apt-get`, or `docker`. If your own
    deploy tooling needs a finer-grained restriction on top of that (e.g.
    "only a deploy subcommand, not console/rake"), that's enforced by that
    tooling's own role checks, not by this whitelist. Same PAM `su` block as
    developer (not in the `sudo` group).
- **Admins and deployers are recorded exactly like developers.** More (or
  less) privilege doesn't mean less audit trail: the sshd `Match Group
  developer,admin,deployer` block forces every session from any of the
  three tiers through `argus-tty-wrapper`, which records the full TTY
  (`script`) and command history under `/var/log/argus-tty/sessions/`.
- `ForceCommand` inside an sshd `Match` block always wins over anything a
  user puts in their own `~/.ssh/authorized_keys`, so there's no way to SSH
  in and skip recording — not even for admins.
- Uploading session files to S3 is handed off to a second helper,
  `argus-tty-finalize`, which authenticates via the instance's IAM role —
  no access keys on disk. Email notifications go through a **third,
  privilege-separated helper**, `argus-tty-mailer`: `argus-tty-wrapper`
  just queues a small local file describing the notification (an instant,
  network-free write), and `argus-tty-mailer` — root-only, driven by a
  systemd timer every 30s — is the only process that ever reads the actual
  SMTP username/password and sends the email. A developer- or admin-owned
  process can never read SMTP credentials, because it never runs as root
  and never has access to that file.
- **Every network call is optional and non-blocking.** `argus-tty-wrapper`
  itself never talks to AWS or SMTP — S3 upload runs in `argus-tty-finalize`
  fully detached via `setsid` (+`timeout` as a hard ceiling), and email is
  just a local file write picked up later by the mailer's timer. If the aws
  CLI isn't installed, no credentials/IAM role resolve, or SMTP is
  unreachable/misconfigured, each helper detects that up front and skips its
  job, logging a warning via `logger -t argus-tty` instead of erroring —
  none of this ever delays login or holds a session's connection open at
  logout. Session recording to local disk always happens regardless.
- **Both integrations have an explicit master on/off switch, and both
  default off.** `EMAIL_ENABLED` and `S3_UPLOAD_ENABLED` in `config.env` (see
  [Configuration reference](#configuration-reference)) aren't just advisory
  flags — `EMAIL_ENABLED=true` is what makes `argus-tty reconfigure` run
  `systemctl enable --now argus-tty-mailer.timer`; leave it `false` and the
  timer is actively disabled, so the mailer never even attempts an SMTP
  connection. `S3_UPLOAD_ENABLED` gates the equivalent logic inside
  `argus-tty-finalize` (S3 upload is a per-session helper invocation, not a
  long-running daemon, so there's no systemd unit for it to enable/disable —
  the flag gates the upload attempt itself instead). Turn either on only
  once you've actually filled in its config section.

## Installing

### Option A — the `.deb` package (recommended)

```bash
scp dist/argus-tty_1.0.0_all.deb root@host:/tmp/
ssh root@host
sudo apt install /tmp/argus-tty_1.0.0_all.deb   # pulls openssh-server/sudo/curl/etc. if missing
```

That's it — `apt install` unpacks every file to its canonical location and
automatically runs the same configuration `install.sh` used to run by hand:
creates the `developer`/`admin` groups, locks down the three installed
binaries, wires up PAM/sudoers/the sshd `Match` block, and enables/disables
the mailer timer to match `EMAIL_ENABLED` (`false` by default — see
[Configuration reference](#configuration-reference)). At the end it prints:

```bash
sudo vi /etc/argus-tty/config.env            # S3_BUCKET, AWS_REGION, EMAIL_TO/FROM, SMTP_HOST/PORT
sudo vi /etc/argus-tty/smtp-credentials.env  # SMTP_USER/SMTP_PASS — the only real secret in this toolkit (600, root-only)
sudo argus-tty reconfigure                   # re-applies config + re-validates sshd/sudoers/systemd after edits
sudo argus-tty status                        # confirm everything is green
```

**Upgrading**: `sudo apt install ./argus-tty_<newer>_all.deb` — dpkg
preserves your edits to `config.env`/`smtp-credentials.env` (they're real
conffiles) and prompts you if it can't cleanly merge a change. Sudoers
permissions aren't dpkg conffiles — see "Customizing sudo permissions" below
for how those persist across upgrades instead.

**Removing**: `sudo apt remove argus-tty` stops the mailer, removes the sshd
`Match` block (so developer/admin/deployer accounts keep working over plain,
unrecorded SSH instead of breaking outright), and removes
`/etc/sudoers.d/{developer,admin}` (no audit trail left behind means no
un-audited sudo access left behind either) — conffiles (`config.env`,
`smtp-credentials.env`) are kept in case you reinstall. `sudo apt purge
argus-tty` additionally deletes `/etc/argus-tty/` (including any sudoers
override you created). Neither ever touches: onboarded Linux accounts and
home directories, `/var/log/argus-tty/{sessions,notify}` (the audit
trail), or `/root/argus-tty-developer-keys/` (generated private keys) —
those are yours to clean up deliberately, not as a side effect of
uninstalling a package.

### Option B — Launchpad PPA (Ubuntu)

```bash
sudo add-apt-repository ppa:yadavramlaxman/argus-tty
sudo apt update
sudo apt install argus-tty
```

Same package as Option A, just distributed through Ubuntu's normal
`apt`/PPA mechanism instead of a hand-copied `.deb` file — upgrades arrive
via your regular `apt upgrade`. See [PACKAGING.md](PACKAGING.md) if you want
to build and publish your own PPA from this source instead of using the one
above.

### Option C — manual, no `.deb` (e.g. air-gapped box without dpkg)

```bash
sudo cp -r /path/to/user_audit /root/argus-tty
sudo chmod 700 /root/argus-tty
cd /root/argus-tty
sudo ./install.sh
```

Functionally identical to Option A (same underlying `lib/reconfigure.sh`
runs either way) — you're just responsible for copying files and re-running
`./install.sh` yourself instead of `apt` doing it. Safe to re-run any time.

### Building the package yourself

```bash
./build-deb.sh          # requires dpkg-deb (macOS: brew install dpkg; Ubuntu: apt-get install dpkg-dev)
# -> dist/argus-tty_<version>_all.deb
```

Re-run this after editing anything under `bin/`, `lib/`, `config/`,
`sudoers/`, `profile.d/`, `logrotate/`, `systemd/`, or `packaging/DEBIAN/` —
`build-deb.sh` assembles the FHS-correct file tree from those sources and
calls `dpkg-deb --build --root-owner-group`, so it doesn't need to run as
root even though the resulting package's files are all owned by root:root.
This produces a ready-to-`apt install` binary `.deb`, but it is **not** what
gets uploaded to Launchpad — Option B's PPA is built from the `debian/`
source package instead. See [PACKAGING.md](PACKAGING.md) for the
build-and-`dput` workflow if you want to publish your own PPA build of this
project.

Bump `VERSION` before rebuilding if you want upgrades to be recognized by
dpkg as newer.

## Onboarding developers (the "one click" step)

```bash
# One developer, key from a file:
sudo argus-tty add dev1 --name "Alice Kumar" --pubkey dev1_id_ed25519.pub

# One developer, paste the key on stdin:
cat dev1_id_ed25519.pub | sudo argus-tty add dev1 --name "Alice Kumar" --pubkey -

# No key provided — a PEM keypair is generated FOR them automatically:
sudo argus-tty add dev2 --name "Bob Singh"
#   [INFO] Generated a new PEM keypair for 'dev2'.
#   [WARN] Private key stored at: /root/argus-tty-developer-keys/dev2.pem (root-only, 600)
#   [WARN] Share it with the developer over a secure channel, e.g.:
#   [WARN]   scp /root/argus-tty-developer-keys/dev2.pem yourlaptop:~/Downloads/dev2.pem
#   [WARN] Then have them connect with:
#   [WARN]   chmod 600 dev2.pem && ssh -i dev2.pem dev2@<host>
#   [WARN] Once handed off, consider removing the copy on this server:
#   [WARN]   sudo shred -u /root/argus-tty-developer-keys/dev2.pem

# Same, but also print the private key straight to the terminal (e.g. to
# copy-paste into a password manager instead of scp'ing it off):
sudo argus-tty add dev2 --print-key

# Explicitly skip key provisioning (add one later with --pubkey):
sudo argus-tty add dev3 --no-key

# Many developers at once — entries with no third field get a key generated
# automatically, same as above:
cp /usr/share/doc/argus-tty/developer_users.conf.example developer_users.conf   # then edit
sudo argus-tty bulk-add developer_users.conf
```

`add` is idempotent — re-running it for an existing username just ensures
group membership and installs whatever key you passed; it never errors out,
duplicates the account, or overwrites a key that's already there (including
a previously generated `.pem`).

## Onboarding admins (full sudo, still recorded)

Every developer command has a mirrored admin one — same flags, same
behavior, just a different group and full sudo instead of the whitelist:

```bash
sudo argus-tty add-admin admin1 --name "Carol Diaz" --pubkey admin1_id_ed25519.pub
sudo argus-tty add-admin admin2 --name "Dan Osei"        # no key -> PEM auto-generated, same as 'add'
sudo argus-tty bulk-add-admins admin_users.conf         # same roster format — cp developer_users.conf.example admin_users.conf
sudo argus-tty list-admins
sudo argus-tty remove-admin admin2 --purge-home
```

Admins get `sudo` with no command restriction (`sudo su`, `sudo -i`, `sudo
bash` all work) — this is meant for a small, trusted set of people. Their
sessions are recorded through the exact same pipeline as developers', so
granting this tier doesn't create a blind spot.

## Onboarding deployers (deploy/restart only, still recorded)

The narrowest tier — same commands, same flags as `add`/`add-admin` again,
just a different group and a much tighter sudo whitelist:

```bash
sudo argus-tty add-deployer deploy1 --name "Eve Ortega" --pubkey deploy1_id_ed25519.pub
sudo argus-tty add-deployer deploy2 --name "Frank Musa"    # no key -> PEM auto-generated, same as 'add'
sudo argus-tty bulk-add-deployers deployer_users.conf     # same roster format — cp developer_users.conf.example deployer_users.conf
sudo argus-tty list-deployers
sudo argus-tty remove-deployer deploy2 --purge-home
```

Deployers get `sudo` for starting/stopping/restarting services only (see
[`sudoers/deployer.sudoers.sample`](sudoers/deployer.sudoers.sample)) — no
console, rake, install, setup, `apt-get`, or `docker`, and none of the
broader whitelist developers get. That's the full extent of what argus-tty
itself enforces for this tier; if your own deploy tooling needs a
finer-grained restriction on top (e.g. "only a deploy subcommand, not
console/rake"), extend the whitelist via the override mechanism (see
"Customizing sudo permissions" below) for whatever additional commands that
tooling needs, and enforce the finer-grained part in the tooling's own role
checks. Their sessions are recorded through the exact same pipeline as
developers'/admins', so the narrower privilege still comes with the full
audit trail. Deployers are also always exempt from Google Authenticator 2FA
(see the next section) — the tier is deliberately scoped down to
scripted/CI-style deploy actions, not step-up-auth territory.

All three tiers are also added to the `webapps` group (and `rvm`, if
installed) automatically — scaffolding for whatever app-deployment tooling
you layer on top of these accounts (this toolkit doesn't install or require
any specific one itself).

## Two-factor authentication (Google Authenticator)

Beyond the SSH key, you can require a Google Authenticator (TOTP) code for
developer and admin sessions — a second factor on top of `publickey`, not a
replacement for it. Off by default; turn it on with:

```bash
sudo vi /etc/argus-tty/config.env   # GOOGLE_2FA_ENABLED=true
sudo argus-tty reconfigure
```

`reconfigure` installs `libpam-google-authenticator` if it isn't already,
wires `AuthenticationMethods publickey,keyboard-interactive` into the sshd
`Match` block, and adds a managed `auth required pam_google_authenticator.so`
line to `/etc/pam.d/sshd`. There's no `nullok` fallback — a developer/admin
account with no TOTP secret enrolled simply cannot complete login once this
is on, so:

- **New accounts** get a secret auto-generated and printed once by `argus-tty
  add`/`add-admin` at onboarding time — same hand-off pattern as the
  auto-generated PEM key, just further down the same command's output:

  ```
  ── BEGIN dev1 TOTP enrollment (copy everything below until END) ──
  <QR code + secret key + emergency scratch codes>
  ── END dev1 TOTP enrollment ──
  ```

  Have the developer scan the QR code (or type the secret manually) into
  Google Authenticator, Authy, or 1Password, and keep the scratch codes
  somewhere safe — each is single-use if they lose their device. Re-running
  `add`/`add-admin` for an account that's already enrolled leaves its secret
  untouched; it's not regenerated on every re-run, same as the SSH key.

- **Existing accounts** are NOT retroactively enrolled just by flipping the
  flag — re-run `sudo argus-tty add <username>` (or `add-admin`) for each one
  *before* their next login, or they'll be locked out. `sudo argus-tty
  status` reports how many developer/admin accounts still have no TOTP
  secret, so you can catch this before anyone gets locked out.

- **Resetting a lost secret**: `sudo rm /home/<username>/.google_authenticator`,
  then re-run `argus-tty add <username>` (or `add-admin`) to generate a fresh
  one — same manual-delete-then-rerun pattern as regenerating a lost SSH key,
  no separate flag needed.

**Deployer accounts are exempt**, always — the narrowest, deploy-only tier
doesn't get a TOTP secret and is never prompted for one, regardless of this
setting. So is every username listed in `LITE_RECORDING_USERS` (default:
`ubuntu`): those are pre-existing, out-of-band accounts that never go
through `argus-tty add`'s onboarding pipeline, so they'd never get a secret
provisioned — subjecting them to a mandatory OTP prompt would just lock them
out the moment this flag flips on, not add security. Both exemptions are
enforced with `pam_succeed_if` inside the same PAM stack, not by skipping the
keyboard-interactive step at the sshd level — a deployer/`ubuntu` session
still passes through it, it just succeeds instantly with no prompt.

One side effect worth knowing: turning this on disables `@include
common-auth` in `/etc/pam.d/sshd` (commented out, not deleted — `reconfigure`
restores it automatically if you set `GOOGLE_2FA_ENABLED=false` again). This
is necessary because every account this toolkit onboards has its password
locked (`passwd -l`) — leaving `pam_unix` active in the same stack would make
the keyboard-interactive phase fail outright for all of them via
`pam_deny`. If anything else on this box relies on `@include common-auth`
for SSH password login, account for that before enabling 2FA.

## Customizing sudo permissions

The developer whitelist (`systemctl`/`apt-get`/`kill`/`docker`, see [How it
works](#how-it-works)) and the admin full-sudo grant are both just the
shipped *defaults* — override either per host without touching this repo or
losing your changes on upgrade:

```bash
sudo cp /usr/share/argus-tty/developer.sudoers.sample /etc/argus-tty/developer.sudoers
sudo vi /etc/argus-tty/developer.sudoers    # add/remove/restrict whatever you need
sudo argus-tty reconfigure
```

Same pattern for `/etc/argus-tty/admin.sudoers`. `reconfigure` checks for
these override files on **every run**: if `/etc/argus-tty/developer.sudoers`
exists, it's validated with `visudo -c` and installed into
`/etc/sudoers.d/developer` instead of the shipped default; if it doesn't,
the shipped default (`/usr/share/argus-tty/developer.sudoers.sample`) is
installed instead. Either way, whatever's currently in
`/etc/sudoers.d/developer` gets **overwritten** on the next reconfigure — so
editing it directly isn't durable, only the override file at
`/etc/argus-tty/developer.sudoers` is.

If your override has a syntax error, `reconfigure` fails loudly (prints the
exact `visudo` error and stops) rather than silently falling back to the
default — you always know for certain which one is actually in effect.

This is a shipped, read-only sample plus an optional override the tool
checks for automatically — the same pattern used throughout this toolkit
(e.g. `config.env` itself). No new sudo access is possible through the
override mechanism itself — you're editing the same whitelist model, not
escaping it — but *what's in* the whitelist is entirely yours to adjust.

## Customizing the developer/admin/deployer tier names

The three tiers are called `developer`/`admin`/`deployer` everywhere by
default. If your org wants different terminology (e.g. `engineer`/`sre`/
`release`), set the corresponding config.env vars and reconfigure:

```bash
sudo vi /etc/argus-tty/config.env   # ADMIN_GROUP_NAME=sre
sudo argus-tty reconfigure
```

This drives the actual Linux group, every sudoers `%group` rule, the sshd
`AllowGroups`/`Match Group` block, and the PAM 2FA exemption — not just a
label. Renaming a tier that already has onboarded accounts is safe:
`reconfigure` detects the old canonical group (`admin`) still exists and
renames it in place with `groupmod -n`, preserving every existing account's
access, rather than creating an empty new group and leaving them behind in
the old one. As with any change that touches sshd's `AllowGroups`/`Match`
block, test a **new** connection in a separate terminal before closing your
current session.

The CLI's canonical verbs always keep working no matter what you set —
renaming only **adds** a synonym, it never removes the default:

```bash
sudo argus-tty add-admin alice ...    # still works
sudo argus-tty add-sre alice ...      # also works, once ADMIN_GROUP_NAME=sre
sudo argus-tty list-admins            # still works
sudo argus-tty list-sres              # also works
```

On-disk paths (`/etc/sudoers.d/developer`, `/etc/argus-tty/admin.sudoers`,
`/usr/share/argus-tty/deployer.sudoers.sample`, etc.) are **not** affected —
they stay on the canonical `developer`/`admin`/`deployer` names as internal
identifiers regardless of what you rename the actual group to; only the
`%<group>` token *inside* those files, and the group itself, changes.

## Restricting an account to specific source IPs

Beyond key-based auth, you can pin a developer/admin/deployer account to
only authenticate from known IP(s)/CIDR(s) — e.g. their office or VPN
egress address — using OpenSSH's native `authorized_keys` `from="..."`
option. sshd enforces it during authentication itself, before
`ForceCommand`/session start ever runs, and it takes effect on the very
**next** connection attempt — no `reconfigure`, no sshd reload:

```bash
sudo argus-tty allow-ip alice 203.0.113.5                    # single IP
sudo argus-tty allow-ip alice 203.0.113.5,198.51.100.0/24     # comma-separated list/CIDR
sudo argus-tty list-ip alice                                  # show alice's current restriction
sudo argus-tty list-ip                                        # show every account's restriction
sudo argus-tty clear-ip alice                                 # remove it — connect from anywhere again
```

Applies to every key in that account's `authorized_keys` as one allowlist,
not per individual key; re-running `allow-ip` replaces any existing
restriction rather than stacking another one on top. As with any sshd
access change: test the new restriction from a **separate** terminal/
session before closing whatever connection you used to set it, in case the
IP list is wrong.

## Excluding commands from full TTY capture

Every session is always fully audited — `.meta` (who, when, exact command,
exit code), the session-start/end email notifications, and the
`logger -t argus-tty` events all fire unconditionally, no matter what runs.
The one thing that's configurable is the byte-for-byte `.tty` transcript
(captured via `script`), which is meant for reviewing what someone actually
typed/saw — not for storing a live-streamed tail that just grows the file
for as long as the connection stays open.

There's no built-in default — every command gets full `.tty` capture unless
you opt one in. If your own deploy tooling has a long-running log-tail
subcommand (e.g. `ssh dev1@host 'mytool logs -f <app>'`) whose live-streamed
byte-for-byte output isn't meaningful to store and would otherwise grow the
`.tty` file for as long as the connection stays open, set
`NO_CAPTURE_COMMAND_PATTERN` in `/etc/argus-tty/config.env` to an extended
regex (bash `=~`) matching it:

```bash
sudo vi /etc/argus-tty/config.env
# NO_CAPTURE_COMMAND_PATTERN='^tail[[:space:]]+.*(-f|--follow)|^journalctl[[:space:]]+.*(-f|--follow)'
```

No `reconfigure` needed — `argus-tty-wrapper` reads `config.env` fresh on
every new session, so the change takes effect on the next connection. Keep
the pattern narrow: a command that could have skipped capture but didn't is
harmless (just the normal, fully-recorded behavior), but a pattern that's
too broad is the only way this setting could actually reduce the audit
trail.

## Configuration reference

Everything below lives in `/etc/argus-tty/config.env` (644, world-readable —
nothing in it is a secret; see the file's own header for why) except
`SMTP_USER`/`SMTP_PASS`, which live in the separate, root-only (600)
`/etc/argus-tty/smtp-credentials.env`. After editing either file, run `sudo
argus-tty reconfigure` to apply changes that need system-level wiring
(systemd, sshd); everything else (session-recording behavior) is picked up
fresh by `argus-tty-wrapper` on the very next SSH connection with no
`reconfigure` needed.

| Variable | Default | What it does |
|---|---|---|
| `S3_UPLOAD_ENABLED` | `false` | Master switch for shipping session recordings to S3. `false` → `argus-tty-finalize` exits immediately for every session, without even checking for the aws CLI or credentials. `true` → uploads are attempted (still gracefully skipped if the aws CLI/IAM role aren't usable). Sessions always record locally either way. |
| `S3_BUCKET` | *(blank)* | Destination bucket. Blank skips upload regardless of `S3_UPLOAD_ENABLED`. |
| `S3_PREFIX` | `argus-tty` | Key prefix under the bucket: `s3://<bucket>/<prefix>/<hostname>/<user>/<session_id>/...`. |
| `AWS_REGION` | `us-east-1` | Region passed to every `aws` CLI call (upload + the advisory `status`/`reconfigure` connectivity checks). |
| `EMAIL_ENABLED` | `false` | Master switch for session start/end email notifications. Directly controls `systemctl enable --now` vs. `disable --now` on `argus-tty-mailer.timer` — `false` means the mailer timer isn't just idle, it's disabled and never runs. |
| `EMAIL_TO` | `you@example.com` | Notification recipient. |
| `EMAIL_FROM` | `argus-tty@example.com` | Envelope/`From:` sender address. |
| `SMTP_HOST` / `SMTP_PORT` | `smtp.example.com` / `587` | SMTP endpoint `argus-tty-mailer` connects to. |
| `SMTP_USER` / `SMTP_PASS` (in `smtp-credentials.env`, 600 root-only) | *(blank)* | The one real secret in this toolkit — only `argus-tty-mailer` (root, via the systemd timer) ever reads this file. |
| `ALLOW_AGENT_FORWARDING` | `no` | Passed straight through to the sshd `Match` block's `AllowAgentForwarding` for developer/admin sessions. |
| `ALLOW_TCP_FORWARDING` | `no` | Same, for `AllowTcpForwarding`. |
| `ALLOW_X11_FORWARDING` | `no` | Same, for `X11Forwarding`. |
| `NO_CAPTURE_COMMAND_PATTERN` | *(unset — full capture on every command)* | Extended regex (bash `=~`) of commands that skip byte-for-byte `.tty` capture; see [Excluding commands from full TTY capture](#excluding-commands-from-full-tty-capture). Never affects `.meta`, email notifications, or `logger` events. |
| `LITE_RECORDING_USERS` | `ubuntu` | Space-separated usernames that skip full `.tty` capture entirely (every session, not just specific commands) while keeping `.hist`/`.meta`. Intended for a pre-existing privileged account like cloud-init's `ubuntu`, not developer/admin accounts. Also exempted from `GOOGLE_2FA_ENABLED` below, for the same reason. |
| `GOOGLE_2FA_ENABLED` | `false` | Master switch for requiring a Google Authenticator (TOTP) code, in addition to the SSH key, for developer/admin sessions. Deployer accounts and `LITE_RECORDING_USERS` are always exempt. See [Two-factor authentication](#two-factor-authentication-google-authenticator). |
| `DEVELOPER_GROUP_NAME` / `ADMIN_GROUP_NAME` / `DEPLOYER_GROUP_NAME` | `developer` / `admin` / `deployer` | Rename the three tiers' actual Linux group (and every sudoers/sshd/PAM reference to it) to your own terminology. See [Customizing the developer/admin/deployer tier names](#customizing-the-developeradmindeployer-tier-names). |

Both `S3_UPLOAD_ENABLED` and `EMAIL_ENABLED` default to `false` on a fresh
install — deliberately, same as the shipped `config.env.example` — so a
brand-new box never attempts an AWS or SMTP call until you've actually
filled in the rest of that integration's settings and flipped the switch.
`sudo argus-tty status` reports the effective state of both (timer
active/disabled, S3/SMTP reachability) so you can confirm your edits took
effect after `reconfigure`.

## Day to day

```bash
sudo argus-tty list          # developer roster, key status, last login
sudo argus-tty list-admins   # admin roster
sudo argus-tty status        # health check: sshd config, mailer timer, aws cli, S3, SMTP, disk usage
sudo argus-tty remove dev1                # offboard, keep home dir
sudo argus-tty remove dev1 --purge-home   # offboard, delete home dir too
```

Session recordings land in S3 at:
`s3://<bucket>/<prefix>/<hostname>/<username>/<session_id>/{session_id}.tty,.hist,.meta`

If aws isn't installed, or the instance has no usable credentials/IAM role,
those files are simply left under `/var/log/argus-tty/sessions/` instead.
Likewise, if SMTP is down or misconfigured, queued notifications sit in
`/var/log/argus-tty/notify/`, get retried automatically every 30s (up to 5
attempts), and finally move to `/var/log/argus-tty/notify/failed/` if
still undeliverable. `sudo argus-tty status` reports pending/failed
counts, and `journalctl -t argus-tty` on a given box shows per-session
skip/failure notices either way.

## Replicating to more machines

The `.deb` is the replication unit — it's fully self-contained:

```bash
scp dist/argus-tty_1.0.0_all.deb root@new-host:/tmp/
ssh root@new-host 'sudo apt install /tmp/argus-tty_1.0.0_all.deb'
sudo vi /etc/argus-tty/config.env             # per-machine or shared, your call
sudo argus-tty reconfigure
```

Reuse the same `developer_users.conf`/`admin_users.conf` for a
company-wide roster, or keep per-machine ones if access should differ by
box. Note that `/root/argus-tty-developer-keys/` (where auto-generated PEM
files land) is a runtime directory, never shipped in the package, so
installing on a new machine never drags another machine's private keys
along with it.

## Test checklist before you walk away from a session

Run this from a **new terminal**, without closing the one you're currently
using to make these changes — if something's wrong, you want a way back in.

```bash
ssh dev1@<host>                 # connects, banner shows "all commands are recorded"
sudo systemctl status ssh       # allowed (whitelisted)
sudo su                         # denied
sudo su root                    # denied
sudo bash                       # denied
sudo -s                         # denied
cd /root                        # denied
cd /home/<other-developer>      # denied
exit                            # disconnect — check S3 for the session files and your inbox for the email

# For an admin account, the same connect/disconnect flow applies, but:
ssh admin1@<host>
sudo su                         # ALLOWED — admin tier
sudo bash                       # ALLOWED — admin tier
exit                            # still recorded end-to-end, same as a developer session
```

If `GOOGLE_2FA_ENABLED=true`, also check the second factor from a **separate**
terminal before closing your current session:

```bash
ssh dev1@<host>                 # prompts for a Verification code: after the key succeeds
ssh admin1@<host>                # same — TOTP required for admin too

# Deployer and LITE_RECORDING_USERS (e.g. ubuntu) are exempt — no OTP prompt:
ssh deploy1@<host>               # connects straight through, key only
ssh ubuntu@<host>                # connects straight through, key only
```

## Installed layout (on a target machine)

```
/usr/bin/argus-tty                       # on PATH — the CLI
/usr/sbin/argus-tty-{wrapper,finalize,mailer}
/usr/lib/argus-tty/bin/*.sh              # CLI helper scripts (add/remove/list/status/...)
/usr/lib/argus-tty/lib/{common,reconfigure}.sh
/usr/share/argus-tty/{developer,admin,deployer}.sudoers.sample  # defaults — reconfigure.sh installs these, or your override
/usr/lib/systemd/system/argus-tty-mailer.{service,timer}
/etc/argus-tty/{config.env,smtp-credentials.env}
/etc/argus-tty/{developer,admin,deployer}.sudoers  # optional — your override, if you created one (see "Customizing sudo permissions" above)
/etc/sudoers.d/{developer,admin,deployer}          # generated by reconfigure.sh on every run, NOT a dpkg conffile
/etc/profile.d/developer-restrictions.sh
/etc/logrotate.d/argus-tty
/var/log/argus-tty/{sessions,notify}     # runtime data, not shipped by the package
/root/argus-tty-developer-keys/          # generated PEM private keys, not shipped by the package
```

## License

[MIT](LICENSE) — © 2026 Ram Laxman Yadav. Contributions welcome; see
[PACKAGING.md](PACKAGING.md) for how releases get built and published.
