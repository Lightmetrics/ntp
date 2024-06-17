#!/bin/bash
set -e
set -o pipefail

CURDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" > /dev/null 2>&1 && pwd)"
pushd $CURDIR &> /dev/null

IMAGE_NAME=ntp
IMAGE_VERSION=$(git describe --tags --always | sed 's|^v\([0-9]\)|\1|g')$(git status --porcelain | grep -q . && echo '-unstable' || true)
echo Building $IMAGE_NAME:$IMAGE_VERSION

if test -z $HOST_PORT; then
  hostPort=11999
else
  hostPort=$HOST_PORT
fi

function _exit() {
  popd &> /dev/null && exit $1
}

# Remove existing image and build it anew
DOCKER_BUILDKIT=1 docker build --build-arg IMAGE_VERSION=$IMAGE_VERSION -t $IMAGE_NAME:$IMAGE_VERSION . || (echo 'Docker build failed' && _exit 1)

echo 'Docker build successful. Starting container...'

docker rm -f $IMAGE_NAME || true

# Start local container
set -x
container=$(docker run --name $IMAGE_NAME -e IMAGE_VERSION=$IMAGE_VERSION \
  -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN \
  --env-file ./.env.test \
  -d $IMAGE_NAME:$IMAGE_VERSION | cut -c-12)
set +x

function _deletecontainer() {
  docker rm -f $container &> /dev/null && echo Deleted container || (echo Failed to delete container && _exit 1)
}

# Check if container started successfully
if [ $(docker inspect -f '{{.State.Running}}' $container) == "false" ]; then
  printf '\033[0;33m'
  echo Container failed to start. Logs:
  docker logs -f $container
  printf '\033[0;0m'
  _deletecontainer
  _exit 1
else
  echo "Container $container is running in detached mode"
fi

# Stop and delete container
should_delete_container='y'
printf '\033[0;0m'
read -p $'\e[33mTest(s) successful. Delete container? [Y/n/f/s]:\e[0m ' should_delete_container1
if ! test -z $should_delete_container1; then
  should_delete_container=$should_delete_container1
fi

if test "${should_delete_container,,}" == "y"; then
  _deletecontainer
  exit 0
elif test "${should_delete_container,,}" == "f"; then
  printf '\033[0;34m'
  docker logs -f $container -n 0
elif test "${should_delete_container,,}" == "s"; then
  printf '\033[0;34m'
  docker exec -it $container /bin/sh
fi
