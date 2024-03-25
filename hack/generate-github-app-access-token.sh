#!/bin/bash
set -eo pipefail

app_id="${GITHUB_APP_ID}"
private_key_file_path="${GITHUB_APP_PRIVATE_KEY_FILE_PATH}"
private_key=$(cat $private_key_file_path)

# Shared content to use as template
header='{
    "alg": "RS256",
    "typ": "JWT"
}'
payload_template='{}'

function build_payload() {
	jq -c \
		--arg iat_str "$(date +%s)" \
		--arg app_id "${app_id}" \
		'
        ($iat_str | tonumber) as $iat
        | .iat = $iat
        | .exp = ($iat + 300)
        | .iss = ($app_id | tonumber)
        ' <<<"${payload_template}" | tr -d '\n'
}

function b64enc() { openssl enc -base64 -A | tr '+/' '-_' | tr -d '='; }
function json() { jq -c . | LC_CTYPE=C tr -d '\n'; }
function rs256_sign() { openssl dgst -binary -sha256 -sign <(printf '%s\n' "$1"); }

function sign() {
	local algo payload sig
	algo=${1:-RS256}
	algo=${algo^^}
	payload=$(build_payload) || return
	signed_content="$(json <<<"$header" | b64enc).$(json <<<"$payload" | b64enc)"
	sig=$(printf %s "$signed_content" | rs256_sign "$private_key" | b64enc)
	printf '%s.%s\n' "${signed_content}" "${sig}"
}

function generate_app_access_token() {
	token=$(sign)

	installation_list_response=$(curl -s -H "Authorization: Bearer ${token}" \
		-H "Accept: application/vnd.github.machine-man-preview+json" \
		https://api.github.com/app/installations)

	installation_id=$(echo $installation_list_response | jq '.[] | select(.app_id=='${app_id}')' | jq -r '.id')

	if [ -z "$installation_id" ]; then
		echo >&2 "Unable to obtain installation ID: $installation_list_response"
		return
	fi

	# authenticate as github app and get access token
	installation_token_response=$(curl -s -X POST \
		-H "Authorization: Bearer ${token}" \
		-H "Accept: application/vnd.github.machine-man-preview+json" \
		https://api.github.com/app/installations/$installation_id/access_tokens)

	installation_token=$(echo $installation_token_response | jq -r '.token')

	if [ -z "$installation_token" ]; then
		echo >&2 "Unable to obtain installation token: $installation_token_response"
		return
	fi

	echo $installation_token
}
