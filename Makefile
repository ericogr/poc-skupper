.PHONY: up validate test-tls test-unidirectional metrics test-network-drop test-revocation relink down

SCRIPTS := scripts

up:
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

validate:
	@$(SCRIPTS)/09-validate-e2e.sh
	@$(SCRIPTS)/10-validate-tls.sh
	@$(SCRIPTS)/11-validate-unidirectional.sh

test-tls:
	@$(SCRIPTS)/10-validate-tls.sh

test-unidirectional:
	@$(SCRIPTS)/11-validate-unidirectional.sh

metrics:
	@$(SCRIPTS)/12-collect-metrics.sh

test-network-drop:
	@$(SCRIPTS)/13-simulate-network-drop.sh

test-revocation:
	@$(SCRIPTS)/14-test-link-revocation.sh

relink:
	@$(SCRIPTS)/07-link-clusters.sh

down:
	@$(SCRIPTS)/99-teardown.sh
