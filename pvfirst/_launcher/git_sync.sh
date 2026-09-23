#!/usr/bin/env bash

# Sincronizacao Git do PV-First.
# Mantem o repositorio na raiz PVFIRST_VISUAL_V38, porque docs/, index.html
# e os arquivos do GitHub Pages ficam um nivel acima da pasta pvfirst/.
# Falhas de internet/SSH nunca derrubam a coleta.

set +e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$PROJECT_DIR"
if [ -d "$PROJECT_DIR/../docs" ] || [ -f "$PROJECT_DIR/../index.html" ] || [ -d "$PROJECT_DIR/../.git" ]; then
  REPO_ROOT="$(cd "$PROJECT_DIR/.." && pwd)"
fi

if [ "$REPO_ROOT" = "$PROJECT_DIR" ]; then
  PROJECT_REL="."
else
  PROJECT_REL="pvfirst"
fi

mkdir -p "$PROJECT_DIR/results" "$PROJECT_DIR/dashboard" "$REPO_ROOT/docs"
GIT_LOG="$PROJECT_DIR/git_sync.log"
SYNC_STATUS="$REPO_ROOT/_interno/git_last_status.txt"

if [ -f "$PROJECT_DIR/config/pvfirst.env" ]; then
  # shellcheck disable=SC1091
  source <(sed 's/\r$//' "$PROJECT_DIR/config/pvfirst.env")
fi

# Proxy detectado pelo launcher Windows. Exporta para curl/git/ssh helpers.
if [ "${PVFIRST_PROXY_AUTO:-0}" = "1" ] && [ -n "${PVFIRST_PROXY_URL:-}" ]; then
  export http_proxy="$PVFIRST_PROXY_URL" https_proxy="$PVFIRST_PROXY_URL"
  export HTTP_PROXY="$PVFIRST_PROXY_URL" HTTPS_PROXY="$PVFIRST_PROXY_URL"
  export no_proxy="${PVFIRST_NO_PROXY:-localhost,127.0.0.1,::1,.intraer}"
  export NO_PROXY="$no_proxy"
fi

MODE="${1:-auto}"
AUTO_PUSH="${PVFIRST_GIT_AUTO_PUSH:-1}"
REMOTE_NAME="${PVFIRST_GIT_REMOTE:-origin}"
BRANCH_NAME="${PVFIRST_GIT_BRANCH:-main}"
REPO_URL="${PVFIRST_GIT_REPO_URL:-git@github.com:CAGDOJ/PhotovoltaicFirst.git}"
COMMIT_PREFIX="${PVFIRST_GIT_COMMIT_PREFIX:-Atualiza resultados PV-First}"
USER_NAME="${PVFIRST_GIT_USER_NAME:-PV-First Collector}"
USER_EMAIL="${PVFIRST_GIT_USER_EMAIL:-pvfirst@local}"

log() {
  msg="[Git] $*"
  echo "$msg"
  printf '%s\n' "$msg" >> "$GIT_LOG" 2>/dev/null || true
}
set_sync_status() {
  mkdir -p "$(dirname "$SYNC_STATUS")" 2>/dev/null || true
  printf '%s\n' "$*" > "$SYNC_STATUS" 2>/dev/null || true
}

count_results() {
  find "$PROJECT_DIR/results" -type f -name "*.csv" 2>/dev/null | wc -l | tr -d " "
}

last_result() {
  find "$PROJECT_DIR/results" -type f -name "*.csv" -printf "%T@ %p\n" 2>/dev/null | sort -nr | head -1 | cut -d" " -f2-
}

is_git_repo() {
  cd "$REPO_ROOT" || return 1
  git rev-parse --is-inside-work-tree >/dev/null 2>&1
}

internet_ok() {
  cd "$REPO_ROOT" || return 1
  GIT_TERMINAL_PROMPT=0 timeout 15 git ls-remote "$REMOTE_NAME" HEAD >/dev/null 2>&1
}

ensure_repo() {
  if ! command -v git >/dev/null 2>&1; then
    log "Git nao esta instalado neste WSL. Rode Verificar ambiente."
    return 1
  fi

  cd "$REPO_ROOT" || return 1

  if ! is_git_repo; then
    log "Repositorio Git ainda nao existia na raiz. Criando git init..."
    git init >/dev/null 2>&1 || return 1
  fi

  git branch -M "$BRANCH_NAME" >/dev/null 2>&1 || true

  if [ -n "$REPO_URL" ]; then
    if git remote get-url "$REMOTE_NAME" >/dev/null 2>&1; then
      current_url="$(git remote get-url "$REMOTE_NAME" 2>/dev/null)"
      if [ "$current_url" != "$REPO_URL" ]; then
        log "Atualizando remote $REMOTE_NAME para a URL configurada."
        git remote set-url "$REMOTE_NAME" "$REPO_URL" >/dev/null 2>&1 || true
      fi
    else
      log "Adicionando remote $REMOTE_NAME."
      git remote add "$REMOTE_NAME" "$REPO_URL" >/dev/null 2>&1 || true
    fi
  fi

  git config user.name "$USER_NAME" >/dev/null 2>&1 || true
  git config user.email "$USER_EMAIL" >/dev/null 2>&1 || true
  return 0
}

track_paths() {
  TRACK_PATHS=()
  [ -e "$REPO_ROOT/docs" ] && TRACK_PATHS+=("docs")
  [ -e "$REPO_ROOT/index.html" ] && TRACK_PATHS+=("index.html")
  [ -e "$REPO_ROOT/.nojekyll" ] && TRACK_PATHS+=(".nojekyll")
  [ -e "$REPO_ROOT/controle.html" ] && TRACK_PATHS+=("controle.html")
  [ -e "$REPO_ROOT/dashboard.html" ] && TRACK_PATHS+=("dashboard.html")
  [ -e "$REPO_ROOT/README.md" ] && TRACK_PATHS+=("README.md")
  [ -e "$REPO_ROOT/COMO_PUBLICAR_GITHUB.md" ] && TRACK_PATHS+=("COMO_PUBLICAR_GITHUB.md")
  [ -e "$PROJECT_DIR/results" ] && TRACK_PATHS+=("$PROJECT_REL/results")
  [ -e "$PROJECT_DIR/dashboard/pvfirst_dashboard.html" ] && TRACK_PATHS+=("$PROJECT_REL/dashboard/pvfirst_dashboard.html")
}

show_status() {
  total="$(count_results)"
  last="$(last_result)"

  log "Raiz Git: $REPO_ROOT"
  log "Resultados CSV encontrados: $total"
  if [ -n "$last" ]; then
    log "Arquivo de resultado mais recente: $last"
  else
    log "Nenhum CSV encontrado em results ainda."
  fi

  if ! command -v git >/dev/null 2>&1; then
    log "Git nao esta instalado neste WSL."
    return 0
  fi

  ensure_repo >/dev/null 2>&1
  if ! is_git_repo; then
    log "Repositorio Git nao configurado."
    return 0
  fi

  cd "$REPO_ROOT" || return 0
  track_paths
  if [ ${#TRACK_PATHS[@]} -gt 0 ]; then
    pending="$(git status --porcelain -- "${TRACK_PATHS[@]}" 2>/dev/null)"
  else
    pending=""
  fi

  if [ -z "$pending" ]; then
    log "Nenhum resultado/painel novo ou alterado para enviar."
  else
    log "Resultados/arquivos pendentes para envio:"
    echo "$pending" | sed "s/^/[Git]   /"
    echo "$pending" | sed "s/^/[Git]   /" >> "$GIT_LOG" 2>/dev/null || true
  fi

  git remote -v 2>/dev/null | sed "s/^/[Git] Remote: /"

  remote_url="$(git remote get-url "$REMOTE_NAME" 2>/dev/null)"
  if echo "$remote_url" | grep -q "^git@github.com:"; then
    log "Remote SSH GitHub configurado. Este WSL precisa ter chave SSH autorizada para fazer push."
  fi

  if internet_ok; then
    log "Internet para GitHub: OK"
  else
    log "Internet para GitHub: indisponivel agora"
  fi
}

push_results() {
  if [ "$AUTO_PUSH" != "1" ] && [ "$MODE" = "auto" ]; then
    log "Envio automatico ao Git esta desligado em config/pvfirst.env."
    return 0
  fi

  if ! ensure_repo; then
    return 0
  fi

  show_status
  cd "$REPO_ROOT" || return 0
  track_paths

  if [ ${#TRACK_PATHS[@]} -eq 0 ]; then
    log "Nenhum arquivo rastreavel encontrado."
    return 0
  fi

  pending="$(git status --porcelain -- "${TRACK_PATHS[@]}" 2>/dev/null)"
  if [ -z "$pending" ]; then
    log "Sem mudancas. Nenhum commit criado."
    return 0
  fi

  if ! internet_ok; then
    log "Sem internet para GitHub."
    log "A coleta continua normalmente. O envio sera tentado depois."
    set_sync_status "OFFLINE|Sem internet para GitHub"
    return 30
  fi

  git add -A -- "${TRACK_PATHS[@]}" >/dev/null 2>&1 || true

  if git diff --cached --quiet --exit-code >/dev/null 2>&1; then
    log "Nada novo para commit depois do git add."
    return 0
  fi

  stamp="$(date '+%Y-%m-%d %H:%M:%S')"
  git commit -m "$COMMIT_PREFIX - $stamp" >/dev/null 2>&1
  if [ $? -ne 0 ]; then
    log "Nao consegui criar commit. A coleta continua normalmente."
    return 0
  fi

  if [ -z "$(git remote get-url "$REMOTE_NAME" 2>/dev/null)" ]; then
    log "Commit criado localmente, mas remote $REMOTE_NAME nao esta configurado."
    return 0
  fi

  push_output="$(GIT_TERMINAL_PROMPT=0 git push "$REMOTE_NAME" "$BRANCH_NAME" 2>&1)"
  push_code=$?
  if [ $push_code -ne 0 ]; then
    log "FALHA NO ENVIO AO GITHUB."
    printf '%s\n' "$push_output" | sed 's/^/[Git]   /'
    printf '%s\n' "$push_output" >> "$GIT_LOG" 2>/dev/null || true
    if printf '%s' "$push_output" | grep -Eqi '407|Proxy Authentication Required'; then
      log "MOTIVO: proxy corporativo exige autenticacao HTTP 407. A chave SSH nao sera alterada."
      set_sync_status "PROXY_AUTH_REQUIRED|Proxy corporativo exige autenticacao"
    elif printf '%s' "$push_output" | grep -Eqi 'Permission denied|publickey|Authentication failed'; then
      log "MOTIVO: autenticacao SSH do GitHub falhou. A chave existente foi preservada."
      set_sync_status "AUTH_REQUIRED|Falha de autenticacao SSH no GitHub"
    else
      set_sync_status "PUSH_FAILED|$push_output"
    fi
    log "O CSV ficou salvo localmente e sera tentado novamente depois."
    return 31
  fi

  log "ENVIADO AO GITHUB COM SUCESSO."
  log "GitHub Pages: https://cagdoj.github.io/PhotovoltaicFirst/"
  set_sync_status "OK|Resultados enviados ao GitHub em $(date '+%Y-%m-%d %H:%M:%S')"
  return 0
}

case "$MODE" in
  status)
    show_status
    ;;
  push|auto)
    push_results
    ;;
  *)
    log "Modo desconhecido: $MODE"
    ;;
esac

exit 0
