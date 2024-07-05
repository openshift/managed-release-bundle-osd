#!/usr/bin/env bash

set -e

function log() {
	echo "[rvmo-bundle] ${1}"
}

function fatal() {
	log "fatal: ${1}" && exit 1
}

# If not explicitly provided, safe bet it's same as OPERATOR_NAME
REPO_NAME=${REPO_NAME:-$OPERATOR_NAME}

for var in TEMPLATE_FILE \
	REPO_NAME \
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

if [[ ${JENKINS_URL} ]]; then
	source "$(dirname "${BASH_SOURCE[0]}")/generate-github-app-access-token.sh"
	github_token=$(generate_app_access_token)
	github_app_id=$(get_app_id)
	github_username="openshift-sd-build-bot"

	github_email="${github_app_id}+${github_username}[bot]@users.noreply.github.com"
	github_origin=$(git config remote.origin.url | sed "s/github.com/${github_username}:${github_token}@github.com/g")
	git remote set-url origin "${github_origin}"
	git config --local user.name "${github_username}[bot]"
	git config --local user.email "${github_email}"

	# force override appinterface pipeline settings
	export GIT_AUTHOR_NAME="${github_username}[bot]"
	export GIT_AUTHOR_EMAIL="${github_email}"
	export GIT_COMMITTER_NAME="${github_username}[bot]"
	export GIT_COMMITTER_EMAIL="${github_email}"
fi

_OUTDIR=resources/${OPERATOR_NAME}
rm -rf "${_OUTDIR}" && mkdir -p "${_OUTDIR}"

# look up the digest for the new registry image
_OPERATOR_OLM_REGISTRY_IMAGE_DIGEST=$(${SKOPEO} inspect --format '{{.Digest}}' \
	docker://"${OPERATOR_OLM_REGISTRY_IMAGE}":v"${OPERATOR_VERSION}" |
	tr -d "\r")

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
TMP_BRANCH="z-bump-${OPERATOR_NAME}-${OPERATOR_VERSION}"
git checkout -b "${TMP_BRANCH}"

log "Processing template with parameters..."
sed -i "s#\${REPO_NAME}#${REPO_NAME}#" "${TEMPLATE_FILE}"
sed -i "s#\${OPERATOR_NAME}#${OPERATOR_NAME}#" "${TEMPLATE_FILE}"
sed -i "s#\${OPERATOR_VERSION}#${OPERATOR_VERSION}#" "${TEMPLATE_FILE}"
sed -i "s#\${REGISTRY_IMG}#${OPERATOR_OLM_REGISTRY_IMAGE}#" "${TEMPLATE_FILE}"
sed -i "s#\${IMAGE_DIGEST}#${_OPERATOR_OLM_REGISTRY_IMAGE_DIGEST}#" "${TEMPLATE_FILE}"
sed -i "s#\${CHANNEL}#stable#" "${TEMPLATE_FILE}"
cp "${TEMPLATE_FILE}" "${_OUTDIR}/resources.yaml.gotmpl"

# add new operator phase if it doesn't exist
if ! grep -q "name: ${OPERATOR_NAME}" resources/manifest.yaml; then
	_CONTENTS=$(${YQ} ".spec.phases += {\"name\": \"${OPERATOR_NAME}\"}" - < resources/manifest.yaml)
	echo "${_CONTENTS}" > resources/manifest.yaml
	# Check for namespaces, prepend if missing
	if ! grep -q "name: namespaces" resources/manifest.yaml; then
		_CONTENTS=$(${YQ} '.spec.phases = [{"name": "namespaces"}] + .spec.phases' - < resources/manifest.yaml)
		echo "${_CONTENTS}" > resources/manifest.yaml
	fi
fi

git add "${_OUTDIR}" resources/manifest.yaml
if git diff --quiet --exit-code --cached; then
	fatal "No changes"
fi

log "Committing changes..."
git commit --quiet --message "${OPERATOR_NAME}: ${OPERATOR_VERSION}"
git push --force -u origin HEAD


# This wouldn't be needed if we had a curl recent enough to support --fail-with-body
curlf() {
  _OUTPUT_FILE=$(mktemp)
  HTTP_CODE=$(curl --silent --output $_OUTPUT_FILE --write-out "%{http_code}" "$@")
  echo "Return Code: $HTTP_CODE"
  cat $_OUTPUT_FILE
  rm $_OUTPUT_FILE
  if [[ ${HTTP_CODE} -lt 200 || ${HTTP_CODE} -gt 299 ]] ; then
    return 22
  fi
}

curlf -X POST \
	-H "Authorization: Bearer ${github_token}" \
	-H "Accept: application/vnd.github+json" \
	-H "X-GitHub-Api-Version: 2022-11-28" \
	--data '{"base":"'"${CURRENT_BRANCH}"'","head":"'"${TMP_BRANCH}"'","title":"'"${OPERATOR_NAME}"':'"${OPERATOR_VERSION}"'"}' \
	https://api.github.com/repos/openshift/managed-release-bundle-osd/pulls
