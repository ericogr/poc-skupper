#!/usr/bin/env bash
# Helpers compartilhados por todos os scripts da PoC.
# Uso: source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="${REPO_ROOT}/.tmp"
mkdir -p "${TMP_DIR}"

CTX_A="kind-skupper-a"
CTX_B="kind-skupper-b"
CLUSTER_A="skupper-a"
CLUSTER_B="skupper-b"
NET_A="net-skupper-a"
NET_B="net-skupper-b"
SITE_A_PORT=30671
SITE_A_GRANT_PORT=30672
NS_SKUPPER="skupper"
NS_APP="app"

log()  { echo "[$(date '+%H:%M:%S')] $*" >&2; }
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; }
die()  { log "ERRO: $*"; exit 1; }

# Espera até que $1 (comando via bash -c) tenha sucesso, tentando por até
# $2 segundos (padrão 120), dormindo $3 segundos entre tentativas (padrão 3).
wait_for() {
  local desc="$1" cmd="$2" timeout="${3:-120}" interval="${4:-3}"
  local waited=0
  log "aguardando: ${desc}"
  until bash -c "${cmd}" >/dev/null 2>&1; do
    if (( waited >= timeout )); then
      die "timeout (${timeout}s) esperando: ${desc}"
    fi
    sleep "${interval}"
    waited=$(( waited + interval ))
  done
  log "ok: ${desc} (${waited}s)"
}

kctl_a() { kubectl --context "${CTX_A}" "$@"; }
kctl_b() { kubectl --context "${CTX_B}" "$@"; }
skupper_a() { skupper --context "${CTX_A}" -n "${NS_APP}" "$@"; }
skupper_b() { skupper --context "${CTX_B}" -n "${NS_APP}" "$@"; }

# Gateway pelo qual containers na rede docker $1 alcançam portas publicadas
# no host (equivalente ao "IP público" simulado).
docker_network_gateway() {
  docker network inspect "$1" -f '{{(index .IPAM.Config 0).Gateway}}'
}
