#!/bin/bash
# Poko installer: curl -fsSL https://raw.githubusercontent.com/OWNER/poko/main/install.sh | bash
# Downloads the latest GitHub release for this Mac, verifies its SHA-256 and installs per-user.
# Environment: POKO_REPO (owner/name), POKO_VERSION (e.g. 1.0.0, default latest).
set -euo pipefail

REPO="${POKO_REPO:-faaydemir/poko}"
say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || die "Poko runs on macOS only."
[ "$(id -u)" -ne 0 ] || die "Run as your normal user, not root; Poko installs per-user."
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MAJOR" -ge 13 ] || die "macOS 13 or newer is required."
case "$(uname -m)" in arm64) ARCH=arm64 ;; x86_64) ARCH=x86_64 ;; *) die "Unsupported architecture $(uname -m)" ;; esac

if [ -n "${POKO_VERSION:-}" ]; then
  VERSION="${POKO_VERSION#v}"
else
  # The /releases/latest redirect needs no API token and has no rate limit.
  TAG="$(curl -fsSIL -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")" || die "Cannot reach github.com/$REPO"
  VERSION="${TAG##*/v}"
  case "$TAG" in */releases/tag/v*) ;; *) die "No published release found for $REPO" ;; esac
fi

ARCHIVE="Poko-${VERSION}-macos-${ARCH}.zip"
BASE="https://github.com/$REPO/releases/download/v${VERSION}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/poko-install.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

say "Downloading Poko $VERSION ($ARCH)"
curl -fL --retry 3 --progress-bar "$BASE/$ARCHIVE" -o "$WORK/$ARCHIVE" || die "Download failed: $BASE/$ARCHIVE"
curl -fsL --retry 3 "$BASE/$ARCHIVE.sha256" -o "$WORK/$ARCHIVE.sha256" || die "Checksum download failed"
say "Verifying checksum"
(cd "$WORK" && shasum -a 256 -c "$ARCHIVE.sha256" >/dev/null) || die "Checksum mismatch; aborting."

say "Installing to ~/Applications"
ditto -x -k "$WORK/$ARCHIVE" "$WORK/extracted"
xattr -dr com.apple.quarantine "$WORK/extracted" 2>/dev/null || true
"$WORK/extracted/Poko Installer.app/Contents/MacOS/PokoInstaller" --yes

say "Done. Poko is in your menu bar; connect your AI agents from Agents → Add MCP."
