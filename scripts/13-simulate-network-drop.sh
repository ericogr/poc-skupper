#!/usr/bin/env bash
# Simula queda de rede desconectando o node de B da sua rede docker (operação
# padrão do Docker CLI sobre um container da própria PoC - não altera a rede
# do host) e mede o tempo até o link se reconectar automaticamente.
#
# O recurso Link vive no lado que resgatou o token (B, que iniciou o link) -
# por isso o status é sempre consultado via contexto B, nunca A (A não tem
# recurso Link nenhum, é exatamente o requisito de unidirecionalidade).
#
# Efeito colateral aceito: durante a queda, kubectl/skupper no contexto B
# também ficam inacessíveis (a única interface de rede do node foi removida).
# Isso é esperado e documentado no README.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NODE_B="${CLUSTER_B}-control-plane"

log "estado do link antes da queda:"
skupper_b link status

log "desconectando ${NODE_B} de ${NET_B} (simulando queda de rede de B)"
drop_ts=$(date +%s)
docker network disconnect "${NET_B}" "${NODE_B}"

sleep 5
log "durante a queda, contexto B fica inacessível (esperado - única rede do node removida):"
skupper_b link status 2>&1 || true

log "reconectando ${NODE_B} a ${NET_B}"
docker network connect "${NET_B}" "${NODE_B}"
reconnect_ts=$(date +%s)

# Checa a condição "Operational" (não só "status.status", que fica com
# cache de "Ready" por um instante enquanto o router ainda está re-discando)
# para não validar em cima de um status momentaneamente desatualizado.
wait_for "link voltando a Operational=True após reconexão" \
  "kubectl --context ${CTX_B} -n ${NS_APP} get link -o jsonpath='{.items[0].status.conditions[?(@.type==\"Operational\")].status}' | grep -qi true" 180 3
recovered_ts=$(date +%s)

log "tempo total desconectado (rede): $(( reconnect_ts - drop_ts ))s"
log "tempo até o link reportar 'Ready' de novo após reconexão de rede: $(( recovered_ts - reconnect_ts ))s"

skupper_b link status

# O status do Link pode reportar Operational=True um instante antes do
# plano de dados (rotas inter-router recém recomputadas) estar de fato
# pronto para encaminhar tráfego de aplicação - por isso o e2e é checado em
# retry curto, não como uma falha definitiva na primeira tentativa.
e2e_attempts=0
until bash "${REPO_ROOT}/scripts/09-validate-e2e.sh"; do
  e2e_attempts=$(( e2e_attempts + 1 ))
  (( e2e_attempts <= 5 )) || die "e2e continua falhando ${e2e_attempts} tentativas após o link voltar a Operational"
  log "e2e ainda falhando logo após reconexão (tentativa ${e2e_attempts}), tentando de novo em 3s"
  sleep 3
done

pass "reconexão automática confirmada após queda de rede simulada"
