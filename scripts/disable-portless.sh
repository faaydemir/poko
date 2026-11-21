#!/bin/bash
set -euo pipefail
if [ "$(id -u)" != 0 ]; then echo 'Run with sudo.' >&2; exit 1; fi
/bin/launchctl bootout system/dev.port.forwarder 2>/dev/null || true
/bin/rm -f /Library/LaunchDaemons/dev.port.forwarder.plist /Library/PrivilegedHelperTools/dev.port.forwarder
