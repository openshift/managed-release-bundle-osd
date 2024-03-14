#!/usr/bin/env bash

set -e

function log() {
	echo "[rvmo-bundle] ${1}"
}

function fatal() {
	log "${1}" && exit 1
}

for var in TEMPLATE_FILE \
	OPERATOR_NAME \
	OPERATOR_VERSION \
	OPERATOR_OLM_REGISTRY_IMAGE; do
	if [ ! "${!var:-}" ]; then
		fatal "$var is not set"
	fi
done

if ! [ -f "${TEMPLATE_FILE}" ]; then
	fatal "template file \"${TEMPLATE_FILE}\" does not exist"
fi

# Use set container engine or select one from available binaries
if [[ -z "${CONTAINER_ENGINE}" ]]; then
	CONTAINER_ENGINE=$(command -v podman || command -v docker || true)
fi

if [[ ${QUAY_DOCKER_CONFIG_JSON} ]]; then
	mkdir -p .docker
	echo "$QUAY_DOCKER_CONFIG_JSON" | base64 -d > .docker/config.json
	export DOCKER_CONFIG=.docker
fi

YQ=yq
if ! command -v ${YQ} &>/dev/null; then
	_YQ_IMAGE="quay.io/app-sre/yq:4"
	${CONTAINER_ENGINE} pull "${_YQ_IMAGE}"
	YQ="${CONTAINER_ENGINE} run --rm -i ${_YQ_IMAGE}"
fi

# TODO: fix forcing skopeo from a container on jenkins
SKOPEO=skopeo
if ! command -v ${SKOPEO} &>/dev/null || [ -n "${JENKINS_URL}" ]; then
	_SKOPEO_IMAGE="quay.io/skopeo/stable:latest"
	${CONTAINER_ENGINE} pull "${_SKOPEO_IMAGE}"
	SKOPEO="${CONTAINER_ENGINE} run --rm -i ${_SKOPEO_IMAGE}"
fi

_KUBECTL_PACAKGE_VERSION=v1.10.0
KUBECTL_PACKAGE=kubectl-package
if ! command -v ${KUBECTL_PACKAGE} &>/dev/null; then
	curl -o kubectl-package \
		-sL https://github.com/package-operator/package-operator/releases/download/${_KUBECTL_PACAKGE_VERSION}/kubectl-package_linux_amd64
	chmod +x ./kubectl-package
	KUBECTL_PACKAGE=./kubectl-package
fi

_BUNDLE_REGISTRY="${BUNDLE_REGISTRY:-quay.io/app-sre/managed-release-bundle}"

_OUTDIR=resources/${OPERATOR_NAME}
rm -rf "${_OUTDIR}" && mkdir -p "${_OUTDIR}"

# TODO: determine this
_OPERATOR_OLM_CHANNEL=staging
_OPERATOR_OLM_REGISTRY_IMAGE_TAG="${_OPERATOR_OLM_CHANNEL}-latest"

# look up the digest for the new registry image
_OPERATOR_OLM_REGISTRY_IMAGE_DIGEST=$(${SKOPEO} inspect --format '{{.Digest}}' \
	docker://"${OPERATOR_OLM_REGISTRY_IMAGE}":"${_OPERATOR_OLM_REGISTRY_IMAGE_TAG}" |
	tr -d "\r")

log "Processing template with parameters..."
sed -i "s#\${NAMESPACE}#${OPERATOR_NAME}#" "${TEMPLATE_FILE}"
sed -i "s#\${REPO_NAME}#${OPERATOR_NAME}#" "${TEMPLATE_FILE}"
sed -i "s#\${REGISTRY_IMG}#${OPERATOR_OLM_REGISTRY_IMAGE}#" "${TEMPLATE_FILE}"
sed -i "s#\${IMAGE_DIGEST}#${_OPERATOR_OLM_REGISTRY_IMAGE_DIGEST}#" "${TEMPLATE_FILE}"
sed -i "s#\${CHANNEL}#${_OPERATOR_OLM_CHANNEL}#" "${TEMPLATE_FILE}"
cp "${TEMPLATE_FILE}" "${_OUTDIR}/resources.yaml"

# add new operator phase if it doesn't exist
if ! grep -q "${OPERATOR_NAME}" resources/manifest.yaml; then
	_CONTENTS=$(${YQ} ".spec.phases += {\"name\": \"${OPERATOR_NAME}\"}" - < resources/manifest.yaml)
	echo "${_CONTENTS}" >> resources/manifest.yaml
fi

git add "${_OUTDIR}" resources/manifest.yaml
if git diff --quiet --exit-code --cached; then
	fatal "No changes"
fi

log "Committing changes..."
git commit --quiet --message "${OPERATOR_NAME}: ${OPERATOR_VERSION}"
# git push

_BRANCH=$(git rev-parse --abbrev-ref HEAD)
_COMMIT=$(git rev-parse --short HEAD)
_BUILD_NUMBER=$(git rev-list --count HEAD)
_BUNDLE_IMAGE_NAME=${_BUNDLE_REGISTRY}:${_BRANCH/#release-/}.${_BUILD_NUMBER}-${_COMMIT}

log "Building and pushing package ${_BUNDLE_IMAGE_NAME} ..."
${KUBECTL_PACKAGE} build --push --tag "${_BUNDLE_IMAGE_NAME}" ./resources
