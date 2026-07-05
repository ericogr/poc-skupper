#!/usr/bin/env bash
# Fixa o NodePort dos Services LoadBalancer relevantes de A nos valores
# reservados no extraPortMappings do kind, e resolve manualmente o status
# de LoadBalancer (status.loadBalancer.ingress) para o gateway de
# net-skupper-b - o endereço "público simulado" pelo qual B alcança as
# portas publicadas no host de A.
#
# Dois Services precisam disso:
#  - app/skupper-router (link-access do site: inter-router + edge) -> nodePort
#    fixo em SITE_A_PORT (extraPortMappings hostPort 30671).
#  - skupper/skupper-grant-server (bootstrap do token issue/redeem, componente
#    global do controller, não do site) -> nodePort fixo em SITE_A_GRANT_PORT
#    (extraPortMappings hostPort 30672).
#
# Sem isso, o site nunca fica "Ready"/"Resolved" e 'skupper token issue'
# falha com "there is no active skupper site in this namespace" / "grant ...
# not ready yet" - kind não implementa LoadBalancer de verdade, então nada
# preenche esse status sozinho.
#
# NOTA: o Skupper deriva o host/porta que embute no AccessToken (spec.url) e
# no Link criado durante o redeem a partir de status.loadBalancer.ingress
# (host) + spec.ports[].port do Service (a porta "interna", ex. 55671/9090) -
# NÃO do nodePort. Tentamos inicialmente forçar spec.ports[].port para igualar
# o nodePort, mas o controller do Skupper reconcilia esse campo de volta ao
# valor padrão continuamente (fica em loop infinito de patch/revert). Por
# isso só fixamos o nodePort aqui; a correção da PORTA fica para depois dos
# fatos, em scripts/07-link-clusters.sh (reescrita do token + patch do Link).
#
# O patch mira a porta pelo NOME (não sobrescreve o array inteiro), porque o
# Service pode ter mais de uma porta. Como o controller do Skupper pode
# reconciliar o nodePort do Service e reverter um patch manual, o script
# reaplica em loop até o valor "grudar" (isso não acontece na prática para
# nodePort, só documentando a defesa).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GATEWAY_B="$(docker_network_gateway "${NET_B}")"
[ -n "${GATEWAY_B}" ] || die "não consegui descobrir o gateway de ${NET_B}"
log "gateway de ${NET_B} (endereço 'público' simulado de A, visto por B): ${GATEWAY_B}"

# pin_nodeport <namespace> <service> <porta-preferida-por-nome> <nodePort-alvo>
pin_nodeport() {
  local ns="$1" svc="$2" preferred_name="$3" target_port="$4"

  kctl_a get svc "${svc}" -n "${ns}" -o json > "${TMP_DIR}/${svc}.json"

  local port_name
  port_name="$(jq -r --arg n "${preferred_name}" '.spec.ports[] | select(.name == $n) | .name' "${TMP_DIR}/${svc}.json" | head -n1)"
  if [ -z "${port_name}" ]; then
    port_name="$(jq -r '.spec.ports[0].name' "${TMP_DIR}/${svc}.json")"
    log "porta '${preferred_name}' não encontrada em ${ns}/${svc}, usando a primeira: ${port_name}"
  fi
  local port_index
  port_index="$(jq -r --arg n "${port_name}" '.spec.ports | to_entries[] | select(.value.name == $n) | .key' "${TMP_DIR}/${svc}.json")"

  local attempts=0
  until kctl_a get svc "${svc}" -n "${ns}" -o jsonpath="{.spec.ports[${port_index}].nodePort}" | grep -qx "${target_port}"; do
    attempts=$(( attempts + 1 ))
    (( attempts <= 10 )) || die "não consegui fixar nodePort ${target_port} em ${ns}/${svc} após ${attempts} tentativas"
    log "aplicando patch (tentativa ${attempts}): ${ns}/${svc} porta '${port_name}' -> nodePort ${target_port}"
    kctl_a patch svc "${svc}" -n "${ns}" --type=json \
      -p="[{\"op\":\"replace\",\"path\":\"/spec/ports/${port_index}/nodePort\",\"value\":${target_port}}]" \
      || true
    sleep 3
  done
  pass "${ns}/${svc}: porta '${port_name}' fixada em nodePort ${target_port}"
}

# resolve_loadbalancer <namespace> <service> <ip>
resolve_loadbalancer() {
  local ns="$1" svc="$2" ip="$3"
  kctl_a patch svc "${svc}" -n "${ns}" --subresource=status --type=merge \
    -p "{\"status\":{\"loadBalancer\":{\"ingress\":[{\"ip\":\"${ip}\"}]}}}"
  pass "${ns}/${svc}: status.loadBalancer.ingress resolvido manualmente para ${ip}"
}

pin_nodeport "${NS_APP}" skupper-router inter-router "${SITE_A_PORT}"
resolve_loadbalancer "${NS_APP}" skupper-router "${GATEWAY_B}"

pin_nodeport "${NS_SKUPPER}" skupper-grant-server https "${SITE_A_GRANT_PORT}"
resolve_loadbalancer "${NS_SKUPPER}" skupper-grant-server "${GATEWAY_B}"

wait_for "site-a reportando status Ready" \
  "kubectl --context ${CTX_A} -n ${NS_APP} get site site-a -o jsonpath='{.status.status}' | grep -qi ready" 60 3

pass "endpoints de A resolvidos e publicados via extraPortMappings do kind"
