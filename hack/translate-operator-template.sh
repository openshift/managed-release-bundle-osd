#!/usr/bin/env bash

set -e

function log() {
	echo "[bundle] ${1}"
}

# TODO: assert required tools are in path
# skopeo, oc, yq, kubectl-package
# TODO: assert required vars are being passed through
# $OPERATOR_NAME $OPERATOR_VERSION $OPERATOR_OLM_REGISTRY_IMAGE

# default path to olm-artifacts-template.yaml file
_TEMPLATE_FILE=../hack/olm-registry/olm-artifacts-template.yaml
_BUNDLE_REGISTRY=ghcr.io/jbpratt/managed-openshift/release-bundle

_OUTDIR=resources/${OPERATOR_NAME}
rm -rf "${_OUTDIR}" && mkdir -p "${_OUTDIR}"

# TODO: determine this
_OPERATOR_OLM_CHANNEL=staging
_OPERATOR_OLM_REGISTRY_IMAGE_TAG="${_OPERATOR_OLM_CHANNEL}-latest"

# look up the digest for the new registry image
_OPERATOR_OLM_REGISTRY_IMAGE_DIGEST=$(skopeo inspect \
	--format '{{.Digest}}' \
	docker://"${OPERATOR_OLM_REGISTRY_IMAGE}":"${_OPERATOR_OLM_REGISTRY_IMAGE_TAG}" |
	tr -d "\r")

log "Process template with parameters..."
_PROCESSED_TEMPLATE=$(oc process \
	--local \
	--output=yaml \
	--ignore-unknown-parameters \
	--filename \
	"${_TEMPLATE_FILE}" \
	CHANNEL="${_OPERATOR_OLM_CHANNEL}" \
	IMAGE_TAG="${_OPERATOR_OLM_REGISTRY_IMAGE_TAG}" \
	REGISTRY_IMG="${OPERATOR_OLM_REGISTRY_IMAGE}" \
	IMAGE_DIGEST="${_OPERATOR_OLM_REGISTRY_IMAGE_DIGEST}")

log "Appending 'package-operator.run/phase' to every object and writing to ${_OUTDIR} ..."
yq "
    .items[0].spec.resources[] |
    select(.kind==\"Namespace\") |
    .metadata.annotations += {\"package-operator.run/phase\": \"namespaces\"}" <<<"${_PROCESSED_TEMPLATE}" >"${_OUTDIR}"/namespace.yaml
yq "
    .items[0].spec.resources[] |
    select(.kind!=\"Namespace\") |
    .metadata.annotations += {\"package-operator.run/phase\":\"${OPERATOR_NAME}\"} |
    split_doc" <<<"${_PROCESSED_TEMPLATE}" >"${_OUTDIR}"/resources.yaml

# add new operator phase if it doesn't exist
if ! grep -q "${OPERATOR_NAME}" resources/manifest.yaml; then
	yq -i ".spec.phases += {\"name\": \"${OPERATOR_NAME}\"}" resources/manifest.yaml
fi

git add "${_OUTDIR}" resources/manifest.yaml

if git diff --quiet --exit-code --cached; then
	log "No changes" && exit 1
fi

log "Committing changes..."
git commit --quiet --message "${OPERATOR_NAME}: ${OPERATOR_VERSION}"
# git push

_BRANCH=$(git rev-parse --abbrev-ref HEAD)
_COMMIT=$(git rev-parse --short HEAD)
_BUILD_NUMBER=$(git rev-list --count HEAD)
_BUNDLE_IMAGE_NAME=${_BUNDLE_REGISTRY}:${_BRANCH/#release-/}.${_BUILD_NUMBER}-${_COMMIT}

log "Building and pushing package ${_BUNDLE_IMAGE_NAME} ..."
kubectl package build --push --tag "${_BUNDLE_IMAGE_NAME}" ./resources
