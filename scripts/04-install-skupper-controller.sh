#!/usr/bin/env bash
# Instala o controller do Skupper (v2.1.1, fixada) nos dois clusters via Helm.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKUPPER_VERSION="2.1.1"

for ctx in "${CTX_A}" "${CTX_B}"; do
  helm upgrade --install skupper oci://quay.io/skupper/helm/skupper \
    --version "${SKUPPER_VERSION}" \
    --namespace "${NS_SKUPPER}" \
    --create-namespace \
    --kube-context "${ctx}"
done

for ctx in "${CTX_A}" "${CTX_B}"; do
  wait_for "controller do Skupper pronto em ${ctx}" \
    "kubectl --context ${ctx} -n ${NS_SKUPPER} rollout status deployment/skupper-controller --timeout=5s" 180 5
done

pass "controller Skupper ${SKUPPER_VERSION} instalado em ${CTX_A} e ${CTX_B}"
