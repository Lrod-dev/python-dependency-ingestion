#!/usr/bin/env bash
set -euo pipefail

REQUEST_DIR="${1:?Usage: ingest_container_image_pip.sh <request-dir>}"

if [[ ! -d "${REQUEST_DIR}" ]]; then
  echo "Request directory does not exist: ${REQUEST_DIR}"
  exit 1
fi

if [[ ! -f "${REQUEST_DIR}/request.properties" ]]; then
  echo "Missing required file: ${REQUEST_DIR}/request.properties"
  exit 1
fi

if [[ ! -f "${REQUEST_DIR}/requirements.txt" ]]; then
  echo "Missing required file: ${REQUEST_DIR}/requirements.txt"
  exit 1
fi

source "${REQUEST_DIR}/request.properties"

: "${REQUEST_ID:?REQUEST_ID is required}"
: "${WORKLOAD_TYPE:?WORKLOAD_TYPE is required}"
: "${CONTAINER_IMAGE:?CONTAINER_IMAGE is required}"
: "${PACKAGE_MANAGER:?PACKAGE_MANAGER is required}"
: "${ARTIFACTORY_REPO:?ARTIFACTORY_REPO is required}"
: "${ARTIFACTORY_HOST:?ARTIFACTORY_HOST is required}"
: "${ARTIFACTORY_USER:?ARTIFACTORY_USER is required}"
: "${ARTIFACTORY_TOKEN:?ARTIFACTORY_TOKEN is required}"

if [[ "${PACKAGE_MANAGER}" != "pip" ]]; then
  echo "Only PACKAGE_MANAGER=pip is supported in this MVP"
  exit 1
fi

PYTHON_COMMAND="${PYTHON_COMMAND:-python}"

OUTPUT_DIR="outputs/${REQUEST_ID}"
mkdir -p "${OUTPUT_DIR}"

if [[ -f "${REQUEST_DIR}/request-metadata.json" ]]; then
  cp "${REQUEST_DIR}/request-metadata.json" "${OUTPUT_DIR}/request-metadata.json"
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

PIP_CONF="${TMP_DIR}/pip.conf"

cat > "${PIP_CONF}" <<EOF_INNER
[global]
index-url = https://${ARTIFACTORY_USER}:${ARTIFACTORY_TOKEN}@${ARTIFACTORY_HOST}/artifactory/api/pypi/${ARTIFACTORY_REPO}/simple
trusted-host = ${ARTIFACTORY_HOST}
disable-pip-version-check = true
EOF_INNER

echo "Request ID: ${REQUEST_ID}"
echo "Workload type: ${WORKLOAD_TYPE}"
echo "Container image: ${CONTAINER_IMAGE}"
echo "Package manager: ${PACKAGE_MANAGER}"
echo "Artifactory repo: ${ARTIFACTORY_REPO}"
echo "Python command: ${PYTHON_COMMAND}"

echo "Pulling container image..."
docker pull "${CONTAINER_IMAGE}"

echo "Running dependency ingestion inside container image..."

docker run --rm \
  -v "$PWD/${REQUEST_DIR}/requirements.txt:/tmp/requirements.txt:ro" \
  -v "$PWD/${OUTPUT_DIR}:/tmp/output" \
  -v "${PIP_CONF}:/etc/pip.conf:ro" \
  "${CONTAINER_IMAGE}" \
  bash -lc "
    set -euo pipefail

    echo 'Runtime Python information'
    ${PYTHON_COMMAND} --version
    ${PYTHON_COMMAND} -m pip --version
    which ${PYTHON_COMMAND} || true

    {
      echo 'PYTHON_VERSION:'
      ${PYTHON_COMMAND} --version
      echo 'PIP_VERSION:'
      ${PYTHON_COMMAND} -m pip --version
      echo 'PYTHON_PATH:'
      which ${PYTHON_COMMAND} || true
    } > /tmp/output/image-python-info.txt

    echo 'Installing requirements from Artifactory inside container image...'
    ${PYTHON_COMMAND} -m pip install -r /tmp/requirements.txt

    echo 'Capturing resolved environment from container image...'
    ${PYTHON_COMMAND} -m pip freeze > /tmp/output/resolved-requirements.txt
  " 2>&1 | tee "${OUTPUT_DIR}/runtime-ingestion.log"

cat > "${OUTPUT_DIR}/ingestion-result.json" <<EOF_INNER
{
  "request_id": "${REQUEST_ID}",
  "status": "passed",
  "workload_type": "${WORKLOAD_TYPE}",
  "container_image": "${CONTAINER_IMAGE}",
  "python_command": "${PYTHON_COMMAND}",
  "package_manager": "${PACKAGE_MANAGER}",
  "artifactory_repo": "${ARTIFACTORY_REPO}",
  "outputs": {
    "resolved_requirements": "${OUTPUT_DIR}/resolved-requirements.txt",
    "runtime_ingestion_log": "${OUTPUT_DIR}/runtime-ingestion.log",
    "image_python_info": "${OUTPUT_DIR}/image-python-info.txt"
  }
}
EOF_INNER

echo "Dependency ingestion passed for ${REQUEST_ID}"
