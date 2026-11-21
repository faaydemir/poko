#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Official Node distributions are portable; Homebrew's node can depend on local dylibs.
NODE_VERSION="${POKO_NODE_VERSION:-22.22.0}"
ARCH="$(uname -m)"
case "$ARCH" in arm64) NODE_ARCH=arm64 ;; x86_64) NODE_ARCH=x64 ;; *) exit 1 ;; esac
VERSION="$(node -p 'require("./package.json").version')"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/poko-package.XXXXXX")"
export POKO_STAGE="$STAGE" POKO_VERSION="$VERSION"
trap 'python3 -c '\''import os, shutil; shutil.rmtree(os.environ["POKO_STAGE"], ignore_errors=True)'\''' EXIT
npm run build
INSTALLER="$STAGE/Poko Installer.app"
PAYLOAD="$INSTALLER/Contents/Resources/payload"
mkdir -p "$INSTALLER/Contents/MacOS" "$PAYLOAD/runtime/bin"
swiftc -O -target "${ARCH}-apple-macosx13.0" scripts/Installer.swift -o "$INSTALLER/Contents/MacOS/PokoInstaller"
cp -R dist/Poko.app 'dist/Poko Server.app' "$PAYLOAD/"
cp -R server "$PAYLOAD/runtime/"
cp package.json package-lock.json "$PAYLOAD/runtime/"
cp SKILL.md scripts/connect-agents.mjs scripts/domain-router.py scripts/setup-domains.py scripts/uninstall.sh "$PAYLOAD/runtime/"
(cd "$PAYLOAD/runtime" && npm ci --omit=dev --ignore-scripts --no-audit --no-fund)
NODE_FILE="node-v${NODE_VERSION}-darwin-${NODE_ARCH}.tar.gz"
curl --fail --location --retry 3 "https://nodejs.org/dist/v${NODE_VERSION}/${NODE_FILE}" -o "$STAGE/$NODE_FILE"
curl --fail --location --retry 3 "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" -o "$STAGE/SHASUMS256.txt"
(cd "$STAGE" && awk -v file="$NODE_FILE" '$2 == file' SHASUMS256.txt > node.sha256 && test -s node.sha256 && shasum -a 256 -c node.sha256)
tar -xzf "$STAGE/$NODE_FILE" -C "$STAGE" "node-v${NODE_VERSION}-darwin-${NODE_ARCH}/bin/node" "node-v${NODE_VERSION}-darwin-${NODE_ARCH}/LICENSE"
cp "$STAGE/node-v${NODE_VERSION}-darwin-${NODE_ARCH}/bin/node" "$PAYLOAD/runtime/bin/node"
cp "$STAGE/node-v${NODE_VERSION}-darwin-${NODE_ARCH}/LICENSE" "$PAYLOAD/runtime/NODE-LICENSE"
"$PAYLOAD/runtime/bin/node" --version
cp dist/Port.icns "$INSTALLER/Contents/Resources/Port.icns"
python3 - <<'PY'
import os, pathlib, plistlib
p=pathlib.Path(os.environ['POKO_STAGE'])/'Poko Installer.app/Contents/Info.plist'
p.write_bytes(plistlib.dumps(dict(CFBundleName='Poko Installer',CFBundleDisplayName='Poko Installer',CFBundleIdentifier='dev.port.installer',CFBundleExecutable='PokoInstaller',CFBundlePackageType='APPL',CFBundleVersion=os.environ['POKO_VERSION'],CFBundleShortVersionString=os.environ['POKO_VERSION'],LSMinimumSystemVersion='13.0',CFBundleIconFile='Port',NSHighResolutionCapable=True)))
PY
codesign --force --deep --sign - "$INSTALLER"
codesign --verify --deep --strict "$INSTALLER"
OUTPUT="dist/Poko-${VERSION}-macos-${ARCH}.zip"
ditto -c -k --keepParent "$INSTALLER" "$OUTPUT"
(cd dist && shasum -a 256 "$(basename "$OUTPUT")" > "$(basename "$OUTPUT").sha256")
python3 scripts/verify-package.py "$OUTPUT"
# Delete only this invocation's temporary build tree.
python3 -c 'import os, shutil; shutil.rmtree(os.environ["POKO_STAGE"])'
printf 'Created %s\n' "$OUTPUT"
