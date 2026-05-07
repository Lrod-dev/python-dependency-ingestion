# DEVELOPMENT.md

## Purpose

This document describes a practical path to evolve this MVP into a repeatable **CodePipeline + CodeBuild** workflow for dependency certification batches, while managing AWS resources via **CloudFormation deploy/change sets**.

## Target operating model

- **Infrastructure lifecycle**: managed separately with CloudFormation (`deploy` + change sets).
- **Batch execution lifecycle**: handled by CodePipeline triggering CodeBuild to run ingestion scripts for new request batches.
- **Pipeline scope**: run certification ingestion jobs; **not** provision or mutate infrastructure.

## Recommended architecture

1. **Source stage (CodePipeline)**
   - Source: GitHub/CodeCommit branch containing `requests/`, `scripts/`, `buildspec.yml`.
   - Trigger: commit/push (or manual).
2. **Build stage (CodeBuild)**
   - Runs `./scripts/ingest_container_image_pip.sh` for one or more request folders.
   - Requires Docker-in-Docker capability (privileged mode) to run target container images.
3. **Artifacts/output**
   - Publish `outputs/**` as build artifacts.
   - Optional: additionally push logs and outputs to an S3 audit bucket.

## CloudFormation stacks (minimal split)

Use separate stacks (or nested stacks) to keep ownership clear:

- `dep-ingestion-shared`:
  - S3 artifact bucket(s)
  - KMS key (optional but recommended)
- `dep-ingestion-build`:
  - CodeBuild project
  - CodeBuild service role + policies (ECR pull, Secrets Manager read, S3 artifact access, logs)
- `dep-ingestion-pipeline`:
  - CodePipeline
  - CodePipeline role + policies

This separation allows safe updates (e.g., pipeline edits) without touching shared storage/security primitives.

## Suggested CloudFormation resources

- `AWS::S3::Bucket` (artifact/audit)
- `AWS::IAM::Role` + `AWS::IAM::Policy` (CodeBuild and CodePipeline)
- `AWS::CodeBuild::Project`
- `AWS::CodePipeline::Pipeline`
- `AWS::SecretsManager::Secret` (or references to existing secrets)
- `AWS::Logs::LogGroup`
- Optional: `AWS::KMS::Key` for S3/Logs encryption

## Runtime requirements for CodeBuild

- `Environment.PrivilegedMode: true` (required for `docker pull` and `docker run` in this MVP)
- Environment variables / secrets:
  - `ARTIFACTORY_HOST`
  - `ARTIFACTORY_USER` (secret)
  - `ARTIFACTORY_TOKEN` (secret)
- Build image with Docker + bash available.

## Handling new certification batches

Two common patterns:

1. **One request per pipeline execution**
   - Pass `REQUEST_DIR` as a CodeBuild env var override.
   - Good for isolation and per-request traceability.
2. **Batch mode in one execution**
   - Add a lightweight wrapper script to iterate `requests/<batch-id>/*`.
   - Good for throughput; ensure failures are clearly attributed per request.

For MVP-to-production progression, start with **one request per run** for easier operational debugging.

## Buildspec strategy

- Keep `buildspec.yml` for default sample execution.
- For pipeline use, either:
  - override `REQUEST_DIR` per run, or
  - add `buildspec.pipeline.yml` for multi-request logic.

## CloudFormation deployment workflow (operator)

1. Validate templates:
   - `aws cloudformation validate-template --template-body file://infra/<template>.yaml`
2. Create change set:
   - `aws cloudformation deploy --stack-name <name> --template-file infra/<template>.yaml --no-execute-changeset ...`
3. Review change set in console/CLI.
4. Execute change set.
5. Confirm stack outputs (pipeline ARN, build project name, artifact bucket).

## Security and governance notes

- Scope IAM permissions to least privilege:
  - read-only for required secrets,
  - pull-only for required registries,
  - write-only to approved artifact locations.
- Avoid printing credentials in logs.
- Consider branch protections and manual approval stage for production branches.

## Practical next implementation steps

1. Add `infra/` folder with baseline templates for CodeBuild and CodePipeline.
2. Parameterize templates for repo/branch, artifact bucket, secret names, and environment.
3. Add optional wrapper script for batch runs and standardized failure summary output.
4. Add a small runbook for operations (`RUNBOOK.md`) covering reruns, partial failures, and rollback.
