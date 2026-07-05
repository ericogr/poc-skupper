.PHONY: preflight up validate test-tls test-unidirectional metrics test-network-drop test-revocation relink down

SCRIPTS := scripts

# Confere se as ferramentas de host exigidas (docker, kind, kubectl, helm,
# skupper, jq) estão instaladas. Reporta TODAS as que faltarem de uma vez,
# cada uma com orientação de instalação. Todo alvo abaixo depende deste,
# então nenhum comando dependente de ferramenta roda sem essa checagem
# passar antes.
preflight:
	@$(SCRIPTS)/check-tools.sh

up: preflight
	@$(SCRIPTS)/00-preflight.sh
	@$(SCRIPTS)/01-create-networks.sh
	@$(SCRIPTS)/02-create-clusters.sh
	@$(SCRIPTS)/03-install-calico.sh
	@$(SCRIPTS)/04-install-skupper-controller.sh
	@$(SCRIPTS)/05-create-sites.sh
	@$(SCRIPTS)/06-pin-site-nodeport.sh
	@$(SCRIPTS)/07-link-clusters.sh
	@$(SCRIPTS)/08-deploy-workloads.sh
	@$(SCRIPTS)/09-validate-e2e.sh

validate: preflight
	@$(SCRIPTS)/09-validate-e2e.sh
	@$(SCRIPTS)/10-validate-tls.sh
	@$(SCRIPTS)/11-validate-unidirectional.sh

test-tls: preflight
	@$(SCRIPTS)/10-validate-tls.sh

test-unidirectional: preflight
	@$(SCRIPTS)/11-validate-unidirectional.sh

metrics: preflight
	@$(SCRIPTS)/12-collect-metrics.sh

test-network-drop: preflight
	@$(SCRIPTS)/13-simulate-network-drop.sh

test-revocation: preflight
	@$(SCRIPTS)/14-test-link-revocation.sh

relink: preflight
	@$(SCRIPTS)/07-link-clusters.sh

down: preflight
	@$(SCRIPTS)/99-teardown.sh
