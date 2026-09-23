#!/bin/bash
set -e

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd /tmp

if [ -f "$ROOT_DIR/config/pvfirst.env" ]; then
    # shellcheck disable=SC1091
    source <(sed 's/\r$//' "$ROOT_DIR/config/pvfirst.env")
fi

if [ "${PVFIRST_PROXY_AUTO:-0}" = "1" ] && [ -n "${PVFIRST_PROXY_URL:-}" ]; then
    export http_proxy="$PVFIRST_PROXY_URL" https_proxy="$PVFIRST_PROXY_URL"
    export HTTP_PROXY="$PVFIRST_PROXY_URL" HTTPS_PROXY="$PVFIRST_PROXY_URL"
    export no_proxy="${PVFIRST_NO_PROXY:-localhost,127.0.0.1,::1,.intraer}"
    export NO_PROXY="$no_proxy"
fi

LOG_FILE="$ROOT_DIR/solar_window.log"
JOB_FLOPS="${1:-${PVFIRST_DEFAULT_FLOPS:-5e10}}"
INTERVAL_SECONDS="${PVFIRST_SOLAR_INTERVAL_SECONDS:-60}"
INTERVAL_SECONDS="$(printf '%s' "$INTERVAL_SECONDS" | tr -d '\r\n ' )"
if ! [[ "$INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || [ "$INTERVAL_SECONDS" -lt 1 ]; then
    echo "[PV-First] Intervalo invalido no config; usando 60 s." | tee -a "$LOG_FILE" 2>/dev/null || true
    INTERVAL_SECONDS=60
fi

check_internet() {
    local url="https://api.open-meteo.com/v1/forecast?latitude=${PVFIRST_LOCATION_LATITUDE:--1.4537}&longitude=${PVFIRST_LOCATION_LONGITUDE:--48.5078}&current=temperature_2m"
    if curl -fsS --connect-timeout 5 --max-time 8 "$url" >/dev/null 2>&1; then
        return 0
    fi
    if [ "${PVFIRST_PROXY_AUTO:-0}" = "1" ] && [ -f "$ROOT_DIR/_launcher/windows_fetch.ps1" ]; then
        powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$ROOT_DIR/_launcher/windows_fetch.ps1")" -Url "$url" -Proxy "${PVFIRST_PROXY_URL:-}" >/dev/null 2>&1
        return $?
    fi
    return 1
}

{
    echo "=================================================="
    echo "PV-First - coleta continua em modo data center"
    echo "Inicio: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "FLOPs do job: $JOB_FLOPS"
    echo "Intervalo entre execucoes: $INTERVAL_SECONDS s"
    echo "Regra: o processo fica vivo 24h, inclusive em segundo plano."
    echo "Sem internet: nao salva CSV e nao derruba a coleta."
    echo "Com internet: simula, salva, atualiza painel e envia pela GitHub API do Windows."
    echo "PHOTOVOLTAIC entra primeiro; GRID complementa quando a PV nao cobre toda a demanda."
    echo "=================================================="
} | tee -a "$LOG_FILE"

while true; do
    NOW="$(date '+%Y-%m-%d %H:%M:%S')"

    if ! check_internet; then
        echo "[$NOW] SEM INTERNET: coleta continua em segundo plano. Nenhuma linha sera salva no CSV ate a internet voltar." | tee -a "$LOG_FILE"
        sleep "$INTERVAL_SECONDS"
        continue
    fi

    TMP_OUTPUT="$(mktemp)"
    echo "[$NOW] INTERNET OK: executando simulacao de data center com SimGrid, PHOTOVOLTAIC e GRID..." | tee -a "$LOG_FILE"

    set +e
    (
        cd "$ROOT_DIR" || exit 1
        printf '%s\n' "$JOB_FLOPS" | stdbuf -oL -eL ./run.sh 2>&1
        exit ${PIPESTATUS[1]}
    ) | tee "$TMP_OUTPUT" | tee -a "$LOG_FILE"
    RUN_STATUS=${PIPESTATUS[0]}
    set -e

    if [ "$RUN_STATUS" -ne 0 ]; then
        echo "[$NOW] A execucao falhou. Nada foi salvo nesta rodada. Vou tentar novamente em $INTERVAL_SECONDS segundos." | tee -a "$LOG_FILE"
        rm -f "$TMP_OUTPUT"
        sleep "$INTERVAL_SECONDS"
        continue
    fi

    if grep -q "PHOTOVOLTAIC : ON" "$TMP_OUTPUT" && grep -q "GRID         : OFF" "$TMP_OUTPUT"; then
        echo "[$NOW] Fonte da rodada: PHOTOVOLTAIC ON, GRID OFF." | tee -a "$LOG_FILE"
    elif grep -q "PHOTOVOLTAIC : ON" "$TMP_OUTPUT" && grep -q "GRID         : ON" "$TMP_OUTPUT"; then
        echo "[$NOW] Fonte da rodada: PHOTOVOLTAIC ON, GRID ON como complemento." | tee -a "$LOG_FILE"
    elif grep -q "GRID         : ON" "$TMP_OUTPUT"; then
        echo "[$NOW] Fonte da rodada: PHOTOVOLTAIC OFF, GRID ON." | tee -a "$LOG_FILE"
    fi

    rm -f "$TMP_OUTPUT"
    REPO_ROOT="$(cd "$ROOT_DIR/.." && pwd)"
    BRIDGE_WIN="$(wslpath -w "$REPO_ROOT/_launcher/GITHUB_API_BRIDGE.ps1")"
    ROOT_WIN="$(wslpath -w "$REPO_ROOT")"
    if [ "${PVFIRST_API_AUTO_SYNC:-1}" = "1" ]; then
      powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$BRIDGE_WIN" -Action sync -Root "$ROOT_WIN" -Repo "${PVFIRST_GITHUB_REPO:-CAGDOJ/PhotovoltaicFirst}" -Branch "${PVFIRST_GITHUB_BRANCH:-main}" >/dev/null 2>&1 || true
    fi
    sleep "$INTERVAL_SECONDS"
done
