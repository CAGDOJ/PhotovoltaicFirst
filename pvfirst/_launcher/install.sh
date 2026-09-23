#!/usr/bin/env bash
set -e
cd "$(dirname "$0")/.."
export DEBIAN_FRONTEND=noninteractive

echo "[1/8] Atualizando pacotes do Linux..."
apt-get update

echo "[2/8] Instalando dependencias do PV-First..."
apt-get install -y build-essential cmake pkg-config curl git libcurl4-openssl-dev libsimgrid-dev python3 dos2unix netcat-openbsd

echo "[3/8] Garantindo arquivo de configuracao..."
mkdir -p config
if [ ! -f config/pvfirst.env ]; then
cat > config/pvfirst.env <<'EOF'
export PVFIRST_DEFAULT_FLOPS="5e13"
export PVFIRST_PANEL_MATERIAL="monocrystalline"
export PVFIRST_PANEL_FACE_TYPE="bifacial"
export PVFIRST_PANEL_AREA_M2="2500"
export PVFIRST_PANEL_BASE_EFFICIENCY="0.23"
export PVFIRST_BIFACIAL_GAIN="1.15"
export PVFIRST_GRID_CARBON_INTENSITY="100"
export PVFIRST_HOST_SPEED_GFLOPS="1000"
export PVFIRST_HOST_IDLE_W="300"
export PVFIRST_HOST_ACTIVE_W="750"
export PVFIRST_HOST_OFF_W="20"
export PVFIRST_DC_ACTIVE_SERVERS="128"
export PVFIRST_DC_PUE="1.40"
export PVFIRST_DC_NETWORK_KW="20"
export PVFIRST_DC_STORAGE_KW="10"
export PVFIRST_SOLAR_START_HOUR="6"
export PVFIRST_SOLAR_INTERVAL_SECONDS="60"
export PVFIRST_SOLAR_ZERO_LIMIT="5"
export PVFIRST_IRRADIANCE_MIN_WM2="1"
export PVFIRST_LOCATION_MODE="manual"
export PVFIRST_LOCATION_CITY="Belem"
export PVFIRST_LOCATION_LATITUDE="-1.4537"
export PVFIRST_LOCATION_LONGITUDE="-48.5078"
export PVFIRST_GIT_AUTO_PUSH="1"
export PVFIRST_GIT_REMOTE="origin"
export PVFIRST_GIT_BRANCH="main"
export PVFIRST_GIT_REPO_URL="git@github.com:CAGDOJ/PhotovoltaicFirst.git"
export PVFIRST_GIT_COMMIT_PREFIX="Atualiza resultados PV-First"
export PVFIRST_GIT_USER_NAME="PV-First Collector"
export PVFIRST_GIT_USER_EMAIL="pvfirst@local"
EOF
fi

echo "[4/8] Ajustando scripts Linux..."
dos2unix run.sh run_solar_window.sh _launcher/*.sh >/dev/null 2>&1 || true
chmod +x run.sh run_solar_window.sh _launcher/*.sh

echo "[5/8] Aplicando configuracao da plataforma SimGrid..."
bash ./_launcher/apply_config.sh

echo "[6/8] Corrigindo horarios dos arquivos e preparando build..."
# Em pastas montadas do Windows, o Make pode enxergar arquivos alguns milesimos no futuro.
# Isso nao e erro do PV-First; e diferenca de relogio entre Windows e WSL.
# O touch + sleep evita o aviso: File Makefile has modification time in the future.
find . -type f -exec touch {} + 2>/dev/null || true
sleep 2
rm -rf build
mkdir -p build

echo "[7/8] Configurando e compilando projeto..."
cd build
cmake ..
# Em alguns PCs o relogio entre Windows e WSL fica alguns segundos diferente.
# Abaixo eu marco os arquivos do build levemente no passado para o make nao parar por clock skew.
sleep 3
find . -type f -exec touch -d '1 minute ago' {} + 2>/dev/null || true
MAKE_STATUS=0
make -B -j"$(nproc)" || MAKE_STATUS=$?
if [ "$MAKE_STATUS" -ne 0 ]; then
    if [ -x ./pvfirst ]; then
        echo "Aviso do make ignorado porque o binario pvfirst foi gerado corretamente."
    else
        echo "Primeira tentativa de compilacao falhou. Ajustando timestamps e tentando novamente..."
        cd ..
        find . -type f -exec touch -d '1 minute ago' {} + 2>/dev/null || true
        sleep 3
        cd build
        make -B -j"$(nproc)"
    fi
fi
cd ..

echo "[8/8] Gerando painel HTML local..."
python3 dashboard/build_dashboard.py || true

echo "OK" > .pvfirst_installed
echo "Instalacao/verificacao concluida."
