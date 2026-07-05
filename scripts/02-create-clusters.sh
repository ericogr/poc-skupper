#!/usr/bin/env bash
# Cria os dois clusters kind, cada um preso à sua própria rede docker via
# KIND_EXPERIMENTAL_DOCKER_NETWORK (confirmado como configurável por invocação).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KIND_EXPERIMENTAL_DOCKER_NETWORK="${NET_A}" kind create cluster \
  --name "${CLUSTER_A}" \
  --config "${REPO_ROOT}/kind/skupper-a.kind.yaml"

KIND_EXPERIMENTAL_DOCKER_NETWORK="${NET_B}" kind create cluster \
  --name "${CLUSTER_B}" \
  --config "${REPO_ROOT}/kind/skupper-b.kind.yaml"

# Confirma que cada node foi de fato parar na rede docker esperada (a flag é
# experimental, então validamos em vez de assumir).
net_a_actual="$(docker inspect "${CLUSTER_A}-control-plane" -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}')"
net_b_actual="$(docker inspect "${CLUSTER_B}-control-plane" -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}')"

echo "${net_a_actual}" | grep -qw "${NET_A}" || die "node de A não está em ${NET_A} (está em: ${net_a_actual})"
echo "${net_b_actual}" | grep -qw "${NET_B}" || die "node de B não está em ${NET_B} (está em: ${net_b_actual})"

pass "cluster ${CLUSTER_A} preso a ${NET_A}, cluster ${CLUSTER_B} preso a ${NET_B}"
