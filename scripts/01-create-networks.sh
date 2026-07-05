#!/usr/bin/env bash
# Cria as duas redes docker isoladas que simulam "internet" entre os clusters.
# Nenhuma delas é conectada uma à outra nem à rede 'kind' padrão - isolamento
# é o comportamento default do Docker para redes diferentes.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for n in "${NET_A}" "${NET_B}"; do
  if docker network inspect "${n}" >/dev/null 2>&1; then
    log "rede ${n} já existe, reaproveitando"
  else
    docker network create "${n}" >/dev/null
    log "rede ${n} criada"
  fi
done

pass "redes docker isoladas prontas: ${NET_A}, ${NET_B}"
