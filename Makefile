.PHONY: all list help secrets build-inception-container secrets-inception-container es-deploy-event es-index-deploy-events configmap container-deploy .check-docker-credentials-expired clean

REGISTRY := 008401962776.dkr.ecr.us-east-1.amazonaws.com
REPO_NAME := bind-caching-dns
REPO := $(REGISTRY)/$(REPO_NAME)
ES_HOST := search.efp.returnpath.net
DEPLOYMENT_YML := deploy/deployment.yml
BUILD_TOOLS := trinitronx/build-tools:ubuntu-1404
BUILD_TOOLS_KUBECTL_REPO := build-tools-kubectl

REV := $(shell TZ=UTC date +'%Y%m%dT%H%M%S')-$(shell git rev-parse --short HEAD)

# Load both ~/.aws and ENV variables for awscli calls so this will work
# with the full aws cli credential detection system (and allows us to run
# on local machines with ~/.aws or jenkins with ENV variables).
DOCKER_AWS_CREDENTIALS := -v ~/.aws:/root/.aws
ifdef AWS_ACCESS_KEY_ID
	DOCKER_AWS_CREDENTIALS += -e AWS_ACCESS_KEY_ID=$(AWS_ACCESS_KEY_ID)
endif
ifdef AWS_SECRET_ACCESS_KEY
	DOCKER_AWS_CREDENTIALS += -e AWS_SECRET_ACCESS_KEY=$(AWS_SECRET_ACCESS_KEY)
endif

## Only pass -it to docker run when not in GoCD
ifeq ($(GO_PIPELINE_NAME),)
  define DOCKER_RUN_INTERACTIVE
    -ti
  endef
else
  define DOCKER_RUN_INTERACTIVE
  endef
endif

.DEFAULT_GOAL := help

# Auto-documented Makefile
# Source: http://marmelab.com/blog/2016/02/29/auto-documented-makefile.html
help: ## Shows this generated help info for Makefile targets
	@grep -E '^[a-zA-Z_-]+:.*?(## )?.*$$' $(MAKEFILE_LIST) | sort | awk '{ if ( $$0 ~ /^[a-zA-Z_-]+:.*?## ?.*$$/ ) { split($$0,resultArr,/:.*## /) ; printf "\033[36m%-30s\033[0m %s\n", resultArr[1], resultArr[2] } else if ( $$0 ~ /^[a-zA-Z_-]+:.*$$/ ) { split($$0,resultArr,/:.*?/);  printf "\033[36m%-30s\033[0m\n", resultArr[1] } } '

list: ## Just list all Makefile targets without help
	@$(MAKE) -pRrq -f $(lastword $(MAKEFILE_LIST)) : 2>/dev/null | awk -v RS= -F: '/^# File/,/^# Finished Make data base/ {if ($$1 !~ "^[#.]") {print $$1}}' | sort | egrep -v -e '^[^[:alnum:]]' -e '^$@$$' | xargs

all: ## Do EVERYTHING!

.check-docker-credentials-expired:
	@#Note: This target is defined as an "order-only" prerequisite type so as to preserve conditional execution of .docker/config.json target
	@#See: https://www.gnu.org/software/make/manual/html_node/Prerequisite-Types.html#Prerequisite-Types
	@if [ ! -d .docker ]; then mkdir .docker ; fi
	@#Always remove our local .docker/config.json if it is expired & older than 12 hrs
	#Checking if .docker/config.json Credentials are expired & re-run make if older than 12 hrs
	if [ -e .docker/config.json ]; then  find .docker/config.json -mmin +720 -exec bash -c 'rm -f "{}"; $(MAKE) .docker/config.json' \; ; fi

# Creating separate shipping paths for both the perl and python, as they have
# different requirements for what is needed in an image.
.docker/config.json: | .check-docker-credentials-expired
	@# Shell will suppress the output the ecr-login task to avoid logging the creds
	@# Comment that will get output minus creds so we know what is going on
	#`docker run --rm $$(DOCKER_AWS_CREDENTIALS) returnpath/awscli ecr get-login`
	@`docker run --rm $(DOCKER_AWS_CREDENTIALS) returnpath/awscli ecr get-login`
	cp ~/.docker/config.json .docker/config.json

build-inception-container: .docker/config.json ## Builds the temp build container base image from build/Dockerfile.make
	docker pull $(BUILD_TOOLS)
	docker build -f build/Dockerfile.make -t "$(REGISTRY)/$(BUILD_TOOLS_KUBECTL_REPO)" .
	docker --config=.docker/ push "$(REGISTRY)/$(BUILD_TOOLS_KUBECTL_REPO)"

build/Dockerfile.make.onbuild:
	printf 'FROM $(REGISTRY)/$(BUILD_TOOLS_KUBECTL_REPO)\n' > build/Dockerfile.make.onbuild

.packaged:
	@echo "BEGIN STEP: PACKAGE"
	if [ ! -z "$$(docker images $(REPO):$(REV))" ]; then	\
		docker build -t "$(REPO):$(REV)" .;             \
	fi
	echo "$(REV)" > .packaged

package: .packaged ## Uses Dockerfile to build the releaseable Docker container for this project.

ship: package .docker/config.json ## Tag & Push the built container to the Docker Registry
	@echo "BEGIN STEP: SHIP"
	docker tag $(REPO):$$(cat .packaged) $(REPO):latest
	docker --config=.docker/ push $(REPO):$(shell cat .packaged)
	docker --config=.docker/ push $(REPO):latest

container-ship: .docker/config.json build-inception-container build/Dockerfile.make.onbuild  ## Runs "make ship" inside temp build container (Use this in GoCD)
	docker build -f build/Dockerfile.make.onbuild -t "$(REPO):build-$(REV)" .
	@# Comment that will get output minus creds so we know what is going on
	#docker run --rm $$(DOCKER_AWS_CREDENTIALS) -v /var/run/docker.sock:/var/run/docker.sock "$(REPO):build-$(REV)" "make ship"
	@bash -c '  cleanup() { docker rm -v "$(REPO_NAME)-container-ship-$(REV)" ; docker rmi "$(REPO):build-$(REV)"; } ; \
                trap cleanup EXIT HUP INT QUIT KILL TERM ;       \
	            docker run  $(DOCKER_AWS_CREDENTIALS)        \
                    --name="$(REPO_NAME)-container-ship-$(REV)"  \
                    -e GO_PIPELINE_NAME=$(GO_PIPELINE_NAME)      \
                    -v /var/run/docker.sock:/var/run/docker.sock \
                    "$(REPO):build-$(REV)"                       \
                    "make ship"; exit_status=$$? ;               \
                echo "CONTAINER_SHIP_RESULT=$$exit_status"; exit $$exit_status; '

$(DEPLOYMENT_YML): build/deployment-template.yml.tmpl
	export KUBERNETES_DEPLOYMENT_NAME="$(REPO_NAME)" ; \
	export KUBERNETES_POD_NAME="$(REPO_NAME)" ; \
	export DOCKER_IMAGE="$(REPO):$$(cat .packaged)" ; \
	[ ! -d "$$(dirname $(DEPLOYMENT_YML))" ] && mkdir -p $$(dirname $(DEPLOYMENT_YML)) || true ; \
	export DEPLOY_CAUSE="$(shell bash -c '[ -n "$$GO_PIPELINE_NAME" ] && echo "GoCD Deployment: https://$(GOCD_SERVER)/go/pipelines/$${GO_PIPELINE_NAME}/$${GO_PIPELINE_COUNTER}/$${GO_STAGE_NAME}/$${GO_STAGE_COUNTER}   Triggered by: $${GO_TRIGGER_USER}  Revision: $${GO_REVISION}" || echo "GNU Make on $$HOSTNAME  Triggered by: $$USER  Revision: $$(git rev-parse HEAD)" ')" ; \
	  cat build/deployment-template.yml.tmpl | envsubst > $(DEPLOYMENT_YML)

configmap: ## Build and deploy all the ConfigMaps from configmap/* directories
	    @# Building the configmaps is currently quite quick, and if there's no change nothing happens, so we're just rebuilding all config maps each time
	    @# `kubectl` doesn't allow you to `apply configmap --from-file`, so to
	    @# avoid checking for the existence of a config map and doing a delete if
	    @# it exists (and opening that race condition) we're creating the yaml
	    @# ourselves and using good old `apply -f`
	    for c in configmap/*; do                   \
	      bin/configmap-from-directory $$c       | \
	        kubectl $(KUBECTL_FLAGS) apply -f -;   \
	    done

es-index-deploy-events: ## Create ElasticSearch events Index + Deployment Mapping
	-if [ -n "$(GO_PIPELINE_NAME)" ] && ! curl -o /dev/null -s -L -k --fail "https://$(ES_HOST)/events"; then \
      curl -s -L -k --fail "https://$(ES_HOST)/events" -d @build/elasticsearch-index-deploy-events.json ; \
    else \
      true ; \
    fi

es-deploy-event: | es-index-deploy-events ## POST Deployment event to ElasticSearch 'events' index
	export GOCD_SERVER GO_ENVIRONMENT_NAME GO_SERVER_URL GO_TRIGGER_USER GO_PIPELINE_NAME GO_PIPELINE_COUNTER GO_PIPELINE_LABEL GO_STAGE_NAME GO_STAGE_COUNTER GO_JOB_NAME GO_REVISION GO_TO_REVISION GO_FROM_REVISION ; \
	export GIT_REPO_URL=$(shell bash -c 'git config --get remote.origin.url') ; \
	export NOW_TIMESTAMP=$(shell bash -c 'date -u +%FT%T%z') ; \
    [ -n "$(GO_PIPELINE_NAME)" ] && cat build/deployment-event-template.json.tmpl | envsubst | curl -k -s "https://$(ES_HOST)/events/deployment" -d @-  || true

deploy: ship $(DEPLOYMENT_YML) .docker/config.json | es-deploy-event ## Deploys the shipped container to Kubernetes (Renders template build/deployment-template.yml.tmpl & pipes to kubectl apply -f -)
	kubectl $(KUBECTL_FLAGS) apply -f $(DEPLOYMENT_YML)

container-deploy: clean .docker/config.json build-inception-container build/Dockerfile.make.onbuild ## Runs "make deploy" inside temp build container (Use this in GoCD)
	docker build -f build/Dockerfile.make.onbuild -t "$(REPO):build-$(REV)" .
	if [ -n "$(GO_PIPELINE_NAME)" ]; then  export GO_PIPELINE_NAME GO_PIPELINE_COUNTER GO_STAGE_NAME GO_STAGE_COUNTER GO_JOB_NAME GO_TRIGGER_USER GO_REVISION USER ;  fi
	@# Comment that will get output minus creds so we know what is going on
	#docker run --rm $$(DOCKER_AWS_CREDENTIALS) -v /var/run/docker.sock:/var/run/docker.sock  -e KUBECTL_FLAGS="$(KUBECTL_FLAGS)" --net=host "$(REPO):build-$(REV)" "make deploy"
	@bash -c '  cleanup() { docker rmi "$(REPO):build-$(REV)"; } ;  \
	            trap cleanup EXIT HUP INT QUIT KILL TERM ;          \
	            docker run --rm $(DOCKER_AWS_CREDENTIALS)           \
                    -e KUBECTL_FLAGS="$(KUBECTL_FLAGS)"           \
                    -e GO_PIPELINE_NAME=$(GO_PIPELINE_NAME)       \
                    -e GO_PIPELINE_COUNTER=$(GO_PIPELINE_COUNTER) \
                    -e GO_STAGE_NAME=$(GO_STAGE_NAME)             \
                    -e GO_STAGE_COUNTER=$(GO_STAGE_COUNTER)       \
                    -e GO_JOB_NAME=$(GO_JOB_NAME)                 \
                    -e GO_TRIGGER_USER=$(GO_TRIGGER_USER)         \
                    -e GO_REVISION=$(GO_REVISION)                 \
                    -e USER=$(USER)                               \
                    --net=host                                    \
                    -v /var/run/docker.sock:/var/run/docker.sock  \
                    "$(REPO):build-$(REV)"                        \
                    "make deploy"; '

secrets-inception-container:  ## Build a temporary container with lpass + current source code for use with "make secrets"
	printf 'FROM returnpath/lpass:0.8.1-3\nADD . /src' > build/Dockerfile.make.secrets

secrets: secrets-inception-container ## Creates Kubernets Secrets from build/secrets/<secret_name>.yml.tmpl + LastPass item(s) matching secret_name
	@echo "Installing secrets into Kubernetes Cluster"
	docker build -f build/Dockerfile.make.secrets -t "returnpath/lpass:0.8.1-3-$(REV)" .
	@echo "LastPass Master Password: " > /dev/stderr;
	@stty -echo
	docker run --rm -it                                                                                    \
	           -e LPASS_DISABLE_PINENTRY=1                                                                 \
	           -e BASE64_FLAGS=$(BASE64_FLAGS)                                                             \
	           -e LPASS_ASKPASS=/usr/local/bin/quiet-askpass                                               \
	           --entrypoint=/bin/bash                                                                      \
	           -v ~/.lpass:/root/.lpass "returnpath/lpass:0.8.1-3-$(REV)"                                  \
	           -c '/src/bin/render-lpass-file-template-into-secret /src/deploy/secrets' | kubectl apply -f -
	@stty echo

container-secrets: clean .docker/config.json build-inception-container build/Dockerfile.make.onbuild ## Runs "make secrets" inside temp build container
	docker build -f build/Dockerfile.make.onbuild -t "$(REPO):build-$(REV)" .
	@# Comment that will get output minus creds so we know what is going on
	#docker run --rm -it $$(DOCKER_AWS_CREDENTIALS) -e KUBECTL_FLAGS="$(KUBECTL_FLAGS)" --net=host -v /var/run/docker.sock:/var/run/docker.sock -v $(HOME)/.lpass:/root/.lpass -v $(PWD):/root/  "$(REPO):build-$(REV)" "make secrets"
	@bash -c '  cleanup() { docker rmi "$(REPO):build-$(REV)"; } ; \
                trap cleanup EXIT HUP INT QUIT KILL TERM ;       \
	            docker run --rm -it $(DOCKER_AWS_CREDENTIALS)    \
                    -e KUBECTL_FLAGS="$(KUBECTL_FLAGS)"          \
                    --net=host                                   \
                    -v /var/run/docker.sock:/var/run/docker.sock \
                    -v $(HOME)/.lpass:/root/.lpass               \
                    -v $(PWD):/root/                             \
                    "$(REPO):build-$(REV)"                       \
                    "make secrets"; '

clean: ## Remove & cleanup leftover files from other make targets
	rm -f build/Dockerfile.make.onbuild
	rm -f .docker/config.json
	rm -f $(DEPLOYMENT_YML)
	rm -f .packaged
