#!/usr/bin/env bash
# TESTE DESTRUTIVO - roda por último de propósito. Revoga o link e confirma
# que os dois serviços perdem rota (ambos os curls passam a falhar).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINK_NAME="$(kctl_b get link -n "${NS_APP}" -o jsonpath='{.items[0].metadata.name}')"
[ -n "${LINK_NAME}" ] || die "nenhum link encontrado no contexto B para revogar"

log "revogando link '${LINK_NAME}' (a partir de B, quem o iniciou)"
skupper_b link delete "${LINK_NAME}"

wait_for "link removido do status em B" \
  "! kubectl --context ${CTX_B} -n ${NS_APP} get link ${LINK_NAME}" 60 3

status=0
log "confirmando que o tráfego bidirecional agora falha (esperado)"
if bash "${REPO_ROOT}/scripts/09-validate-e2e.sh"; then
  fail "tráfego bidirecional continuou funcionando mesmo após revogar o link (esperado: falhar)"
  status=1
else
  pass "tráfego bidirecional falhou nos dois sentidos após a revogação, como esperado"
fi

exit "${status}"
