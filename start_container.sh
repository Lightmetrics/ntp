#!/bin/sh
set -e
set -o pipefail

echo 'Starting container'

# /etc/docker_application_image_version.txt is created during docker build
export IMAGE_VERSION=$(cat /etc/docker_application_image_version.txt)

function check_env_param() {
  env_param_name=$1
  env_param_value=$(eval 'echo -n $'$env_param_name)
  if test -z "$env_param_value"; then
    echo "Invalid $1 in env" 1>&2
    exit 1
  fi
}
check_env_param 'PARAMETER_STORE_REGION'
check_env_param 'PARAMETER_STORE_BASE_PATH'

echo 'Pulling environment from parameter store'

# Separate base paths for
# - COMMON: '.../common/' path suffix (same values across different application versions)
# - VERSIONED: '.../<IMAGE_VERSION>/' path suffix (to be used to specify different env values across application versions)
# VERSIONED env values always override COMMON if specified under both paths
function pull_env() {
  sub_path=$1
  aws --output json --region $PARAMETER_STORE_REGION ssm get-parameters-by-path \
    --path "$PARAMETER_STORE_BASE_PATH""$sub_path"'/' --with-decryption |
    jq -r '.Parameters[] | "test -z \"$\(.Name)\" && export '"'"'\(.Name)=\(.Value)'"'"' || true"' |
    sed "s|''''|''|g" |
    sed "s|${PARAMETER_STORE_BASE_PATH}${sub_path}/||g" | sort
}

# Finish all env download from paramater store before exporting to env
# to avoid the scenario where different AWS credentials from parameter store
# are exported before finishing the env download from parameter store
versioned_env=$(pull_env $IMAGE_VERSION)
common_env=$(pull_env common)

if (
  echo "$versioned_env"
  echo "$common_env"
) | grep -q '\(AWS_ACCESS_KEY_ID\|AWS_SECRET_ACCESS_KEY\|AWS_SESSION_TOKEN\)'; then
  echo 'WARNING: Received AWS credentials from parameter store' 1>&2
fi

# pull_env variables are only exported if they are not already set
# Hence, eval versioned_env first, then common_env so that versioned_env
# variables take precedence over common_env variables
eval "$versioned_env"
eval "$common_env"

if test -z $AUTH_BEARER_JWKS && ! test -z $AUTH_BEARER_JWKS_ENDPOINT; then
  echo 'Loading environment variable AUTH_BEARER_JWKS from AUTH_BEARER_JWKS_ENDPOINT'
  export AUTH_BEARER_JWKS=$(curl ${AUTH_BEARER_JWKS_ENDPOINT} 2> /tmp/curl_bsu.log | base64 -w 0)
fi

echo 'Loaded environment'

while true; do { echo -e 'HTTP/1.1 200 OK\r\n'; echo 'OK'; } | nc -l -p 11999; done &

/opt/ntp_startup.sh
