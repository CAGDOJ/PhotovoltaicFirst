#!/usr/bin/env bash

# Publica o painel local do PV-First na pasta docs/ do repositorio.
# A pasta docs/ e usada pelo GitHub Pages.

set +e

cd "$(dirname "$0")/.." || exit 0
PROJECT_DIR="$(pwd)"
REPO_ROOT="$PROJECT_DIR"
if [ -d "$PROJECT_DIR/../.git" ] || [ -d "$PROJECT_DIR/../docs" ]; then
  REPO_ROOT="$(cd "$PROJECT_DIR/.." && pwd)"
fi

MODE="${1:-push}"

log(){ echo "[Pages] $*"; }

if [ -f config/pvfirst.env ]; then
  # shellcheck disable=SC1091
  source <(sed 's/\r$//' config/pvfirst.env)
fi

if [ "${PVFIRST_PROXY_AUTO:-0}" = "1" ] && [ -n "${PVFIRST_PROXY_URL:-}" ]; then
  export http_proxy="$PVFIRST_PROXY_URL" https_proxy="$PVFIRST_PROXY_URL"
  export HTTP_PROXY="$PVFIRST_PROXY_URL" HTTPS_PROXY="$PVFIRST_PROXY_URL"
  export no_proxy="${PVFIRST_NO_PROXY:-localhost,127.0.0.1,::1,.intraer}"
  export NO_PROXY="$no_proxy"
  log "Proxy ativo: $PVFIRST_PROXY_URL"
fi

REMOTE_NAME="${PVFIRST_GIT_REMOTE:-origin}"
BRANCH_NAME="${PVFIRST_GIT_BRANCH:-main}"
REPO_URL="${PVFIRST_GIT_REPO_URL:-git@github.com:CAGDOJ/PhotovoltaicFirst.git}"

mkdir -p "$REPO_ROOT/docs/results" "$REPO_ROOT/docs/assets" "$REPO_ROOT/docs/downloads"

log "Gerando dashboard local..."
python3 dashboard/build_dashboard.py >/dev/null 2>&1 || log "Nao consegui gerar dashboard agora. Vou publicar o que ja existir."

if [ -f dashboard/pvfirst_dashboard.html ]; then
  cp -f dashboard/pvfirst_dashboard.html "$REPO_ROOT/docs/dashboard.html"
  log "Dashboard copiado para docs/dashboard.html"
fi

if [ -d results ]; then
  find results -type f -name '*.csv' -exec cp -f {} "$REPO_ROOT/docs/results/" \; 2>/dev/null || true
  log "Resultados CSV copiados para docs/results/"
fi

# Mantem arquivos estaticos de controle se existirem na raiz do repositorio.
if [ -f "$REPO_ROOT/docs/controle.html" ]; then
  cp -f "$REPO_ROOT/docs/controle.html" "$REPO_ROOT/controle.html" 2>/dev/null || true
  log "Controle remoto publicado em docs/controle.html e controle.html"
fi
if [ -f "$REPO_ROOT/docs/dashboard.html" ]; then
  cat > "$REPO_ROOT/dashboard.html" <<'EOF'
<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="refresh" content="0; url=docs/dashboard.html"><title>PV-First Dashboard</title></head><body><p>Abrindo <a href="docs/dashboard.html">dashboard</a>...</p></body></html>
EOF
fi

if [ "$MODE" = "stage" ]; then
  log "Arquivos do GitHub Pages preparados localmente. O git_sync fara commit/push depois."
  exit 0
fi

cd "$REPO_ROOT" || exit 0

if ! command -v git >/dev/null 2>&1; then
  log "Git nao instalado. Publicacao local preparada em docs/, mas nao enviada."
  exit 0
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  log "Repositorio Git ainda nao existia. Criando git init..."
  git init >/dev/null 2>&1 || true
fi

git branch -M "$BRANCH_NAME" >/dev/null 2>&1 || true
if [ -n "$REPO_URL" ]; then
  if git remote get-url "$REMOTE_NAME" >/dev/null 2>&1; then
    git remote set-url "$REMOTE_NAME" "$REPO_URL" >/dev/null 2>&1 || true
  else
    git remote add "$REMOTE_NAME" "$REPO_URL" >/dev/null 2>&1 || true
  fi
fi

git config user.name "${PVFIRST_GIT_USER_NAME:-PV-First Collector}" >/dev/null 2>&1 || true
git config user.email "${PVFIRST_GIT_USER_EMAIL:-pvfirst@local}" >/dev/null 2>&1 || true

git add docs index.html controle.html dashboard.html .nojekyll README.md COMO_PUBLICAR_GITHUB.md 2>/dev/null || true
if git diff --cached --quiet --exit-code >/dev/null 2>&1; then
  log "Nada novo para commit depois do git add."
  exit 0
fi

stamp="$(date '+%Y-%m-%d %H:%M:%S')"
git commit -m "Atualiza GitHub Pages PV-First - $stamp" >/dev/null 2>&1 || true

if [ "$MODE" != "push" ]; then
  log "Commit local preparado. Push nao solicitado."
  exit 0
fi

push_output="$(GIT_TERMINAL_PROMPT=0 git push "$REMOTE_NAME" "$BRANCH_NAME" 2>&1)"
if [ $? -ne 0 ]; then
  if printf '%s' "$push_output" | grep -Eqi '407|Proxy Authentication Required'; then
    log "Commit criado, mas o proxy corporativo exige autenticacao (HTTP 407). A chave SSH foi preservada."
  else
    log "Commit criado, mas o push nao terminou agora. Sera tentado novamente depois."
  fi
  exit 0
fi

log "GitHub Pages atualizado com sucesso."
log "Pagina: https://cagdoj.github.io/PhotovoltaicFirst/"
log "Dashboard: https://cagdoj.github.io/PhotovoltaicFirst/dashboard.html"
log "Controle: https://cagdoj.github.io/PhotovoltaicFirst/controle.html"
exit 0


# Garante arquivos do controle remoto via GitHub Pages
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$ROOT_DIR/docs/commands" "$ROOT_DIR/docs/status"
if [ ! -f "$ROOT_DIR/docs/commands/latest.json" ]; then
  cat > "$ROOT_DIR/docs/commands/latest.json" <<'EOF'
{"id":"init","action":"none","created_at":"","from":"init"}
EOF
fi
if [ ! -f "$ROOT_DIR/docs/status/pvfirst_status.json" ]; then
  cat > "$ROOT_DIR/docs/status/pvfirst_status.json" <<'EOF'
{"agent":"ainda nao iniciou","status":"Inicie PVFIRST.bat no PC.","updated_at":""}
EOF
fi
