#!/usr/bin/env bash
# Prova o requisito central: cada cluster expõe um serviço consumido pelo
# outro, com uma ligação estabelecida só num sentido (B->A).
# Imprime PASS/FAIL por verificação e sai != 0 se alguma falhar.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

status=0

curl_from() {
  local ctx="$1" svc="$2"
  kubectl --context "${ctx}" -n "${NS_APP}" run "curltest-$$-${RANDOM}" \
    --rm -i --restart=Never --image=curlimages/curl:8.10.1 --command --quiet -- \
    curl -s --max-time 5 "http://${svc}:8080/" 2>/dev/null
}

check() {
  local desc="$1" out="$2" expect="$3"
  if echo "${out}" | grep -q "${expect}"; then
    pass "${desc} (resposta: '${out}')"
  else
    fail "${desc} (esperado '${expect}', recebido: '${out}')"
    status=1
  fi
}

log "chamando svc-a a partir de B (deve chegar em echo-a)"
out_b_to_a="$(curl_from "${CTX_B}" svc-a || true)"
check "B -> svc-a -> echo-a" "${out_b_to_a}" "hello from A"

log "chamando svc-b a partir de A (deve chegar em echo-b)"
out_a_to_b="$(curl_from "${CTX_A}" svc-b || true)"
check "A -> svc-b -> echo-b" "${out_a_to_b}" "hello from B"

exit "${status}"
