#!/usr/bin/env bash
set -e
cd "$(dirname "$0")/.."
rm -rf build
rm -f solar_window.log
rm -f dashboard/pvfirst_dashboard.html
mkdir -p results
rm -f _interno/current.log 2>/dev/null || true
echo "Build e logs limpos."
