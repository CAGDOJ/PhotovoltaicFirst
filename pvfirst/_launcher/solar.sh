#!/usr/bin/env bash
set -e
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [ -f "$ROOT_DIR/config/pvfirst.env" ]; then
  # shellcheck disable=SC1091
  source <(sed 's/\r$//' "$ROOT_DIR/config/pvfirst.env")
fi

# Aplica configuracao em um subshell para nao manter a pasta do projeto como cwd.
( cd "$ROOT_DIR" && bash ./_launcher/apply_config.sh )
FLOPS="${1:-${PVFIRST_DEFAULT_FLOPS:-5e10}}"
echo "[PV-First] Coleta continua 24h com FLOPs=$FLOPS"
echo "[PV-First] Sem internet: o processo continua vivo, mas nao salva CSV."
echo "[PV-First] Com internet: simula, salva, atualiza painel e tenta enviar ao Git."
cd /tmp
exec bash "$ROOT_DIR/run_solar_window.sh" "$FLOPS"
