#!/usr/bin/env bash
# Gera um token de acesso em A, reescreve a porta do endpoint de bootstrap
# (grant server) embutida no token, resgata o token em B, e corrige a porta
# do link inter-router para o NodePort realmente publicado no host.
#
# Contexto (ver docs/v1-to-v2-mapping.md e comentários em
# scripts/06-pin-site-nodeport.sh): o Skupper deriva host/porta que embute no
# AccessToken (spec.url) e no Link criado durante o redeem a partir de
# status.loadBalancer.ingress (host, que já resolvemos manualmente) + de
# spec.ports[].port do Service (porta "interna" do cluster, não o NodePort
# publicado no host) - e o controller reconcilia esse "port" de volta sempre
# que tentamos sobrescrevê-lo no Service. Por isso a correção de porta
# acontece em dois lugares, depois dos fatos:
#   1. no arquivo de token local (campo spec.url, usado só para o bootstrap
#      HTTP do grant server) - antes do redeem;
#   2. no objeto Link já criado em B (campo spec.endpoints[].port, usado
#      para o link inter-router de verdade) - depois do redeem. Este último
#      não é recomputado a partir de A (não há canal entre os clusters além
#      do próprio link), então o patch é estável; só é preciso reiniciar o
#      router de B (rollout restart) para ele reler o ConfigMap gerado a
#      partir do Link corrigido.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOKEN_FILE="${TMP_DIR}/site-a-token.yaml"
rm -f "${TOKEN_FILE}"

skupper_a token issue "${TOKEN_FILE}"
[ -s "${TOKEN_FILE}" ] || die "token não foi gerado em ${TOKEN_FILE}"

# Endpoint publicado no host de A (ver 06-pin-site-nodeport.sh): o token já
# embute o host certo (gateway de net-skupper-b, resolvido manualmente no
# Service), só a porta do grant-server precisa virar o NodePort publicado.
sed -i "s#:9090/#:${SITE_A_GRANT_PORT}/#" "${TOKEN_FILE}"
log "token reescrito (porta do grant server -> ${SITE_A_GRANT_PORT}):"
grep '^  url:' "${TOKEN_FILE}" >&2

skupper_b token redeem "${TOKEN_FILE}"

LINK_NAME="$(kctl_b get link -n "${NS_APP}" -o jsonpath='{.items[0].metadata.name}')"
[ -n "${LINK_NAME}" ] || die "link não foi criado em B após o redeem"

# Porta real do Service de A por nome de porta (nodePort, o único publicado
# no host) - usado para corrigir o Link criado por B.
INTER_ROUTER_NODEPORT="$(kctl_a get svc skupper-router -n "${NS_APP}" -o jsonpath='{.spec.ports[?(@.name=="inter-router")].nodePort}')"
EDGE_NODEPORT="$(kctl_a get svc skupper-router -n "${NS_APP}" -o jsonpath='{.spec.ports[?(@.name=="edge")].nodePort}')"

log "corrigindo portas do Link '${LINK_NAME}' em B: inter-router->${INTER_ROUTER_NODEPORT}, edge->${EDGE_NODEPORT}"
kctl_b get link "${LINK_NAME}" -n "${NS_APP}" -o json > "${TMP_DIR}/link.json"
EDGE_IDX="$(jq -r '.spec.endpoints | to_entries[] | select(.value.name=="edge") | .key' "${TMP_DIR}/link.json")"
INTER_IDX="$(jq -r '.spec.endpoints | to_entries[] | select(.value.name=="inter-router") | .key' "${TMP_DIR}/link.json")"

kctl_b patch link "${LINK_NAME}" -n "${NS_APP}" --type=json -p="[
  {\"op\":\"replace\",\"path\":\"/spec/endpoints/${EDGE_IDX}/port\",\"value\":\"${EDGE_NODEPORT}\"},
  {\"op\":\"replace\",\"path\":\"/spec/endpoints/${INTER_IDX}/port\",\"value\":\"${INTER_ROUTER_NODEPORT}\"}
]"

# O router de B só relê o ConfigMap gerado a partir do Link corrigido depois
# de reiniciar (o kubelet demora a propagar o ConfigMap montado, e o
# processo do router não faz watch ativo do arquivo).
kctl_b rollout restart deployment/skupper-router -n "${NS_APP}"
wait_for "skupper-router de B reiniciado com a config corrigida" \
  "kubectl --context ${CTX_B} -n ${NS_APP} rollout status deployment/skupper-router --timeout=5s" 120 5

wait_for "link '${LINK_NAME}' reportando 'Ready'/OK em B" \
  "kubectl --context ${CTX_B} -n ${NS_APP} get link ${LINK_NAME} -o jsonpath='{.status.status}' | grep -qi ready" 120 3

skupper_b link status
skupper_a link status

pass "link estabelecido entre site-a e site-b (iniciado por B, conforme requisito de unidirecionalidade)"
