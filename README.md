# Container Image Python Dependency Ingestion MVP

This repository provides a CodeBuild-compatible MVP for ingesting Python and Conda dependencies into Artifactory by installing request-defined dependencies inside a declared container image.

## Repository structure

- `buildspec.yml` - CodeBuild pipeline definition.
- `scripts/ingest_container_image_pip.sh` - Ingestion script (supports `pip` and `conda`).
- `requests/req-001-sample-training/` - Sample request input (includes pip + conda dependency examples).

## Request contract

Each request directory must contain:

- `request.properties`

For `PACKAGE_MANAGER=pip`:

- `requirements.txt`

For `PACKAGE_MANAGER=conda`:

- `conda-requirements.txt` **or** `environment.yml` **or** `environment.yaml`

The sample request folder includes `requirements.txt`, `conda-requirements.txt`, and `environment.yml` so you can switch `PACKAGE_MANAGER` and test either path.

Optional:

- `request-metadata.json`

Required `request.properties` values:

- `REQUEST_ID`
- `WORKLOAD_TYPE`
- `CONTAINER_IMAGE`
- `PACKAGE_MANAGER` (`pip` or `conda`)
- `ARTIFACTORY_REPO`

Environment variables required at runtime:

- `ARTIFACTORY_HOST`
- `ARTIFACTORY_USER`
- `ARTIFACTORY_TOKEN`

Optional in `request.properties`:

- `PYTHON_COMMAND` (defaults to `python`, used for pip workflow)

## How it works

1. Validates request inputs.
2. Loads request properties.
3. Builds an ephemeral `pip.conf` and `.condarc` with Artifactory credentials.
4. Pulls the container image.
5. For pip requests, runs `pip install -r requirements.txt` inside the container image.
6. For conda requests, runs `conda install --file conda-requirements.txt` or `conda env update -n base -f environment.yml` inside the container image.
7. Captures runtime info and resolved packages to `outputs/<REQUEST_ID>/`.


## Creating a new request batch (operator quick steps)

1. Copy the sample request folder to a new ID, for example:
   `cp -R requests/req-001-sample-training requests/req-002-my-job`
2. Update `request.properties` with your new `REQUEST_ID`, `WORKLOAD_TYPE`, `CONTAINER_IMAGE`, `PACKAGE_MANAGER`, and `ARTIFACTORY_REPO`.
3. Keep only the dependency file(s) for your manager:
   - `pip` -> `requirements.txt`
   - `conda` -> `conda-requirements.txt` or `environment.yml`/`environment.yaml`
4. Optionally update `request-metadata.json` for audit context.
5. Run the script against the new request directory:
   `./scripts/ingest_container_image_pip.sh requests/<new-request-id>`
6. Collect results from `outputs/<new-request-id>/`.

## Output files

- `outputs/<REQUEST_ID>/runtime-ingestion.log`
- `outputs/<REQUEST_ID>/image-python-info.txt`
- `outputs/<REQUEST_ID>/resolved-requirements.txt`
- `outputs/<REQUEST_ID>/ingestion-result.json`
- `outputs/<REQUEST_ID>/request-metadata.json` (if provided)


## Run in AWS CodeBuild

1. Create a CodeBuild project from this repository.
2. Enable **Privileged** mode (Docker required for `docker pull`/`docker run`).
3. Use `buildspec.yml` from the repo root.
4. Set env vars/secrets in the project:
   - `REQUEST_DIR` (example: `requests/req-001-sample-training`)
   - `ARTIFACTORY_HOST`
   - `ARTIFACTORY_USER` (secret)
   - `ARTIFACTORY_TOKEN` (secret)
5. Start a build; artifacts are written under `outputs/<REQUEST_ID>/` and exported by `buildspec.yml`.

## Run locally

```bash
export ARTIFACTORY_HOST=artifactory.example.com
export ARTIFACTORY_USER=your-user
export ARTIFACTORY_TOKEN=your-token

./scripts/ingest_container_image_pip.sh requests/req-001-sample-training
```
