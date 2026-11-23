#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/lint.sh
swift test
