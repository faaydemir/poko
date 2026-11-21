#!/bin/bash
set -euo pipefail
python3 - <<'PY'
import pathlib,os,subprocess,shutil,plistlib
home=pathlib.Path.home();launch=home/'Library/LaunchAgents/dev.port.server.plist'
subprocess.run(['launchctl','bootout',f'gui/{os.getuid()}',str(launch)],capture_output=True)
launch.unlink(missing_ok=True)
subprocess.run(['osascript','-e','tell application id "dev.port.ui" to quit'],capture_output=True)
for name in ['Poko','Poko Server']:
    p=home/f'Applications/{name}.app'
    if p.exists() and plistlib.load(open(p/'Contents/Info.plist','rb')).get('CFBundleIdentifier') in ('dev.port.ui','dev.port.server-app'): shutil.rmtree(p)
print('Removed apps and launch agent. Registry and runtime are preserved in ~/Library/Application Support/Port. Remove the port MCP entry from agents before deleting that folder.')
PY
