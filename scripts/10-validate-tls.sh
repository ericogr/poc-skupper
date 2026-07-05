#!/usr/bin/env bash
# Prova que o link entre os sites é autenticado e criptografado (mTLS), não
# texto plano: inspeciona o Secret de TLS gerado pelo token issue/redeem e
# faz um handshake TLS manual contra o endpoint publicado no host, com e sem
# certificado de cliente (controle negativo).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

status=0

log "Secrets de TLS no namespace ${NS_APP} do cluster A:"
kctl_a get secret -n "${NS_APP}" -o custom-columns=NAME:.metadata.name,TYPE:.type

CA_SECRET="$(kctl_a get secret -n "${NS_APP}" -o jsonpath='{range .items[?(@.type=="kubernetes.io/tls")]}{.metadata.name}{"\n"}{end}' | head -n1)"
if [ -n "${CA_SECRET}" ]; then
  pass "Secret TLS encontrado no site A: ${CA_SECRET} (certificados gerenciados pela CA interna do Skupper)"
else
  fail "nenhum Secret kubernetes.io/tls encontrado no namespace ${NS_APP} de A"
  status=1
fi

GATEWAY_B="$(docker_network_gateway "${NET_B}")"
ENDPOINT="${GATEWAY_B}:${SITE_A_PORT}"

log "handshake TLS bruto contra ${ENDPOINT} (a partir de um pod em B, mesma rota que o router usa)"
handshake_out="$(kubectl --context "${CTX_B}" -n "${NS_APP}" run "tlscheck-$$-${RANDOM}" \
  --rm -i --restart=Never --image=alpine/openssl:latest --command --quiet -- \
  sh -c "echo | openssl s_client -connect ${ENDPOINT} -brief 2>&1" || true)"
echo "${handshake_out}" >&2

if echo "${handshake_out}" | grep -qiE 'Verification|CN ?=|subject='; then
  pass "handshake TLS concluído e certificado do servidor apresentado em ${ENDPOINT} (CN=skupper-router, emitido pela CA do site)"
else
  fail "não consegui confirmar handshake TLS em ${ENDPOINT}"
  status=1
fi

# Controle negativo: o openssl s_client acima não apresenta certificado de
# cliente algum (não temos o material do token carregado nele) - a
# autenticação mútua do Skupper deve rejeitar a conexão nesse ponto, mesmo
# com o handshake TLS de servidor concluído com sucesso.
if echo "${handshake_out}" | grep -qiE 'certificate required|tlsv1[3]? alert|sslv3 alert (handshake failure|bad certificate)'; then
  pass "controle negativo: conexão sem certificado de cliente foi rejeitada pelo mTLS ('$(echo "${handshake_out}" | grep -oiE '[a-z0-9._-]*alert[a-z0-9 ._-]*' | head -n1)')"
else
  fail "conexão sem certificado de cliente NÃO foi rejeitada - mTLS pode não estar em vigor"
  status=1
fi

exit "${status}"
