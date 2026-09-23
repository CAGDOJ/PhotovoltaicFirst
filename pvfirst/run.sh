#!/bin/bash
set -e

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"

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

if [ -x "$ROOT_DIR/_launcher/apply_config.sh" ]; then
    bash "$ROOT_DIR/_launcher/apply_config.sh" >/dev/null 2>&1 || true
fi

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

CMAKE_LOG="$BUILD_DIR/cmake.log"
MAKE_LOG="$BUILD_DIR/make.log"

NEED_CONFIGURE=0

if [ ! -f Makefile ]; then
    NEED_CONFIGURE=1
fi

if [ -f "$ROOT_DIR/CMakeLists.txt" ] && [ -f Makefile ]; then
    if [ "$ROOT_DIR/CMakeLists.txt" -nt Makefile ]; then
        NEED_CONFIGURE=1
    fi
fi

# se a plataforma SimGrid mudou, garante a copia dentro do build
mkdir -p "$BUILD_DIR/simgrid"
if [ -f "$ROOT_DIR/simgrid/platform.xml" ]; then
    cp "$ROOT_DIR/simgrid/platform.xml" "$BUILD_DIR/simgrid/platform.xml"
fi

echo "Preparando ambiente..."

if [ "$NEED_CONFIGURE" -eq 1 ]; then
    if ! cmake .. >"$CMAKE_LOG" 2>&1; then
        echo ""
        echo "Erro na configuracao do projeto."
        echo "Abaixo esta o log do CMake:"
        echo "------------------------------------------------------------"
        cat "$CMAKE_LOG"
        echo "------------------------------------------------------------"
        exit 1
    fi
fi

# Evita falso erro de timestamp em pasta Windows/WSL.
sleep 1
find "$BUILD_DIR" -type f -exec touch {} + 2>/dev/null || true

if ! make -s -j"$(nproc)" >"$MAKE_LOG" 2>&1; then
    echo ""
    echo "Erro na compilacao do projeto."
    echo "Abaixo esta o log do make:"
    echo "------------------------------------------------------------"
    cat "$MAKE_LOG"
    echo "------------------------------------------------------------"
    exit 1
fi

cd "$ROOT_DIR"

if [ -t 1 ]; then
    clear
fi

./build/pvfirst "$@"
