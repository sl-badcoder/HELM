#!/bin/bash
set -euo pipefail

DRIVER_VERSION="595.71.05"

IMAGE_NAME="uvm-eviction-cuda-${DRIVER_VERSION}"
CONTAINER_NAME="uvm-eviction-dev-${DRIVER_VERSION}"

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd)

# ============================================================
# CHECK HOST NVIDIA DRIVER
# ============================================================

if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "ERROR: nvidia-smi was not found on the host."
  exit 1
fi

HOST_DRIVER=$(
  nvidia-smi -i 0 \
    --query-gpu=driver_version \
    --format=csv,noheader |
  tr -d '[:space:]'
)

if [[ "${HOST_DRIVER}" != "${DRIVER_VERSION}" ]]; then
  echo "ERROR: This source tree must match the running NVIDIA driver exactly."
  echo "Expected ${DRIVER_VERSION}, found ${HOST_DRIVER}."
  exit 1
fi

if command -v modinfo >/dev/null 2>&1; then
  NVIDIA_LICENSE=$(modinfo -F license nvidia 2>/dev/null || true)

  if [[ "${NVIDIA_LICENSE}" != *"MIT/GPL"* ]]; then
    echo "ERROR: The ${DRIVER_VERSION} port uses NVIDIA's open kernel modules."
    echo "The loaded nvidia module reports license '${NVIDIA_LICENSE:-unknown}'."
    echo "Install the ${DRIVER_VERSION} open driver flavor before running these experiments."
    exit 1
  fi
fi

"${SCRIPT_DIR}/check-kernel-headers.sh"


# ============================================================
# BUILD IMAGE ONLY IF IT DOES NOT ALREADY EXIST
# ============================================================

if ! docker image inspect "${IMAGE_NAME}" >/dev/null 2>&1; then
  echo "Docker image does not exist. Building:"
  echo "  ${IMAGE_NAME}"

  docker build \
    -f "${SCRIPT_DIR}/Dockerfile" \
    "${SCRIPT_DIR}" \
    -t "${IMAGE_NAME}"
else
  echo "Using existing image:"
  echo "  ${IMAGE_NAME}"
fi


# ============================================================
# REUSE EXISTING CONTAINER
# ============================================================

if docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then

  RUNNING=$(
    docker inspect \
      -f '{{.State.Running}}' \
      "${CONTAINER_NAME}"
  )

  if [[ "${RUNNING}" == "true" ]]; then
    echo "Container is already running."
    echo "Opening a new shell..."

    docker exec \
      -it \
      "${CONTAINER_NAME}" \
      bash

  else
    echo "Starting existing container:"
    echo "  ${CONTAINER_NAME}"

    docker start \
      -ai \
      "${CONTAINER_NAME}"
  fi

  exit 0
fi


# ============================================================
# CREATE CONTAINER FOR THE FIRST TIME
# ============================================================

echo "Creating persistent development container:"
echo "  ${CONTAINER_NAME}"

docker run \
  --name "${CONTAINER_NAME}" \
  --init \
  --hostname=cuda-host \
  --privileged=true \
  -it \
  --gpus all \
  --ipc=host \
  --ulimit memlock=-1 \
  --ulimit stack=67108864 \
  -v "${REPO_ROOT}:/uvm-eviction" \
  -w /uvm-eviction \
  -v /lib/modules:/lib/modules:ro \
  -v /usr/src:/usr/src:ro \
  "${IMAGE_NAME}" \
  bash