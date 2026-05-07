# Container Image Python Dependency Ingestion MVP

This repository provides a CodeBuild-compatible MVP for ingesting Python dependencies into Artifactory by installing a request's `requirements.txt` inside a declared container image.

## Repository structure

- `buildspec.yml` - CodeBuild pipeline definition.
- `scripts/ingest_container_image_pip.sh` - Ingestion script.
- `requests/req-001-sample-training/` - Sample request input.

## Request contract

Each request directory must contain:

- `request.properties`
- `requirements.txt`

Optional:

- `request-metadata.json`

Required `request.properties` values:

- `REQUEST_ID`
- `WORKLOAD_TYPE`
- `CONTAINER_IMAGE`
- `PACKAGE_MANAGER` (`pip` only)
- `ARTIFACTORY_REPO`

Environment variables required at runtime:

- `ARTIFACTORY_HOST`
- `ARTIFACTORY_USER`
- `ARTIFACTORY_TOKEN`

Optional in `request.properties`:

- `PYTHON_COMMAND` (defaults to `python`)

## How it works

1. Validates request inputs.
2. Loads request properties.
3. Builds an ephemeral `pip.conf` with Artifactory credentials.
4. Pulls the container image.
5. Runs `pip install -r requirements.txt` inside the container image.
6. Captures Python runtime info and `pip freeze` output.
7. Writes results to `outputs/<REQUEST_ID>/`.

## Output files

- `outputs/<REQUEST_ID>/runtime-ingestion.log`
- `outputs/<REQUEST_ID>/image-python-info.txt`
- `outputs/<REQUEST_ID>/resolved-requirements.txt`
- `outputs/<REQUEST_ID>/ingestion-result.json`
- `outputs/<REQUEST_ID>/request-metadata.json` (if provided)

## Run locally

```bash
export ARTIFACTORY_HOST=artifactory.example.com
export ARTIFACTORY_USER=your-user
export ARTIFACTORY_TOKEN=your-token

./scripts/ingest_container_image_pip.sh requests/req-001-sample-training
```
