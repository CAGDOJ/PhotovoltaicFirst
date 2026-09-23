#!/usr/bin/env bash
set -e
cd "$(dirname "$0")/.."

if [ -f config/pvfirst.env ]; then
  # shellcheck disable=SC1091
  source <(sed 's/\r$//' config/pvfirst.env)
fi

HOST_SPEED_GFLOPS="${PVFIRST_HOST_SPEED_GFLOPS:-50}"
HOST_IDLE_W="${PVFIRST_HOST_IDLE_W:-120}"
HOST_ACTIVE_W="${PVFIRST_HOST_ACTIVE_W:-250}"
HOST_OFF_W="${PVFIRST_HOST_OFF_W:-10}"

mkdir -p simgrid
cat > simgrid/platform.xml <<EOF
<?xml version='1.0'?>
<!DOCTYPE platform SYSTEM "https://simgrid.org/simgrid.dtd">
<platform version="4.1">
  <zone id="AS0" routing="Full">
    <host id="hpc-node" speed="${HOST_SPEED_GFLOPS}Gf" core="1">
      <prop id="wattage_per_state" value="${HOST_IDLE_W}:${HOST_ACTIVE_W}:${HOST_ACTIVE_W}" />
      <prop id="wattage_off" value="${HOST_OFF_W}" />
    </host>
  </zone>
</platform>
EOF

echo "Platform SimGrid atualizada: speed=${HOST_SPEED_GFLOPS}Gf, wattage=${HOST_IDLE_W}:${HOST_ACTIVE_W}:${HOST_ACTIVE_W}, off=${HOST_OFF_W}W"
