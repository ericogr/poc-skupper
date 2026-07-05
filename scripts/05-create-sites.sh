#!/usr/bin/env bash
# Cria o namespace de aplicação e o site Skupper em cada cluster.
# Só A pede exposição de link-access (vai ficar <pending> como LoadBalancer,
# mas já aloca o NodePort que fixamos no próximo script).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

kctl_a create namespace "${NS_APP}" --dry-run=client -o yaml | kctl_a apply -f -
kctl_b create namespace "${NS_APP}" --dry-run=client -o yaml | kctl_b apply -f -

skupper_a site create site-a \
  --enable-link-access \
  --link-access-type loadbalancer \
  --wait configured

skupper_b site create site-b \
  --wait ready

pass "site-a (link-access habilitado) e site-b criados"
