# Trades pipeline. make deploy (infra -> images -> apps), then make health. make destroy removes everything.
SHELL  := /bin/bash
REGION := eu-north-1
TAG    ?= $(shell git rev-parse --short HEAD 2>/dev/null)
TF     := terraform

.PHONY: help preflight images deploy destroy verify-clean health query kubeconfig
.DEFAULT_GOAL := help

help: ## list the targets (default)
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-13s %s\n", $$1, $$2}'

preflight: ## checks the tools and the AWS account before deploy
	@for t in aws terraform helm kubectl docker; do command -v $$t >/dev/null || { echo "missing tool: $$t"; exit 1; }; done
	@acct=$$(aws sts get-caller-identity --query Account --output text) || { echo "no AWS credentials: set AWS_PROFILE"; exit 1; }; \
	  test "$$acct" = 092988563851 || { echo "wrong AWS account: $$acct (expected 092988563851)"; exit 1; }
	@echo "preflight OK"

images: ## build and push both images, tag = git SHA (or TAG=...); a tag already in ECR is skipped
	@test -n "$(TAG)" || { echo "no git commit yet: commit first, the image tag is the commit SHA"; exit 1; }
	scripts/build-push.sh $(TAG)

deploy: preflight ## infra (creates the ECR repos), then the images, then the in-cluster layer
	@test -n "$(TAG)" || { echo "no git commit yet: commit first, the image tag is the commit SHA"; exit 1; }
	$(TF) -chdir=infra init -input=false
	$(TF) -chdir=infra apply -input=false -auto-approve -lock-timeout=5m
	scripts/build-push.sh $(TAG)
	$(TF) -chdir=apps init -input=false
	$(TF) -chdir=apps apply -input=false -auto-approve -lock-timeout=5m -var image_tag=$(TAG)
	$(MAKE) kubeconfig

destroy: ## reverse order: the in-cluster layer first (must succeed while the cluster exists), then infra
	$(TF) -chdir=apps init -input=false
	@if aws eks describe-cluster --region $(REGION) --name arik-rainish-eks >/dev/null 2>&1; then 	  $(TF) -chdir=apps destroy -input=false -auto-approve -lock-timeout=5m; 	else echo "cluster arik-rainish-eks not found: skipping the apps destroy (nothing left to remove in it)"; fi
	$(TF) -chdir=infra init -input=false
	$(TF) -chdir=infra destroy -input=false -auto-approve -lock-timeout=5m

verify-clean: ## after destroy: lists anything left behind (expect empty sections)
	scripts/verify-clean.sh

kubeconfig: ## writes to the KUBECONFIG file (default ~/.kube/config); set AWS_PROFILE to the sandbox profile first
	aws eks update-kubeconfig --region $(REGION) --name arik-rainish-eks --alias trades-pipeline

health: ## one command: OK or ALARM of the composite alarm
	@aws cloudwatch describe-alarms --alarm-names arik-rainish-health --alarm-types CompositeAlarm --query 'CompositeAlarms[0].StateValue' --region eu-north-1 --output text

query: ## read-only SQL through the consumer pod, e.g. make query SQL=scripts/duplicates.sql
	@test -n "$(SQL)" || { echo "usage: make query SQL=scripts/duplicates.sql"; exit 1; }
	@kubectl -n pipeline exec -i deploy/consumer -- python query.py < $(SQL)
