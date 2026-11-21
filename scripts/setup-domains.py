#!/usr/bin/python3
import os,sys,pathlib,shutil,plistlib,subprocess
if os.geteuid()!=0: raise SystemExit('Administrator authorization required')
target=pathlib.Path('/Library/PrivilegedHelperTools/dev.port.domains.py')
plist=pathlib.Path('/Library/LaunchDaemons/dev.port.domains.plist')
if len(sys.argv)>=3 and sys.argv[1]=='--disable':
    uid=sys.argv[2]
    subprocess.run(['/bin/launchctl','bootout','system/dev.port.domains'],capture_output=True)
    for p in (plist,target,pathlib.Path('/var/run/dev.port.domains-'+uid+'.json')):
        p.unlink(missing_ok=True)
    sys.exit(0)
source,support,uid=sys.argv[1:]
target.parent.mkdir(parents=True,exist_ok=True)
shutil.copyfile(source,target);os.chown(target,0,0);os.chmod(target,0o755)
subprocess.run(['/bin/launchctl','bootout','system/dev.port.domains'],capture_output=True)
config=dict(Label='dev.port.domains',ProgramArguments=['/usr/bin/python3',str(target),str(pathlib.Path(support)/'registry.json'),'/var/run/dev.port.domains-'+uid+'.json',uid],RunAtLoad=True,KeepAlive=True,ThrottleInterval=10,StandardErrorPath='/var/log/port-domains.log')
with open(plist,'wb') as f:plistlib.dump(config,f)
os.chown(plist,0,0);os.chmod(plist,0o644)
subprocess.run(['/bin/launchctl','bootstrap','system',str(plist)],check=True)
