#!/usr/bin/env bash
# Confere ferramentas (delega a scripts/check-tools.sh) e ausência de
# colisão de nomes antes de criar nada.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

"$(dirname "${BASH_SOURCE[0]}")/check-tools.sh"

for c in "${CLUSTER_A}" "${CLUSTER_B}"; do
  if kind get clusters 2>/dev/null | grep -qx "${c}"; then
    die "já existe um cluster kind chamado '${c}' - remova antes (kind delete cluster --name ${c}) ou rode 'make down'"
  fi
done

for n in "${NET_A}" "${NET_B}"; do
  if docker network inspect "${n}" >/dev/null 2>&1; then
    die "já existe uma rede docker chamada '${n}' - remova antes (docker network rm ${n}) ou rode 'make down'"
  fi
done

if ss -ltn 2>/dev/null | grep -q ":${SITE_A_PORT} "; then
  die "porta ${SITE_A_PORT} já está em uso no host - escolha outra em kind/skupper-a.kind.yaml e scripts/lib.sh"
fi

pass "preflight ok - ambiente livre para criar clusters/redes"
