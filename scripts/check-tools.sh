#!/usr/bin/env bash
# Preflight de ferramentas: confere se todos os binários de host exigidos
# pela PoC estão instalados, ANTES de qualquer outro script rodar. Ao
# contrário de um simples "die na primeira ausência", varre a lista
# inteira e reporta TODAS as ferramentas faltando de uma vez, cada uma com
# orientação de como instalar - para o usuário não precisar rodar `make`
# várias vezes só para descobrir a próxima dependência ausente.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

declare -A INSTALL_HINT=(
  [docker]="https://docs.docker.com/engine/install/ (Ubuntu/Debian: 'sudo apt install docker.io'; ou Docker Desktop)"
  [kind]="https://kind.sigs.k8s.io/docs/user/quick-start/#installation (ex.: 'go install sigs.k8s.io/kind@latest', ou baixe o binário do release)"
  [kubectl]="https://kubernetes.io/docs/tasks/tools/#kubectl (Ubuntu/Debian: 'sudo apt install kubectl', ou curl do release oficial)"
  [helm]="https://helm.sh/docs/intro/install/ (ex.: 'curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash')"
  [skupper]="https://skupper.io/install/ (ex.: 'curl https://skupper.io/install.sh | sh')"
  [jq]="https://jqlang.github.io/jq/download/ (Ubuntu/Debian: 'sudo apt install jq'; macOS: 'brew install jq')"
)

# Ordem fixa (não a ordem de iteração de um array associativo) para a saída
# ser sempre estável e previsível.
REQUIRED_TOOLS=(docker kind kubectl helm skupper jq)

missing=()
for bin in "${REQUIRED_TOOLS[@]}"; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    missing+=("${bin}")
    continue
  fi
  case "${bin}" in
    docker)  log "docker:  $(docker --version)" ;;
    kind)    log "kind:    $(kind --version)" ;;
    kubectl) log "kubectl: $(kubectl version --client 2>&1 | tr '\n' ' ')" ;;
    helm)    log "helm:    $(helm version --short 2>&1 || helm version)" ;;
    skupper) log "skupper: $(skupper version 2>&1 | tr '\n' ' ')" ;;
    jq)      log "jq:      $(jq --version)" ;;
  esac
done

if [ "${#missing[@]}" -gt 0 ]; then
  log "ERRO: ${#missing[@]} ferramenta(s) obrigatória(s) não encontrada(s) no PATH:"
  for bin in "${missing[@]}"; do
    log "  - ${bin}: não encontrado. Instale em: ${INSTALL_HINT[${bin}]}"
  done
  die "instale as ferramentas listadas acima e rode 'make preflight' de novo para confirmar"
fi

pass "preflight de ferramentas ok - todas presentes: ${REQUIRED_TOOLS[*]}"
