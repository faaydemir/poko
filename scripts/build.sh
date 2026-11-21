#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
clang -Os -Wall -Wextra -Werror -mmacosx-version-min=13.0 scripts/listener-probe.c -o server/listener-probe
codesign --force --sign - server/listener-probe
swift build -c release -Xswiftc -debug-prefix-map -Xswiftc "$PWD=."
mkdir -p 'dist/Poko.app/Contents/MacOS' 'dist/Poko.app/Contents/Resources' 'dist/Poko Server.app/Contents/MacOS' 'dist/Poko Server.app/Contents/Resources' dist/Port.iconset
cp .build/release/PortUI 'dist/Poko.app/Contents/MacOS/Poko'
strip -S 'dist/Poko.app/Contents/MacOS/Poko'
mkdir -p 'dist/Poko.app/Contents/Resources/AgentIcons'
cp Sources/PortUI/Resources/AgentIcons/*.png 'dist/Poko.app/Contents/Resources/AgentIcons/'
swiftc -target "$(uname -m)-apple-macosx13.0" scripts/ServerLauncher.swift -o 'dist/Poko Server.app/Contents/MacOS/PortServer'
swift scripts/icon.swift dist/icon.png
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" dist/icon.png --out "dist/Port.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" dist/icon.png --out "dist/Port.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns dist/Port.iconset -o dist/Port.icns
python3 - <<'PY'
import plistlib, shutil, json
version=json.load(open('package.json'))['version']
for name,executable,identifier in [('Poko','Poko','dev.port.ui'),('Poko Server','PortServer','dev.port.server-app')]:
    root=f'dist/{name}.app/Contents'
    with open(root+'/Info.plist','wb') as f:
        plistlib.dump(dict(CFBundleName=name,CFBundleDisplayName=name,CFBundleIdentifier=identifier,CFBundleExecutable=executable,CFBundlePackageType='APPL',CFBundleVersion=version,CFBundleShortVersionString=version,LSMinimumSystemVersion='13.0',LSUIElement=True,CFBundleIconFile='Port',NSHighResolutionCapable=True),f)
    shutil.copy('dist/Port.icns',root+'/Resources/Port.icns')
PY
codesign --force --deep --sign - 'dist/Poko.app'
codesign --force --deep --sign - 'dist/Poko Server.app'
printf 'Built dist/Poko.app and dist/Poko Server.app\n'
