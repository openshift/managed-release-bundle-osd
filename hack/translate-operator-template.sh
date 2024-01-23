#!/usr/bin/env bash

set -e

function log() {
	echo "[bundle] ${1}"
}

# assert required vars are being passed through
echo "${OPERATOR_VERSION}"

# default path to olm-artifacts-template.yaml file
_TEMPLATE_FILE=../hack/olm-registry/olm-artifacts-template.yaml

# TODO: determine this
_OPERATOR_OLM_CHANNEL=staging
_OPERATOR_OLM_REGISTRY_IMAGE_TAG="${_OPERATOR_OLM_CHANNEL}-latest"

# look up the digest for the new registry image
_OPERATOR_OLM_REGISTRY_IMAGE_DIGEST=$(skopeo inspect \
    --format '{{.Digest}}' \
    docker://"${OPERATOR_OLM_REGISTRY_IMAGE}":"${_OPERATOR_OLM_REGISTRY_IMAGE_TAG}" \
    | tr -d "\r")

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

echo "${_PROCESSED_TEMPLATE}"

log "Appending 'package-operator.run/phase' to every object and writing to ${_OUTDIR} ..."

log "Committing changes..."
