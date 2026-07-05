#!/usr/bin/env bash
# Mede latência cross-cluster (via link Skupper) vs. local (mesmo cluster),
# e uso de CPU/mem dos routers. Roda com o link ainda ativo - por isso vem
# antes dos testes destrutivos/disruptivos.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

METRICS_SERVER_URL="https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml"
TS="$(date +%Y%m%d-%H%M%S)"
CSV="${REPO_ROOT}/metrics/results-${TS}.csv"
N_REQUESTS=20

install_metrics_server() {
  local ctx="$1"
  if kubectl --context "${ctx}" -n kube-system get deployment metrics-server >/dev/null 2>&1; then
    log "metrics-server já instalado em ${ctx}"
    return
  fi
  kubectl --context "${ctx}" apply -f "${METRICS_SERVER_URL}"
  kubectl --context "${ctx}" -n kube-system patch deployment metrics-server --type=json -p='[
    {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}
  ]'
  wait_for "metrics-server pronto em ${ctx}" \
    "kubectl --context ${ctx} -n kube-system rollout status deployment/metrics-server --timeout=5s" 180 5
}

install_metrics_server "${CTX_A}"
install_metrics_server "${CTX_B}"

measure() {
  local ctx="$1" ns="$2" target="$3" label="$4"
  local times=()
  for _ in $(seq 1 "${N_REQUESTS}"); do
    t="$(kubectl --context "${ctx}" -n "${ns}" run "metrics-$$-${RANDOM}" \
      --rm -i --restart=Never --image=curlimages/curl:8.10.1 --command --quiet -- \
      curl -s -o /dev/null -w '%{time_total}' --max-time 5 "http://${target}:8080/" 2>/dev/null || echo "")"
    [ -n "${t}" ] && times+=("${t}")
  done
  if [ "${#times[@]}" -eq 0 ]; then
    log "sem amostras válidas para ${label}"
    return
  fi
  printf '%s\n' "${times[@]}" | sort -n | awk -v label="${label}" '
    { a[NR]=$1 }
    END {
      p50 = a[int(NR*0.5)+1]; p99 = a[int(NR*0.99)+1 > NR ? NR : int(NR*0.99)+1];
      printf "%s,%d,%s,%s\n", label, NR, p50, p99
    }' >> "${CSV}"
}

echo "label,amostras,p50_s,p99_s" > "${CSV}"

log "medindo latência local em B (echo-b direto, mesmo cluster)"
measure "${CTX_B}" "${NS_APP}" echo-b "local-B-to-echo-b"

log "medindo latência cross-cluster B -> svc-a (via link Skupper)"
measure "${CTX_B}" "${NS_APP}" svc-a "cross-B-to-svc-a"

log "medindo latência local em A (echo-a direto, mesmo cluster)"
measure "${CTX_A}" "${NS_APP}" echo-a "local-A-to-echo-a"

log "medindo latência cross-cluster A -> svc-b (via link Skupper)"
measure "${CTX_A}" "${NS_APP}" svc-b "cross-A-to-svc-b"

log "uso de CPU/mem do skupper-router:"
{
  echo "--- router A ---"
  kubectl --context "${CTX_A}" -n "${NS_APP}" top pod -l app.kubernetes.io/name=skupper-router 2>&1 || true
  echo "--- router B ---"
  kubectl --context "${CTX_B}" -n "${NS_APP}" top pod -l app.kubernetes.io/name=skupper-router 2>&1 || true
} | tee -a "${CSV}.top.txt"

pass "métricas coletadas em ${CSV}"
