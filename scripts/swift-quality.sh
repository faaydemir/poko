#!/bin/bash
# Dead-code scan for the Swift UI (needs Periphery: brew install periphery).
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v periphery >/dev/null; then echo "periphery not installed (brew install periphery); skipping Swift dead-code scan" >&2; exit 0; fi
periphery scan --strict --quiet --disable-update-check
