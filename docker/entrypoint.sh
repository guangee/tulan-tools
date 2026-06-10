#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/tulan-tools/bin:${PATH}"
exec apache2ctl -D FOREGROUND
