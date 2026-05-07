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

source "${REQUEST_DIR}/request.properties"

: "${REQUEST_ID:?REQUEST_ID is required}"
: "${WORKLOAD_TYPE:?WORKLOAD_TYPE is required}"
: "${CONTAINER_IMAGE:?CONTAINER_IMAGE is required}"
: "${PACKAGE_MANAGER:?PACKAGE_MANAGER is required}"
: "${ARTIFACTORY_REPO:?ARTIFACTORY_REPO is required}"
: "${ARTIFACTORY_HOST:?ARTIFACTORY_HOST is required}"
: "${ARTIFACTORY_USER:?ARTIFACTORY_USER is required}"
: "${ARTIFACTORY_TOKEN:?ARTIFACTORY_TOKEN is required}"

STATUS="failed"
ERROR_STEP="initialization"

OUTPUT_DIR="outputs/${REQUEST_ID}"
mkdir -p "${OUTPUT_DIR}"

write_result_json() {
  cat > "${OUTPUT_DIR}/ingestion-result.json" <<EOF_INNER
{
  "request_id": "${REQUEST_ID}",
  "status": "${STATUS}",
  "error_step": "${ERROR_STEP}",
  "workload_type": "${WORKLOAD_TYPE}",
  "container_image": "${CONTAINER_IMAGE}",
  "python_command": "${PYTHON_COMMAND}",
  "package_manager": "${PACKAGE_MANAGER}",
  "artifactory_repo": "${ARTIFACTORY_REPO}",
  "outputs": {
    "resolved_requirements": "${OUTPUT_DIR}/resolved-requirements.txt",
    "runtime_ingestion_log": "${OUTPUT_DIR}/runtime-ingestion.log",
    "image_python_info": "${OUTPUT_DIR}/image-python-info.txt",
    "resolved_conda_environment": "${OUTPUT_DIR}/resolved-environment.yml"
  }
}
EOF_INNER
}

on_error() {
  write_result_json
}

trap on_error ERR

if [[ "${PACKAGE_MANAGER}" != "pip" && "${PACKAGE_MANAGER}" != "conda" ]]; then
  echo "Only PACKAGE_MANAGER=pip or PACKAGE_MANAGER=conda is supported"
  exit 1
fi

if [[ "${PACKAGE_MANAGER}" == "pip" && ! -f "${REQUEST_DIR}/requirements.txt" ]]; then
  echo "Missing required file for pip: ${REQUEST_DIR}/requirements.txt"
  exit 1
fi

CONDA_REQUIREMENTS_FILE=""
if [[ "${PACKAGE_MANAGER}" == "conda" ]]; then
  CONDA_FILE_COUNT=0
  [[ -f "${REQUEST_DIR}/conda-requirements.txt" ]] && CONDA_FILE_COUNT=$((CONDA_FILE_COUNT + 1))
  [[ -f "${REQUEST_DIR}/environment.yml" ]] && CONDA_FILE_COUNT=$((CONDA_FILE_COUNT + 1))
  [[ -f "${REQUEST_DIR}/environment.yaml" ]] && CONDA_FILE_COUNT=$((CONDA_FILE_COUNT + 1))

  if [[ "${CONDA_FILE_COUNT}" -gt 1 ]]; then
    echo "Multiple conda dependency files found. Provide exactly one of: conda-requirements.txt, environment.yml, environment.yaml"
    ERROR_STEP="input_validation"
    exit 1
  fi

  if [[ -f "${REQUEST_DIR}/conda-requirements.txt" ]]; then
    CONDA_REQUIREMENTS_FILE="conda-requirements.txt"
  elif [[ -f "${REQUEST_DIR}/environment.yml" ]]; then
    CONDA_REQUIREMENTS_FILE="environment.yml"
  elif [[ -f "${REQUEST_DIR}/environment.yaml" ]]; then
    CONDA_REQUIREMENTS_FILE="environment.yaml"
  else
    echo "Missing conda dependency file. Provide one of: conda-requirements.txt, environment.yml, environment.yaml"
    exit 1
  fi
fi

PYTHON_COMMAND="${PYTHON_COMMAND:-python}"
CONDA_ENV_NAME="${CONDA_ENV_NAME:-base}"

if [[ -f "${REQUEST_DIR}/request-metadata.json" ]]; then
  cp "${REQUEST_DIR}/request-metadata.json" "${OUTPUT_DIR}/request-metadata.json"
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

PIP_CONF="${TMP_DIR}/pip.conf"
CONDARC="${TMP_DIR}/condarc"

cat > "${PIP_CONF}" <<EOF_INNER
[global]
index-url = https://${ARTIFACTORY_USER}:${ARTIFACTORY_TOKEN}@${ARTIFACTORY_HOST}/artifactory/api/pypi/${ARTIFACTORY_REPO}/simple
trusted-host = ${ARTIFACTORY_HOST}
disable-pip-version-check = true
EOF_INNER

cat > "${CONDARC}" <<EOF_INNER
channels:
  - https://${ARTIFACTORY_USER}:${ARTIFACTORY_TOKEN}@${ARTIFACTORY_HOST}/artifactory/api/conda/${ARTIFACTORY_REPO}
channel_priority: flexible
always_yes: true
EOF_INNER

echo "Request ID: ${REQUEST_ID}"
echo "Workload type: ${WORKLOAD_TYPE}"
echo "Container image: ${CONTAINER_IMAGE}"
echo "Package manager: ${PACKAGE_MANAGER}"
echo "Artifactory repo: ${ARTIFACTORY_REPO}"
echo "Python command: ${PYTHON_COMMAND}"
echo "Conda env name: ${CONDA_ENV_NAME}"

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker CLI is required but was not found in PATH"
  ERROR_STEP="preflight"
  exit 1
fi

ERROR_STEP="docker_pull"
echo "Pulling container image..."
docker pull "${CONTAINER_IMAGE}"

ERROR_STEP="docker_run"
echo "Running dependency ingestion inside container image..."

if [[ "${PACKAGE_MANAGER}" == "pip" ]]; then
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

      echo 'Installing pip requirements from Artifactory inside container image...'
      ${PYTHON_COMMAND} -m pip install -r /tmp/requirements.txt

      echo 'Capturing resolved pip environment from container image...'
      ${PYTHON_COMMAND} -m pip freeze > /tmp/output/resolved-requirements.txt
    " 2>&1 | tee "${OUTPUT_DIR}/runtime-ingestion.log"
else
  docker run --rm \
    -v "$PWD/${REQUEST_DIR}/${CONDA_REQUIREMENTS_FILE}:/tmp/conda-input:ro" \
    -v "$PWD/${OUTPUT_DIR}:/tmp/output" \
    -v "${CONDARC}:/root/.condarc:ro" \
    "${CONTAINER_IMAGE}" \
    bash -lc "
      set -euo pipefail
      CONDA_INPUT_FILE=${CONDA_REQUIREMENTS_FILE}

      if ! command -v conda >/dev/null 2>&1; then
        echo 'Conda is not installed in this container image'
        exit 1
      fi

      echo 'Runtime Conda information'
      conda --version
      conda info

      {
        echo 'CONDA_VERSION:'
        conda --version
      } > /tmp/output/image-python-info.txt

      echo 'Installing conda requirements from Artifactory inside container image...'
      if [[ "${CONDA_INPUT_FILE}" == *.yml || "${CONDA_INPUT_FILE}" == *.yaml ]]; then
        conda env update -n ${CONDA_ENV_NAME} -f /tmp/conda-input
      else
        conda install -n ${CONDA_ENV_NAME} --file /tmp/conda-input
      fi

      echo 'Capturing resolved conda environment from container image...'
      conda list -n ${CONDA_ENV_NAME} > /tmp/output/resolved-requirements.txt
      conda env export -n ${CONDA_ENV_NAME} > /tmp/output/resolved-environment.yml
    " 2>&1 | tee "${OUTPUT_DIR}/runtime-ingestion.log"
fi

STATUS="passed"
ERROR_STEP="none"
write_result_json

echo "Dependency ingestion passed for ${REQUEST_ID}"
