# Publishing argus-tty to a Launchpad PPA

This repo ships two independent ways to build a `.deb`:

| Path | Produces | Use for |
|---|---|---|
| `./build-deb.sh` | a prebuilt binary `.deb` (`dist/argus-tty_<version>_all.deb`) | quick local installs, testing, air-gapped boxes — see [README.md](README.md#installing) |
| `debian/` + `debuild`/`dpkg-buildpackage` | a Debian **source** package (`.dsc` + `.tar.xz` + `.changes`) | uploading to Launchpad — **a PPA only ever builds from source**, it will not accept a prebuilt `.deb` |

Both read from the exact same `bin/`, `lib/`, `config/`, `sudoers/`,
`logrotate/`, `systemd/`, and `packaging/DEBIAN/*` maintainer scripts —
`debian/rules` mirrors `build-deb.sh`'s install steps file-for-file
and copies `packaging/DEBIAN/{preinst,postinst,prerm,postrm}` into `debian/`
at build time, so there is one source of truth for the actual scripts.
Keep `debian/rules`'s `override_dh_auto_install` in sync if you add, rename,
or move a shipped file — same as you'd do for `build-deb.sh`.

This guide covers the **personal PPA** path (self-service, you own the
whole process end to end). Getting into the *official* Ubuntu archive
instead is a much heavier process — an ITP bug, Debian policy compliance,
and a MOTU (Masters Of The Ubuntu Universe) sponsor to review and upload on
your behalf — realistically weeks of review by actual humans, not something
that can be scripted end-to-end. Start with the PPA; it's what most
Ubuntu users actually install from anyway (`add-apt-repository ppa:...`).

## 1. One-time setup (per Launchpad account)

1. **Create a Launchpad account**: https://launchpad.net (if you don't have
   one already).
2. **Generate a GPG key** (skip if you already have one you use for
   package signing):
   ```bash
   gpg --full-generate-key       # RSA, 4096 bit, no expiry or a long one
   gpg --list-secret-keys --keyid-format LONG
   ```
3. **Upload it to a keyserver Launchpad polls**, then tell Launchpad about
   your key fingerprint under *Account → OpenPGP keys*:
   ```bash
   gpg --keyserver keyserver.ubuntu.com --send-keys <YOUR_KEY_ID>
   ```
   Launchpad will email you a confirmation message to encrypt/decrypt with
   your key to prove ownership — follow the on-page instructions.
4. **Sign the Ubuntu Code of Conduct** on Launchpad (required before you can
   upload anything) — *Account → Code of Conduct*.
5. **Create the PPA itself**: on your Launchpad profile page, *Create a new
   PPA*, name it `argus-tty`. For this project that's:
   ```
   ppa:yadavramlaxman/argus-tty
   ```
   (already reserved by you — this guide assumes that exact name below.)
6. **Install the tooling** (on your build machine — Ubuntu/Debian):
   ```bash
   sudo apt-get install devscripts debhelper dput gnupg
   ```

## 2. Every release: build and upload

From the repo root (this directory — the one with `debian/` in it):

1. **Bump the version** if you haven't already:
   - `VERSION` (used by `build-deb.sh`) and `debian/changelog`'s top entry
     must agree.
   - This is a **native** package (`debian/source/format` = `3.0 (native)`)
     — there's no separate upstream-tarball-vs-Debian-revision split, so
     versions are plain (`1.0.0`, `1.0.1`, ...), never `1.0.0-1`. `lintian`
     will flag a dash in the version as `native-package-with-dash-version`.
   - Easiest way to add a changelog entry correctly formatted: `dch -i`
     (opens `$EDITOR`) or `dch -v 1.0.1 "What changed"`.

2. **Set the target Ubuntu series** in `debian/changelog`'s top line. It
   currently says `UNRELEASED`, which `debuild` will refuse to upload as-is
   — change it to the series you're targeting, e.g.:
   ```
   argus-tty (1.0.0) noble; urgency=medium
   ```
   A PPA build is **per-series** (the code that runs on 22.04 "jammy" isn't
   necessarily built against the same library versions as 24.04 "noble").
   To support multiple series, either:
   - upload once per series, bumping the changelog's distribution field and
     re-running the build+upload steps each time (e.g. `noble`, then
     `jammy`) — since this is a native package, give each re-upload its own
     version bump (e.g. `1.0.0` for noble, `1.0.1` for a jammy respin) rather
     than reusing the same version number twice, or
   - rely on Launchpad's "build for all supported series" behavior for
     architecture-independent (`Architecture: all`) packages like this one
     — check your PPA's settings for which series it builds against.

3. **Build the source package** (this is what actually gets uploaded — no
   binary `.deb` involved):
   ```bash
   debuild -S -sa
   ```
   - `-S` — build a source package, not a binary one (Launchpad's builders
     do the binary build).
   - `-sa` — force-include the full source tarball (needed for a first
     upload of a given version; `dpkg-genchanges` can otherwise assume the
     previous upload already has it).
   - This will prompt for your GPG passphrase to sign `.dsc` and `.changes`.
   - Output lands **one directory above** this repo (standard `debuild`
     behavior): `../argus-tty_1.0.0_source.changes` and friends.

4. **Upload with `dput`**:
   ```bash
   dput ppa:yadavramlaxman/argus-tty ../argus-tty_1.0.0_source.changes
   ```
   You'll get a confirmation email from Launchpad, then another once the
   build finishes (or fails — check the PPA's build log if so). Typical
   turnaround is minutes to a couple of hours depending on builder queue
   depth.

5. **Once it builds**, anyone can install it with:
   ```bash
   sudo add-apt-repository ppa:yadavramlaxman/argus-tty
   sudo apt update
   sudo apt install argus-tty
   ```

## 3. Local sanity check before uploading

Catch packaging mistakes before Launchpad's builders do:

```bash
# Build a source package locally (same command as step 2 above)
debuild -S -sa

# Lint it — fix anything reported as "error", read through "warning"
lintian ../argus-tty_1.0.0_source.changes

# Optional but recommended: actually build the binary in a clean chroot,
# the same way Launchpad's builders will, instead of trusting your local
# machine's installed packages:
pbuilder-dist noble build ../argus-tty_1.0.0.dsc       # needs pbuilder-dist / ubuntu-dev-tools
```

## 4. What's still a placeholder

- `debian/control`'s `Homepage`/`Vcs-Browser` point at the PPA page itself
  since there's no separate public git remote configured yet. If you push
  this repo to GitHub/GitLab/Launchpad's own git hosting, update those two
  fields (and add `Vcs-Git:`) to point at it.
- `debian/changelog`'s distribution is `UNRELEASED` — see step 2 above,
  you must change this before every real upload.
