#!/usr/bin/env bash

set -e

function log() {
	echo "[bundle] ${1}"
}

# assert required vars are being passed through
echo "${OPERATOR_VERSION}"

# default path to olm-artifacts-template.yaml file
_TEMPLATE_FILE=../hack/olm-registry/olm-artifacts-template.yaml

cat ${_TEMPLATE_FILE}

log "Process template with parameters..."

log "Appending 'package-operator.run/phase' to every object and writing to ${_OUTDIR} ..."

log "Committing changes..."
