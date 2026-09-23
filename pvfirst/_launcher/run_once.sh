#!/usr/bin/env bash
set -e
cd "$(dirname "$0")/.."
ROOT_DIR="$(pwd)"

if [ -f config/pvfirst.env ]; then
  # shellcheck disable=SC1091
  source <(sed 's/\r$//' config/pvfirst.env)
fi

bash ./_launcher/apply_config.sh
FLOPS="${1:-${PVFIRST_DEFAULT_FLOPS:-5e10}}"

check_internet() {
  local url="https://api.open-meteo.com/v1/forecast?latitude=${PVFIRST_LOCATION_LATITUDE:--1.4537}&longitude=${PVFIRST_LOCATION_LONGITUDE:--48.5078}&current=temperature_2m"
  if curl -fsS --connect-timeout 5 --max-time 8 "$url" >/dev/null 2>&1; then
    return 0
  fi
  # Proxy corporativo autenticado: usa credenciais do Windows logado.
  if [ "${PVFIRST_PROXY_AUTO:-0}" = "1" ] && [ -f "$ROOT_DIR/_launcher/windows_fetch.ps1" ]; then
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$ROOT_DIR/_launcher/windows_fetch.ps1")" -Url "$url" -Proxy "${PVFIRST_PROXY_URL:-}" >/dev/null 2>&1
    return $?
  fi
  return 1
}

echo "[PV-First] Rodando teste com FLOPs=$FLOPS"
echo "[PV-First] Fluxo: SIMULAR -> CSV LOCAL -> BASE CENTRAL GITHUB -> DASHBOARD"

if ! check_internet; then
  echo "[PV-First] SEM INTERNET: teste nao executado porque os sensores precisam de internet."
  exit 0
fi

printf '%s\n' "$FLOPS" | stdbuf -oL -eL ./run.sh

echo ""
echo "[PV-First] Enviando resultado para a base central do GitHub pela API do Windows..."
REPO_ROOT="$(cd "$ROOT_DIR/.." && pwd)"
BRIDGE_WIN="$(wslpath -w "$REPO_ROOT/_launcher/GITHUB_API_BRIDGE.ps1")"
ROOT_WIN="$(wslpath -w "$REPO_ROOT")"
SYNC_CODE=0
if [ "${PVFIRST_API_AUTO_SYNC:-1}" = "1" ]; then
  set +e
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$BRIDGE_WIN" -Action sync -Root "$ROOT_WIN" -Repo "${PVFIRST_GITHUB_REPO:-CAGDOJ/PhotovoltaicFirst}" -Branch "${PVFIRST_GITHUB_BRANCH:-main}"
  SYNC_CODE=$?
  set -e
else
  echo "[PV-First] Sincronizacao automatica desativada no painel do PC."
fi

if [ "$SYNC_CODE" -eq 0 ]; then
  echo ""
  echo "=================================================="
  echo "[PV-First] TESTE ENVIADO COM SUCESSO VIA GITHUB API"
  echo "[PV-First] Painel: https://cagdoj.github.io/PhotovoltaicFirst/"
  echo "=================================================="
else
  echo ""
  echo "=================================================="
  echo "[PV-First] TESTE SALVO LOCALMENTE, MAS A API NAO ENVIOU"
  echo "[PV-First] Abra PVFIRST.bat e confira o token do agente do PC."
  echo "=================================================="
fi
exit 0
