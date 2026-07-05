#!/usr/bin/env bash
# Defesa em profundidade além do isolamento de rede: aplica egress-deny em A,
# confirma que o tráfego bidirecional pelo link já estabelecido continua OK,
# e confirma (controle negativo) que A não consegue iniciar conexão NOVA
# para fora do cluster (prova que a policy é real - Calico, não kindnet).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

status=0

kctl_a apply -f "${REPO_ROOT}/networkpolicy/skupper-a-deny-egress.yaml"
sleep 3

log "revalidando e2e bidirecional com egress bloqueado em A"
if bash "${REPO_ROOT}/scripts/09-validate-e2e.sh"; then
  pass "tráfego bidirecional (conexão já estabelecida) sobrevive ao egress-deny em A"
else
  fail "tráfego bidirecional quebrou com egress-deny em A"
  status=1
fi

log "controle negativo: tentando conexão NOVA de dentro de A para um IP público (1.1.1.1)"
egress_out="$(kubectl --context "${CTX_A}" -n "${NS_APP}" run "egresscheck-$$-${RANDOM}" \
  --rm -i --restart=Never --image=curlimages/curl:8.10.1 --command --quiet -- \
  curl -s --max-time 5 -o /dev/null -w '%{http_code}' http://1.1.1.1/ 2>&1 || true)"
log "resultado da tentativa de egress externo: ${egress_out}"

if echo "${egress_out}" | grep -qE '^[0-9]{3}$'; then
  fail "conexão de saída para 1.1.1.1 teve sucesso (egress-deny não está em vigor - CNI não aplica NetworkPolicy?)"
  status=1
else
  pass "conexão de saída para 1.1.1.1 falhou como esperado (egress-deny em vigor via Calico)"
fi

exit "${status}"
