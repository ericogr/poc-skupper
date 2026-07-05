#!/usr/bin/env bash
# Remove tudo que a PoC criou: releases helm, clusters kind, redes docker.
# Idempotente - pode ser rodado mesmo se algum passo anterior falhou.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

helm uninstall skupper -n "${NS_SKUPPER}" --kube-context "${CTX_A}" 2>/dev/null || true
helm uninstall skupper -n "${NS_SKUPPER}" --kube-context "${CTX_B}" 2>/dev/null || true

kind delete cluster --name "${CLUSTER_A}" 2>/dev/null || true
kind delete cluster --name "${CLUSTER_B}" 2>/dev/null || true

docker network rm "${NET_A}" 2>/dev/null || true
docker network rm "${NET_B}" 2>/dev/null || true

rm -rf "${TMP_DIR}"

pass "teardown completo: clusters, releases e redes removidos"
