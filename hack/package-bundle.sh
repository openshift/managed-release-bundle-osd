#!/usr/bin/env bash

set -e

_KUBECTL_PACAKGE_VERSION=v1.10.0
KUBECTL_PACKAGE=kubectl-package
if ! command -v ${KUBECTL_PACKAGE} &>/dev/null; then
	curl -o kubectl-package \
		-sL https://github.com/package-operator/package-operator/releases/download/${_KUBECTL_PACAKGE_VERSION}/kubectl-package_linux_amd64
	chmod +x ./kubectl-package
	KUBECTL_PACKAGE=./kubectl-package
fi

if [[ ${QUAY_DOCKER_CONFIG_JSON} ]]; then
	mkdir -p .docker
	echo "$QUAY_DOCKER_CONFIG_JSON" | base64 -d > .docker/config.json
	export DOCKER_CONFIG=.docker
fi

_BUNDLE_REGISTRY="${BUNDLE_REGISTRY:-quay.io/app-sre/managed-release-bundle}"

_BRANCH=$(git rev-parse --abbrev-ref HEAD)
_COMMIT=$(git rev-parse --short HEAD)
_BUILD_NUMBER=$(git rev-list --count HEAD)
_BUNDLE_IMAGE_NAME=${_BUNDLE_REGISTRY}:${_BRANCH/#release-/}.${_BUILD_NUMBER}-${_COMMIT}

echo "Building and pushing package ${_BUNDLE_IMAGE_NAME} ..."
${KUBECTL_PACKAGE} build --push --tag "${_BUNDLE_IMAGE_NAME}" ./resources
