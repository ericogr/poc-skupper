#!/usr/bin/env bash
# Instala Calico (Tigera operator) só no cluster A, que subiu com
# disableDefaultCNI: true e podSubnet 192.168.0.0/16 - o mesmo CIDR default
# do manifesto oficial de custom-resources do Calico.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CALICO_VERSION="v3.32.1"
OPERATOR_URL="https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"
CR_URL="https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/custom-resources.yaml"

kctl_a apply -f "${OPERATOR_URL}"
wait_for "tigera-operator disponível" \
  "kubectl --context ${CTX_A} -n tigera-operator rollout status deployment/tigera-operator --timeout=5s"

wait_for "CRDs do tigera-operator estabelecidas" \
  "kubectl --context ${CTX_A} get crd installations.operator.tigera.io" 60 3

# A aplicação pode falhar transitoriamente logo após o operator subir, se as
# CRDs ainda não terminaram de propagar no apiserver - reaplica em loop.
attempts=0
until kctl_a apply -f "${CR_URL}"; do
  attempts=$(( attempts + 1 ))
  (( attempts <= 10 )) || die "falha ao aplicar custom-resources do Calico após ${attempts} tentativas"
  log "custom-resources do Calico falhou (tentativa ${attempts}), tentando de novo em 5s"
  sleep 5
done

wait_for "nós do cluster A prontos (CNI Calico funcionando)" \
  "kubectl --context ${CTX_A} wait --for=condition=Ready node --all --timeout=5s" 300 5

wait_for "todos os pods de calico-system prontos" \
  "kubectl --context ${CTX_A} -n calico-system wait --for=condition=Ready pod --all --timeout=5s" 300 5

kctl_a get pods -n calico-system

pass "Calico instalado em ${CLUSTER_A} (CNI real, suporta NetworkPolicy)"
