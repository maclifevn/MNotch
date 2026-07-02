#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
pkill -x MNotch 2>/dev/null || true
Scripts/build.sh
open build/MNotch.app
