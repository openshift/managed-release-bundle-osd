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
if [[ -z "$CONTAINER_ENGINE" ]]; then
	CONTAINER_ENGINE=$(command -v podman || command -v docker || true)
fi

# TODO: install oc when missing
OC=oc
if ! command -v ${OC} &>/dev/null; then
	fatal "'oc' is required"
fi

YQ=yq
if ! command -v ${YQ} &>/dev/null; then
	_YQ_IMAGE="quay.io/app-sre/yq:4"
	${CONTAINER_ENGINE} pull "${_YQ_IMAGE}"
	YQ="${CONTAINER_ENGINE} run --rm -i ${_YQ_IMAGE}"
fi

SKOPEO=skopeo
if ! command -v ${SKOPEO} &>/dev/null; then
	_SKOPEO_IMAGE="quay.io/skopeo/stable:latest"
	${CONTAINER_ENGINE} pull "${_SKOPEO_IMAGE}"
	SKOPEO="${CONTAINER_ENGINE} run --rm -i ${_SKOPEO_IMAGE}"
fi

_KUBECTL_PACAKGE_VERSION=v1.9.3
KUBECTL_PACKAGE=kubectl-package
if ! command -v ${KUBECTL_PACKAGE} &>/dev/null; then
	curl -o kubectl-package \
		-sL https://github.com/package-operator/package-operator/releases/download/${_KUBECTL_PACAKGE_VERSION}/kubectl-package_linux_amd64
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
_PROCESSED_TEMPLATE=$(${OC} process \
	--local \
	--output=yaml \
	--ignore-unknown-parameters \
	--filename \
	"${TEMPLATE_FILE}" \
	CHANNEL="${_OPERATOR_OLM_CHANNEL}" \
	IMAGE_TAG="${_OPERATOR_OLM_REGISTRY_IMAGE_TAG}" \
	REGISTRY_IMG="${OPERATOR_OLM_REGISTRY_IMAGE}" \
	IMAGE_DIGEST="${_OPERATOR_OLM_REGISTRY_IMAGE_DIGEST}")

log "Appending 'package-operator.run/phase' to every object and writing to ${_OUTDIR} ..."
${YQ} ".items[0].spec.resources[] |
     select(.kind==\"Namespace\") |
     .metadata.annotations += {\"package-operator.run/phase\": \"namespaces\"}" <<<"${_PROCESSED_TEMPLATE}" >"${_OUTDIR}"/namespace.yaml
${YQ} ".items[0].spec.resources[] |
     select(.kind!=\"Namespace\") |
     .metadata.annotations += {\"package-operator.run/phase\":\"${OPERATOR_NAME}\"} |
     split_doc" <<<"${_PROCESSED_TEMPLATE}" >"${_OUTDIR}"/resources.yaml

# add new operator phase if it doesn't exist
if ! grep -q "${OPERATOR_NAME}" resources/manifest.yaml; then
	${YQ} -i ".spec.phases += {\"name\": \"${OPERATOR_NAME}\"}" resources/manifest.yaml
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
