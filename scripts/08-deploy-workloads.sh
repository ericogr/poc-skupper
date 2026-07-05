#!/usr/bin/env bash
# Deploy bidirecional: cada cluster roda seu próprio echo e expõe o do outro.
# Routing-keys diferentes (svc-a, svc-b) evitam colisão já que os dois lados
# têm connector *e* listener ao mesmo tempo.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

kctl_a apply -f "${REPO_ROOT}/workload/echo-a.deployment.yaml"
kctl_b apply -f "${REPO_ROOT}/workload/echo-b.deployment.yaml"

wait_for "echo-a pronto em A" \
  "kubectl --context ${CTX_A} -n ${NS_APP} rollout status deployment/echo-a --timeout=5s" 120 5
wait_for "echo-b pronto em B" \
  "kubectl --context ${CTX_B} -n ${NS_APP} rollout status deployment/echo-b --timeout=5s" 120 5

# Lado A: expõe echo-a (svc-a) para B, e consome svc-b vindo de B.
skupper_a connector create svc-a 8080 --workload deployment/echo-a
skupper_a listener create svc-b 8080

# Lado B: expõe echo-b (svc-b) para A, e consome svc-a vindo de A.
skupper_b connector create svc-b 8080 --workload deployment/echo-b
skupper_b listener create svc-a 8080

wait_for "listener svc-a pronto em B" \
  "kubectl --context ${CTX_B} -n ${NS_APP} get listener svc-a -o jsonpath='{.status.status}' | grep -qi ready" 60 3
wait_for "listener svc-b pronto em A" \
  "kubectl --context ${CTX_A} -n ${NS_APP} get listener svc-b -o jsonpath='{.status.status}' | grep -qi ready" 60 3

pass "workloads e connectors/listeners bidirecionais no ar (svc-a e svc-b)"
