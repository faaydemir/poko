#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d dist/Poko.app ] && [ -x server/listener-probe ] || bash scripts/build.sh
export PORT_NODE_BIN="$(command -v node)"
python3 - <<'PY'
import os, pathlib, shutil, plistlib, subprocess, json
home=pathlib.Path.home()
support=home/'Library/Application Support/Port'
runtime=support/'runtime'
apps=home/'Applications'
launch=home/'Library/LaunchAgents/dev.port.server.plist'
for p in (support,runtime,apps,launch.parent): p.mkdir(parents=True,exist_ok=True)
os.chmod(support,0o700)
subprocess.run(['launchctl','bootout',f'gui/{os.getuid()}',str(launch)],capture_output=True)
for name in ['Poko','Poko Server']:
    target=apps/f'{name}.app'
    if target.exists():
        info=plistlib.load(open(target/'Contents/Info.plist','rb'))
        if info.get('CFBundleIdentifier') not in ('dev.port.ui','dev.port.server-app'): raise SystemExit(f'Refusing to replace unrelated {target}')
        shutil.rmtree(target)
    shutil.copytree(f'dist/{name}.app',target)
for name in ['server','node_modules']:
    target=runtime/name
    if target.exists(): shutil.rmtree(target)
    shutil.copytree(name,target)
for obsolete in ['enable-portless.sh','port-forwarder']:
    (runtime/obsolete).unlink(missing_ok=True)
for name in ['domain-router.py','setup-domains.py']:
    shutil.copy('scripts/'+name,runtime/name)
shutil.copy('scripts/connect-agents.mjs',runtime/'connect-agents.mjs')
shutil.copy('SKILL.md',runtime/'SKILL.md')
with open(runtime/'agent-config.json','w') as f: json.dump(dict(node=os.path.realpath(os.environ['PORT_NODE_BIN'])),f)
shutil.copy('package.json',runtime/'package.json')
shutil.copy('package-lock.json',runtime/'package-lock.json')
config=dict(Label='dev.port.server',ProgramArguments=[os.environ['PORT_NODE_BIN'],str(runtime/'server/daemon.mjs')],WorkingDirectory=str(runtime),RunAtLoad=True,KeepAlive=True,ThrottleInterval=5,StandardOutPath=str(support/'server.log'),StandardErrorPath=str(support/'server.error.log'),EnvironmentVariables=dict(PORT_DATA_DIR=str(support)))
with open(launch,'wb') as f: plistlib.dump(config,f)
subprocess.run(['launchctl','bootstrap',f'gui/{os.getuid()}',str(launch)],check=True)
subprocess.run(['open',str(apps/'Poko.app')],check=True)
print('Installed apps in ~/Applications and started the per-user Poko Server.')
PY
