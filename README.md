# shared-pipelines

A centralized GitHub Actions reusable workflows repository for Terraform, Python, and Infrastructure-as-Code projects. This repository is the single source of truth for all CI/CD pipeline logic across the organization.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture](#2-architecture)
3. [Quick Start](#3-quick-start)
4. [Workflows Reference](#4-workflows-reference)
   - [shared-lint.yml](#41-shared-lintyml)
   - [shared-security.yml](#42-shared-securityyml)
   - [shared-terraform.yml](#43-shared-terraformyml)
   - [shared-cost.yml](#44-shared-costyml)
   - [scheduled-security.yml](#45-scheduled-securityyml)
5. [Configuration Files Reference](#5-configuration-files-reference)
6. [Security Design](#6-security-design)
7. [Caching Strategy](#7-caching-strategy)
8. [Path-Based Filtering](#8-path-based-filtering)
9. [Local Development](#9-local-development)
10. [Versioning and Release Process](#10-versioning-and-release-process)
11. [Branch Protection Setup](#11-branch-protection-setup)
12. [Troubleshooting](#12-troubleshooting)
13. [Contributing](#13-contributing)
14. [Rollout Plan](#14-rollout-plan)
15. [Metrics and SLOs](#15-metrics-and-slos)

---

## 1. Overview

### What this is

`shared-pipelines` is a GitHub Actions reusable workflows repository. It contains a curated set of CI/CD workflows that any repository in the organization can call via 

`uses: shaposhnikoff/my_shared_pipeline/.github/workflows/<workflow>.yml@main`.

The consuming repository does not define any pipeline logic itself — it delegates entirely to the workflows defined here.

### Why it exists

Without a shared pipeline, each repository independently defines its own CI/CD workflows. This creates three compounding problems:

- **Drift**: teams use different versions of the same tools, or skip checks entirely.
- **Toil**: fixing a lint rule or bumping a tool version requires opening PRs in every repository.
- **Inconsistent security posture**: one repository might pin action SHAs while another uses `@main`, and security checks may differ in severity thresholds.

`shared-pipelines` solves all three problems by centralizing workflow definitions. When a fix or improvement is merged here, every consuming repository picks it up automatically on the next pipeline run without any changes on their end.

### What problem it solves

| Problem | Without shared-pipelines | With shared-pipelines |
|---|---|---|
| Tool version drift | Each team pins their own versions | One place to update |
| Security check gaps | Optional per team | Enforced for all repos |
| Onboarding time | Hours of CI/CD setup | Copy one `ci.yml` file |
| Secret leak risk | Inconsistent scanning | gitleaks on every PR |
| Cloud credential hygiene | Static IAM keys common | 100% OIDC enforced |
| Cost visibility | None | Infracost on every Terraform PR |

---

## 2. Architecture

### Repository structure

```
shared-pipelines/                      ← this repository
├── .github/
│   ├── dependabot.yml                 ← weekly SHA + pip updates
│   └── workflows/
│       ├── shared-lint.yml            ← reusable: all linters
│       ├── shared-security.yml        ← reusable: checkov + trivy + SARIF
│       ├── shared-terraform.yml       ← reusable: tf fmt/validate/tflint
│       ├── shared-cost.yml            ← reusable: infracost PR comment
│       └── scheduled-security.yml     ← scheduled: weekday full scan
├── .checkov.yml                       ← checkov configuration
├── .gitleaks.toml                     ← gitleaks rules (default + custom)
├── .pre-commit-config.yaml            ← local pre-commit mirrors CI
├── .tflint.hcl                        ← tflint plugins + rules
├── .yamllint.yml                      ← yamllint rules
├── requirements-lint.txt              ← pinned Python linter versions
└── ruff.toml                          ← ruff + format configuration

calling-repo/                          ← any product repository
└── .github/
    └── workflows/
        └── ci.yml                     ← calls shared workflows via `uses:`
```

### Calling pattern

Each product repository contains a single `ci.yml` that delegates all work to this repository. No pipeline logic lives in the product repository.

```
shaposhnikoff/my_shared_pipeline/.github/workflows/ci.yml
    │
    ├── uses: shaposhnikoff/my_shared_pipeline/.github/workflows/shared-lint.yml@v1
    ├── uses: shaposhnikoff/my_shared_pipeline/.github/workflows/shared-terraform.yml@v1
    ├── uses: shaposhnikoff/my_shared_pipeline/.github/workflows/shared-security.yml@v1
    └── uses: shaposhnikoff/my_shared_pipeline/.github/workflows/shared-cost.yml@v1
```


### Pipeline flow

The pipeline is ordered deliberately. Fast, cheap checks run first. Expensive checks run only after earlier stages pass. The cost estimation is advisory and never blocks a merge.

```
PR opened / updated
        │
        ▼
┌───────────────────┐
│   changes job     │  dorny/paths-filter
│   (always runs)   │  detects terraform / python / docker changes
└────────┬──────────┘
         │ outputs: terraform=true|false, python=true|false, docker=true|false
         ▼
┌───────────────────────────────────────────────────────────┐
│  Stage 1 + 2: LINT  (BLOCKING)  ~1–5 min                 │
│                                                           │
│  Runs only if terraform OR python OR docker changed       │
│                                                           │
│  Jobs (parallel):                                         │
│    secrets      — gitleaks full history scan              │
│    yaml-lint    — yamllint                                │
│    python-lint  — ruff + black --check + bandit           │
│    shell-lint   — shellcheck                              │
│    dockerfile-lint — hadolint                             │
│    terraform-lint  — fmt -check + init -backend=false     │
│                      + validate + tflint                  │
└────────┬──────────────────────────────────────────────────┘
         │ all lint jobs passed
         ▼
┌─────────────────────────┐     ┌──────────────────────────┐
│  Stage 3a: TERRAFORM    │     │  Stage 3b: SECURITY      │
│  (BLOCKING)  ~5–10 min  │     │  (BLOCKING)  ~5–10 min   │
│                         │     │                          │
│  terraform fmt -check   │     │  checkov (HIGH/CRITICAL)  │
│  terraform init         │     │  trivy SCA (advisory)    │
│  terraform validate     │     │  SARIF → Security tab    │
│  tflint                 │     │                          │
│  optional OIDC AWS auth │     │                          │
└─────────┬───────────────┘     └────────────┬─────────────┘
          │                                  │
          └──────────────┬───────────────────┘
                         │ both passed
                         ▼
              ┌──────────────────────┐
              │  Stage 4: COST       │
              │  (ADVISORY)  ~2–3 min│
              │  PR only             │
              │                      │
              │  infracost breakdown  │
              │  (base branch)        │
              │  infracost diff       │
              │  (PR vs base)         │
              │  PR comment updated   │
              └──────────────────────┘
```

**Dependency chain:** `lint` → `terraform` + `security` (parallel) → `cost`

### Tools matrix

| Stage | Tool | Blocking | Severity threshold | Purpose |
|---|---|---|---|---|
| 1 | gitleaks | YES | any | Secrets in code and full git history |
| 1 | yamllint | YES | any | YAML syntax and style |
| 2 | ruff | YES | any | Python lint, isort, pyflakes |
| 2 | black --check | YES | any | Python formatting |
| 2 | bandit | YES | HIGH + HIGH confidence | Python security issues |
| 2 | shellcheck | YES | any | Bash/sh script issues |
| 2 | hadolint | YES | any | Dockerfile best practices |
| 3 | terraform fmt -check | YES | any | Terraform formatting |
| 3 | terraform validate | YES | any | Terraform syntax and references |
| 3 | tflint | YES | any | Terraform naming, documentation, best practices |
| 3 | checkov | YES | HIGH, CRITICAL | IaC security misconfigurations |
| 4 | infracost diff | NO | — | Cost delta shown as PR comment |
| 4 | trivy | NO | MEDIUM and above in SARIF | SCA: CVEs in dependencies and OS packages |

---

## 3. Quick Start

This section covers everything needed to onboard a new repository. The process takes approximately 15 minutes.

### Prerequisites

Before starting, confirm the following:

- You have admin access to the repository you are onboarding.
- The `org/shared-pipelines` repository is visible to your repository (same GitHub organization, or visibility set to `internal` or `public`).
- If your repository contains Terraform code and you want OIDC AWS authentication: an IAM OIDC provider for GitHub Actions is already configured in your AWS account. See [Section 6 — OIDC Setup](#oidc-setup-aws) if it is not.
- If you want cost estimation: the `INFRACOST_API_KEY` secret is set at the organization level (or repository level).

### Step 1 — Create the calling workflow

Create the file `.github/workflows/ci.yml` in your repository with the following content. Adjust the `working-directory` and `terraform-dir` paths to match your repository layout, and replace `org` with your GitHub organization name.

<details>
<summary>Full ci.yml — click to expand</summary>

```yaml
# .github/workflows/ci.yml
name: CI

on:
  pull_request:
    branches: [main, develop]
  push:
    branches: [main]

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.head_ref || github.ref }}
  cancel-in-progress: true

jobs:
  # ── Path-based filtering ────────────────────────────────────────────────────
  # Determines what changed so downstream jobs only run when relevant.
  changes:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    permissions:
      contents: read
      pull-requests: read
    outputs:
      terraform: ${{ steps.filter.outputs.terraform }}
      python: ${{ steps.filter.outputs.python }}
      docker: ${{ steps.filter.outputs.docker }}
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2
      - uses: dorny/paths-filter@de90cc6fb38fc0963ad72b210f1f284cd68cea36  # v3.0.2
        id: filter
        with:
          filters: |
            terraform:
              - 'terraform/**'
              - '**/*.tf'
              - '**/*.tfvars'
            python:
              - '**/*.py'
              - 'requirements*.txt'
            docker:
              - '**/Dockerfile*'
              - '**/*.dockerfile'

  # ── Stage 1+2: Lint (BLOCKING) ─────────────────────────────────────────────
  lint:
    needs: changes
    if: >
      needs.changes.outputs.terraform == 'true' ||
      needs.changes.outputs.python == 'true' ||
      needs.changes.outputs.docker == 'true'
    uses: shaposhnikoff/my_shared_pipeline/.github/workflows/shared-lint.yml@v1
    with:
      python-version: "3.11"
      terraform-version: "1.9.x"
      working-directory: "./terraform"
    secrets: inherit

  # ── Stage 3a: Terraform validation (BLOCKING) ──────────────────────────────
  terraform:
    needs: lint
    if: needs.changes.outputs.terraform == 'true'
    uses: shaposhnikoff/my_shared_pipeline/.github/workflows/shared-terraform.yml@v1
    with:
      working-directory: "./terraform"
      aws-role-arn: ${{ vars.AWS_ROLE_ARN }}
    secrets: inherit

  # ── Stage 3b: Security scanning (BLOCKING for checkov) ─────────────────────
  security:
    needs: lint
    uses: shaposhnikoff/my_shared_pipeline/.github/workflows/shared-security.yml@v1
    with:
      working-directory: "./terraform"
      fail-on-severity: "HIGH"
    secrets: inherit

  # ── Stage 4: Cost estimation (ADVISORY) ────────────────────────────────────
  cost:
    needs: [terraform, security]
    if: github.event_name == 'pull_request'
    uses: shaposhnikoff/my_shared_pipeline/.github/workflows/shared-cost.yml@v1
    with:
      terraform-dir: "./terraform"
      aws-role-arn: ${{ vars.AWS_ROLE_ARN }}
    secrets:
      infracost-api-key: ${{ secrets.INFRACOST_API_KEY }}
```

</details>

### Step 2 — Set repository variables and secrets

In your repository, go to **Settings → Secrets and variables → Actions**.

| Type | Name | Value | Required when |
|---|---|---|---|
| Variable | `AWS_ROLE_ARN` | `arn:aws:iam::123456789012:role/github-actions-ci` | Terraform uses AWS |
| Secret | `INFRACOST_API_KEY` | Your Infracost API key | Cost estimation enabled |

> **Note:** If `INFRACOST_API_KEY` is set at the organization level, you do not need to set it per repository.

### Step 3 — Configure branch protection

After the first successful pipeline run, add the required status checks. See [Section 11 — Branch Protection Setup](#11-branch-protection-setup) for exact steps.

### Step 4 — Install pre-commit hooks (optional but strongly recommended)

```bash
pip install pre-commit
pre-commit install
```

This runs the same checks locally before you push. See [Section 9 — Local Development](#9-local-development) for details.

### Step 5 — Open a pull request

Create a branch, make any change, and open a pull request. The pipeline will trigger automatically. On the first run, the `tflint` plugin cache will be cold and the run will take slightly longer than subsequent runs.

---

## 4. Workflows Reference

### 4.1 shared-lint.yml

**Description:** Runs all linters across secrets, YAML, Python, shell scripts, Dockerfiles, and Terraform. All jobs in this workflow are blocking — a failure in any job prevents the PR from merging. Jobs run in parallel for speed.

**Trigger:** `workflow_call` only (called from product repositories).

**Default permissions:** `contents: read`

**Concurrency:** `cancel-in-progress: true` — a new push cancels the previous run for the same branch.

**Timeout:** 10 minutes per job.

#### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `python-version` | string | `"3.11"` | Python version passed to `actions/setup-python`. Must match a version available on the runner. |
| `terraform-version` | string | `"1.9.x"` | Terraform version passed to `hashicorp/setup-terraform`. Use `x` as a patch wildcard. |
| `working-directory` | string | `"."` | Directory used as `defaults.run.working-directory` for Terraform jobs. Set this to the root of your Terraform code. |

#### Secrets

None. This workflow uses only `GITHUB_TOKEN` (automatically provided by GitHub Actions).

#### Jobs

| Job ID | Tool(s) | What it checks | Blocking |
|---|---|---|---|
| `secrets` | gitleaks v2.3.9 | Scans the full git history (`fetch-depth: 0`) for secrets, API keys, tokens, and credentials. Uses `.gitleaks.toml` configuration. | YES |
| `yaml-lint` | yamllint 1.35.1 | Validates YAML syntax and enforces style rules from `.yamllint.yml`. | YES |
| `python-lint` | ruff 0.4.4, black 24.4.2, bandit 1.7.8 | Lints Python code for style, formatting, and HIGH/CRITICAL security issues. | YES |
| `shell-lint` | shellcheck | Checks all `.sh` and `.bash` scripts for common errors and POSIX compliance issues. | YES |
| `dockerfile-lint` | hadolint v3.1.0 | Lints all Dockerfiles recursively for best practices. | YES |
| `terraform-lint` | terraform 1.9.x, tflint | Checks Terraform formatting (`fmt -check -recursive`), initializes without a backend (`init -backend=false`), validates syntax (`validate`), and runs tflint rules. | YES |

> **Note:** The `terraform-lint` job uses `terraform init -backend=false`. This means it does not connect to any remote state backend and does not require cloud credentials. It only validates that module references and provider configurations are syntactically correct.

---

### 4.2 shared-security.yml

**Description:** Runs checkov for IaC security misconfiguration detection and trivy for software composition analysis (SCA). Checkov findings at HIGH or CRITICAL severity are blocking. Trivy results are uploaded as SARIF and are advisory. All results appear in the repository's **Security** tab under **Code scanning alerts**.

**Trigger:** `workflow_call` only.

**Default permissions:** `contents: read`, `security-events: write` (required for SARIF upload to the GitHub Security tab).

**Concurrency:** `cancel-in-progress: true`

**Timeout:** 15 minutes per job.

#### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `working-directory` | string | `"."` | Directory scanned by checkov. Set to the root of your Terraform code or repository root. |
| `fail-on-severity` | string | `"HIGH"` | Minimum severity that causes checkov to exit non-zero. Accepted values: `LOW`, `MEDIUM`, `HIGH`, `CRITICAL`. MEDIUM and LOW are configured as `soft-fail-on` in `.checkov.yml`. |

#### Secrets

None.

#### Jobs

| Job ID | Tool(s) | What it checks | Blocking |
|---|---|---|---|
| `checkov` | checkov v20250201 | Scans Terraform, secrets, Dockerfile, and GitHub Actions workflows for security misconfigurations. Outputs SARIF to the Security tab. HIGH and CRITICAL findings fail the job. MEDIUM and LOW are soft-fail (reported but do not block). | YES (HIGH/CRITICAL) |
| `trivy` | trivy v0.30.0 | Scans the filesystem for known CVEs in dependencies (SCA). Outputs SARIF to the Security tab. `exit-code: 0` — always exits successfully regardless of findings. | NO |

**Frameworks scanned by checkov:** `terraform`, `secrets`, `dockerfile`, `github_actions`

> **Note:** SARIF files are uploaded with `if: always()`, meaning security findings are reported to the Security tab even when the job fails. This ensures findings are visible regardless of whether the workflow succeeds.

---

### 4.3 shared-terraform.yml

**Description:** Validates Terraform code quality and correctness. Optionally authenticates to AWS using OIDC before running checks. This is the workflow to use when you need Terraform to resolve remote modules or data sources that require cloud credentials.

**Trigger:** `workflow_call` only.

**Default permissions:** `contents: read`, `id-token: write` (required for OIDC token exchange with AWS).

**Concurrency:** `cancel-in-progress: false` — unlike other workflows, this one does NOT cancel in-progress runs. This prevents a mid-plan interruption from leaving a Terraform state lock orphaned in the backend.

**Timeout:** 20 minutes.

#### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `terraform-version` | string | `"1.9.x"` | Terraform version to install. |
| `working-directory` | string | `"."` | Terraform root directory. |
| `aws-role-arn` | string | `""` | IAM role ARN to assume via OIDC. If empty, AWS authentication is skipped. Example: `arn:aws:iam::123456789012:role/github-actions-ci` |

#### Secrets

None required (uses `GITHUB_TOKEN` automatically, and OIDC for AWS if `aws-role-arn` is provided).

#### Jobs

| Job ID | Tool(s) | Steps | Blocking |
|---|---|---|---|
| `terraform` | terraform, tflint | OIDC AWS auth (if `aws-role-arn` set), `terraform fmt -check -recursive`, `terraform init -backend=false`, `terraform validate`, `tflint --recursive` | YES |

> **Warning:** Even though `cancel-in-progress: false` prevents cancellation within this workflow, it does not protect a live `terraform apply` running elsewhere. This workflow only runs validation, not apply. Never configure `apply` in a PR pipeline without a manual approval gate.

---

### 4.4 shared-cost.yml

**Description:** Estimates the cost impact of Terraform changes and posts the result as a comment on the pull request. Uses the infracost two-run pattern: first computes the cost of the base branch, then computes the cost of the PR branch, and finally posts the delta as a PR comment. The comment is updated (not re-created) on each new push to the PR.

This workflow is advisory. A failure here (for example, infracost cannot price a resource) does not block the PR from merging.

**Trigger:** `workflow_call` only. Should be called only when `github.event_name == 'pull_request'` (see the `ci.yml` example).

**Default permissions:** `contents: read`, `pull-requests: write` (required to post and update PR comments).

**Concurrency:** `cancel-in-progress: true`

**Timeout:** 15 minutes.

#### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `terraform-dir` | string | `"."` | Path to the Terraform directory. Passed to `infracost breakdown` and `infracost diff`. |
| `aws-role-arn` | string | `""` | IAM role ARN for OIDC. Required when Terraform reads remote state from S3 or uses data sources that require AWS credentials. |

#### Secrets

| Secret | Required | Description |
|---|---|---|
| `infracost-api-key` | YES | Infracost API key. Obtain from [infracost.io](https://www.infracost.io). Set as an organization secret named `INFRACOST_API_KEY`. |

#### Jobs

| Job ID | Tool(s) | Steps | Blocking |
|---|---|---|---|
| `infracost` | infracost v3 | OIDC AWS auth (optional), checkout base SHA, `infracost breakdown` to `/tmp/infracost-base.json`, checkout PR SHA, `infracost diff` comparing to base, post PR comment via `infracost comment github` CLI with `behavior: update` | NO |

**Two-run pattern explained:**

```
1. git checkout <base branch SHA>
   infracost breakdown --path . --format json --out-file /tmp/infracost-base.json
   (baseline: what does the infrastructure cost today?)

2. git checkout <PR branch SHA>
   infracost diff --path . --compare-to /tmp/infracost-base.json --format json --out-file /tmp/infracost-diff.json
   (delta: how much will this PR change the monthly cost?)

3. Post the diff as a PR comment (updates existing comment on re-push)
```

---

### 4.5 scheduled-security.yml

**Description:** Runs a full security scan on a schedule, independent of pull requests. This catches vulnerabilities introduced in dependencies after a PR merged — for example, a new CVE published today against a package that was already in `requirements.txt`. Also supports manual dispatch for on-demand scanning.

**Trigger:** Cron schedule (`0 6 * * 1-5` — Monday through Friday at 06:00 UTC) and `workflow_dispatch` (manual trigger from the Actions tab).

**Default permissions:** `contents: read`, `security-events: write`

**Concurrency:** `cancel-in-progress: true` (group: `scheduled` — a manual dispatch cancels any in-progress scheduled run)

**Timeout:** 30 minutes. The single job runs gitleaks, checkov, and trivy sequentially on the same runner.

#### Jobs

| Job ID | Tool(s) | What it checks | Blocking |
|---|---|---|---|
| `full-security-scan` | gitleaks, checkov, trivy | Full git history secrets scan, checkov IaC misconfiguration scan (all frameworks), trivy filesystem SCA. All results uploaded as SARIF to the Security tab. | The job itself does not gate a PR (it runs on schedule). checkov soft-fail is still in effect. |

> **Note:** This workflow runs against the default branch (`main`). Results appear in the Security tab under **Code scanning alerts**. Configure alert notifications in **Settings → Security → Code security and analysis** to receive email or Slack alerts when new findings are discovered.

---

## 5. Configuration Files Reference

All configuration files live in the root of the `shared-pipelines` repository and are copied into the GitHub Actions runner workspace alongside the calling repository's code during workflow execution.

### `.yamllint.yml`

Controls YAML style enforcement. Applied by both the `yaml-lint` CI job and the local `yamllint` pre-commit hook.

```yaml
extends: default
rules:
  line-length:
    max: 120
  truthy:
    allowed-values: ['true', 'false']
```

**Key decisions:**
- `line-length: 120` — allows longer lines than the yamllint default of 80. This accommodates GitHub Actions workflow files which frequently have long `uses:` lines with SHA comments.
- `truthy: allowed-values: ['true', 'false']` — rejects ambiguous truthy values (`yes`, `no`, `on`, `off`) which have caused incidents when Kubernetes and Helm YAML files were misinterpreted.

### `ruff.toml`

Controls Python linting and formatting via ruff. Applied by the `python-lint` CI job and the `ruff` pre-commit hook.

```toml
line-length = 120
target-version = "py311"
select = ["E", "F", "I", "B", "UP"]
ignore = ["E501"]

[format]
quote-style = "double"
```

**Rule sets enabled:**
| Code | Ruleset | Description |
|---|---|---|
| `E` | pycodestyle errors | Standard PEP 8 style errors |
| `F` | pyflakes | Undefined names, unused imports |
| `I` | isort | Import ordering |
| `B` | flake8-bugbear | Common bug patterns |
| `UP` | pyupgrade | Modernize Python syntax for the target version |

**Note:** `E501` (line too long) is ignored because `line-length = 120` already enforces the limit via the formatter. Ignoring `E501` prevents double-reporting.

### `ruff.toml` — format section

`quote-style = "double"` aligns ruff's formatter with black's default behavior. Both tools must agree on quote style or they will conflict in `--check` mode.

### `.tflint.hcl`

Configures tflint plugins and rules. The plugin cache key in CI is `tflint-${{ hashFiles('.tflint.hcl') }}` — changing this file invalidates the plugin cache and triggers a fresh download.

```hcl
plugin "aws" {
  enabled = true
  version = "0.27.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

plugin "azurerm" {
  enabled = true
  version = "0.26.0"
  source  = "github.com/terraform-linters/tflint-ruleset-azurerm"
}

rule "terraform_naming_convention" { enabled = true }
rule "terraform_documented_variables" { enabled = true }
rule "terraform_documented_outputs" { enabled = true }
```

**Rules enforced:**
- `terraform_naming_convention` — enforces consistent resource naming (snake_case by default).
- `terraform_documented_variables` — every input variable must have a `description` field.
- `terraform_documented_outputs` — every output must have a `description` field.

> **Note:** Both `aws` and `azurerm` plugins are loaded regardless of which cloud a given repository uses. tflint only applies rules relevant to the resources found in the code. Loading an unused plugin does not cause failures.

### `.checkov.yml`

Configures checkov's scan scope and severity thresholds. This file is referenced by the `checkov-action` in `shared-security.yml` and `scheduled-security.yml`.

```yaml
framework:
  - terraform
  - secrets
  - dockerfile
  - github_actions
skip-check:
  - CKV_AWS_144   # cross-region replication — not required for all workloads
soft-fail-on:
  - MEDIUM
  - LOW
```

**Frameworks:**
- `terraform` — checks Terraform resource configurations (S3 encryption, security groups, IAM policies, etc.)
- `secrets` — detects hardcoded secrets in any file type
- `dockerfile` — checks Dockerfile instructions for best practices
- `github_actions` — checks GitHub Actions workflow files (unpinned actions, overly broad permissions, etc.)

**Severity model:**
- HIGH and CRITICAL: hard fail (job exits non-zero, PR is blocked).
- MEDIUM and LOW: soft fail (findings are reported in SARIF and visible in Security tab, but the job exits zero).

To add a skip for an organization-wide false positive, add the check ID to `skip-check`. To skip a check only in one repository's Terraform code, add an inline comment: `#checkov:skip=CKV_AWS_144:reason`.

### `.gitleaks.toml`

Configures gitleaks secret detection. Extends the built-in default ruleset with a custom rule for organization-internal tokens.

```toml
[extend]
useDefault = true

[[rules]]
description = "Custom: Internal API tokens"
id = "internal-api-token"
regex = '''PERISCOPE_[A-Z0-9]{32}'''
```

**`useDefault = true`** activates gitleaks's built-in 100+ rules covering AWS keys, GitHub tokens, Stripe keys, private keys, and many more.

The custom `internal-api-token` rule catches tokens with the `PERISCOPE_` prefix — an organization-specific token format that would not be detected by the default ruleset.

To add more custom rules, append additional `[[rules]]` blocks. To allowlist a known false positive, add an `[[allowlist]]` block with a `regexes` or `commits` entry.

### `requirements-lint.txt`

Pinned Python linter dependencies installed in a virtualenv on the CI runner. Pinning exact versions ensures reproducible lint results across all runs and all repositories.

```text
ruff==0.4.4
black==24.4.2
bandit==1.7.8
yamllint==1.35.1
```

Dependabot opens weekly PRs to bump these versions. Review the Dependabot PR, check the changelogs for the tools, and merge if the pipeline is green.

### `.pre-commit-config.yaml`

Mirrors the CI lint checks for local development. When installed, these hooks run automatically before each `git commit`, giving immediate feedback without waiting for a CI run.

<details>
<summary>Full .pre-commit-config.yaml — click to expand</summary>

```yaml
repos:
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.18.4
    hooks:
      - id: gitleaks

  - repo: https://github.com/adrienverge/yamllint
    rev: v1.35.1
    hooks:
      - id: yamllint
        args: [-c, .yamllint.yml]

  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: v0.4.4
    hooks:
      - id: ruff
        args: [--fix]
      - id: ruff-format

  - repo: https://github.com/psf/black
    rev: 24.4.2
    hooks:
      - id: black

  - repo: https://github.com/PyCQA/bandit
    rev: 1.7.8
    hooks:
      - id: bandit
        args: [-ll, -ii]

  - repo: https://github.com/antonbabenko/pre-commit-terraform
    rev: v1.92.0
    hooks:
      - id: terraform_fmt
      - id: terraform_validate
      - id: terraform_tflint
        args:
          - --args=--recursive
```

</details>

> **Note:** The pre-commit `ruff` hook runs with `--fix` (auto-fixes issues in place), while CI runs `ruff check .` without `--fix` (read-only check that fails if issues exist). This means pre-commit will silently fix some issues that CI would block on — always review auto-fixes before committing.

### `.github/dependabot.yml`

<details>
<summary>Full dependabot.yml — click to expand</summary>

```yaml
version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
      day: "monday"
      time: "06:00"
      timezone: "UTC"
    groups:
      actions-minor:
        patterns: ["*"]
        update-types: ["minor", "patch"]
    labels:
      - "dependencies"
      - "github-actions"
    commit-message:
      prefix: "chore(deps)"

  - package-ecosystem: "pip"
    directory: "/"
    schedule:
      interval: "weekly"
      day: "monday"
      time: "06:00"
      timezone: "UTC"
    labels:
      - "dependencies"
      - "python"
    commit-message:
      prefix: "chore(deps)"
```

</details>

Dependabot opens PRs every Monday at 06:00 UTC to update:
1. **GitHub Actions**: all action SHAs are updated when new releases are tagged. Minor and patch updates are grouped into a single PR.
2. **pip**: all packages in `requirements-lint.txt` are updated to their latest compatible versions.

---

## 6. Security Design

### SHA pinning

Every `uses:` reference in every workflow in this repository pins the action to a full 40-character git SHA, not a mutable tag like `@v4` or `@main`.

```yaml
# Correct: pinned to exact commit
- uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2

# Wrong: tag is mutable, anyone can push a new commit to v4
- uses: actions/checkout@v4
```

**Why this matters:** A mutable tag can be moved by the action's maintainer (or an attacker who compromises the maintainer's account) to point at malicious code. A SHA is immutable. This practice is called supply chain attack mitigation and is required for SLSA compliance.

The human-readable version tag is preserved as an inline comment (`# v4.2.2`) so you can understand what version is pinned without looking it up.

Dependabot automatically opens PRs to update SHAs when new versions are released, so pinning does not mean falling behind.

### Permissions model

Every workflow declares explicit `permissions:` at the top level, defaulting to the minimum required. GitHub's default for `GITHUB_TOKEN` is overly broad (`contents: write` in many cases). This repository uses the principle of least privilege.

| Permission | Granted to | Reason |
|---|---|---|
| `contents: read` | All workflows (default) | Checkout code |
| `security-events: write` | `shared-security.yml`, `scheduled-security.yml` | Upload SARIF to Security tab |
| `pull-requests: write` | `shared-cost.yml` | Post and update PR comments |
| `id-token: write` | `shared-terraform.yml`, `shared-cost.yml` | Exchange OIDC token with AWS |

> **Warning:** Never add `contents: write` unless a job needs to push commits. Never add `packages: write` unless a job needs to publish container images. If a third-party action requests these permissions without a documented reason, treat it as a red flag.

### OIDC — no static credentials

No long-lived AWS IAM access keys are stored in GitHub Secrets. AWS authentication uses OpenID Connect (OIDC). GitHub Actions generates a short-lived signed JWT that AWS exchanges for temporary STS credentials scoped to the specific IAM role.

**Benefits:**
- Credentials expire automatically (typically in 1 hour).
- No secret rotation needed.
- Credentials are bound to the repository, branch, and workflow via the OIDC claim conditions on the IAM role trust policy.

#### OIDC Setup (AWS) {#oidc-setup-aws}

Perform the following steps once per AWS account. After this, any repository can authenticate by providing `aws-role-arn` as a workflow input.

**Step 1 — Create the OIDC provider in AWS IAM:**

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

> **Note:** Run this command only once per AWS account. If an OIDC provider for `token.actions.githubusercontent.com` already exists, skip this step. Check with: `aws iam list-open-id-connect-providers`.

**Step 2 — Create the IAM role with a trust policy:**

Create a file named `trust-policy.json` with the following content. Replace `YOUR_ORG` and `YOUR_REPO` with your GitHub organization and repository names. Replace `123456789012` with your AWS account ID.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:YOUR_ORG/YOUR_REPO:*"
        }
      }
    }
  ]
}
```

```bash
aws iam create-role \
  --role-name github-actions-ci \
  --assume-role-policy-document file://trust-policy.json
```

**Step 3 — Attach the minimum necessary policy to the role:**

For read-only Terraform validation (no state backend access), attach:

```bash
aws iam attach-role-policy \
  --role-name github-actions-ci \
  --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess
```

For Terraform with S3 remote state, additionally allow:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::your-tfstate-bucket",
        "arn:aws:s3:::your-tfstate-bucket/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": ["dynamodb:GetItem"],
      "Resource": "arn:aws:dynamodb:us-east-1:123456789012:table/terraform-locks"
    }
  ]
}
```

**Step 4 — Set the role ARN as a repository variable:**

```bash
gh variable set AWS_ROLE_ARN \
  --body "arn:aws:iam::123456789012:role/github-actions-ci" \
  --repo YOUR_ORG/YOUR_REPO
```

### Dependabot for supply chain security

`.github/dependabot.yml` configures Dependabot to open weekly PRs updating:
- All action SHAs in workflow files (includes SHAs in `shared-pipelines` itself)
- All packages in `requirements-lint.txt`

Review Dependabot PRs every Monday. The pipeline runs against each Dependabot PR. If it passes, merge it. If it fails, check the changelog for the bumped tool and decide whether to skip the version or update configuration.

---

## 7. Caching Strategy

Caching reduces pipeline duration and runner egress costs. The following caches are configured:

### Cache layers

| Cache | Path | Key | Expected hit rate | Invalidated by |
|---|---|---|---|---|
| Terraform providers | `~/.terraform.d/plugin-cache` | `tf-providers-${{ hashFiles('**/.terraform.lock.hcl') }}` | High (>90%) | Changing `.terraform.lock.hcl` (provider version bump) |
| tflint plugins | `~/.tflint.d/plugins` | `tflint-${{ hashFiles('.tflint.hcl') }}` | High (>90%) | Changing `.tflint.hcl` |
| Python pip | Managed by `actions/setup-python` with `cache: pip` | Based on `requirements*.txt` hash | High (>85%) | Changing `requirements-lint.txt` or other requirements files |
| Trivy vulnerability DB | `~/.cache/trivy` | `trivy-db-${{ steps.date.outputs.date }}` (daily) | Medium (~70%) | Each calendar day (Trivy DB updates daily) |

### How caching works in practice

1. **tflint plugins** are the most impactful cache. Without caching, tflint downloads the AWS and azurerm plugins on every run (~50–100 MB). With caching, plugin initialization takes under 2 seconds.

2. **Python pip caching** is handled transparently by `actions/setup-python` when `cache: pip` is set. It hashes all `requirements*.txt` files in the repository and restores the pip cache automatically.

3. **Trivy DB** is cached per calendar day. Trivy's vulnerability database is updated multiple times per day, but re-downloading it on every run is wasteful. A daily cache key means the database is at most 24 hours stale, which is acceptable for CI scanning.

4. **Terraform providers** are only relevant if you use `terraform init` with a real backend (not `-backend=false`). For the validation workflows in this pipeline (`init -backend=false`), provider downloads are minimal. The cache is still configured for completeness and for any consuming repos that extend these workflows.

### Cache hit rate target

The SLO target is **cache hit rate > 80%** across all caches. Monitor this in the **Actions** tab by inspecting the "Cache" step logs for hit/miss messages. A miss on every run typically indicates the cache key is too specific (includes a timestamp or other volatile value).

---

## 8. Path-Based Filtering

### How it works

The `changes` job at the top of `ci.yml` uses `dorny/paths-filter` to inspect which files changed between the base branch and the PR branch. It outputs boolean flags (`true` or `false`) for each file category.

Downstream jobs use `if:` conditions on these outputs. If no relevant files changed, the job is skipped — it neither runs nor appears as a failure.

### Filter definitions

```yaml
filters: |
  terraform:
    - 'terraform/**'    # any file under a terraform/ directory
    - '**/*.tf'         # any .tf file anywhere in the repo
    - '**/*.tfvars'     # any .tfvars file anywhere in the repo
  python:
    - '**/*.py'         # any Python file
    - 'requirements*.txt'  # any requirements file
  docker:
    - '**/Dockerfile*'  # Dockerfile, Dockerfile.prod, etc.
    - '**/*.dockerfile' # files with .dockerfile extension
```

### Which jobs run for which file types

| Files changed | `lint` | `terraform` | `security` | `cost` |
|---|---|---|---|---|
| Only `.md` files | Skipped | Skipped | Always runs | Skipped (no terraform) |
| Only `.py` files | Runs | Skipped | Always runs | Skipped (no terraform) |
| Only `.tf` files | Runs | Runs | Always runs | Runs (PR only) |
| `.tf` + `.py` | Runs | Runs | Always runs | Runs (PR only) |
| `Dockerfile` | Runs | Skipped | Always runs | Skipped |
| Push to `main` (any files) | Depends on changed files | Depends | Always runs | Never (push, not PR) |

> **Note:** `security` always runs regardless of which files changed. This is intentional. A dependency file (e.g., `requirements.txt`) may not match the `terraform` or `python` filters above, but could still introduce a security issue. Running security checks unconditionally ensures no change escapes scanning.

### Customizing filters in your repository

To add a new filter category (for example, `helm` charts), modify the `filters` block in your `ci.yml`. The shared workflows themselves do not need to change — the `if:` condition on the `lint` job already supports any filter you add:

```yaml
if: >
  needs.changes.outputs.terraform == 'true' ||
  needs.changes.outputs.python == 'true' ||
  needs.changes.outputs.docker == 'true' ||
  needs.changes.outputs.helm == 'true'    # add new category here
```

---

## 9. Local Development

Running checks locally before pushing saves time and reduces pipeline noise. The pre-commit hooks in this repository mirror the CI checks exactly.

### Install pre-commit

```bash
pip install pre-commit
```

### Install hooks into your local git repository

Run this inside the repository you are working on (not inside `shared-pipelines` itself unless you are contributing to it):

```bash
pre-commit install
```

After this, every `git commit` triggers the configured hooks automatically. To run all hooks manually against all files:

```bash
pre-commit run --all-files
```

To run a specific hook:

```bash
pre-commit run gitleaks
pre-commit run ruff
pre-commit run black
pre-commit run yamllint
pre-commit run terraform_fmt
```

### Run linters manually without pre-commit

If you need to run a specific linter directly:

```bash
# Install linter dependencies in a virtual environment
python -m venv /tmp/lint-venv
/tmp/lint-venv/bin/pip install ruff==0.4.4 black==24.4.2 bandit==1.7.8 yamllint==1.35.1

# Python linting
/tmp/lint-venv/bin/ruff check .
/tmp/lint-venv/bin/black --check .
/tmp/lint-venv/bin/bandit -r . -ll -ii

# YAML linting (uses .yamllint.yml from shared-pipelines root)
/tmp/lint-venv/bin/yamllint -c .yamllint.yml .

# Shell script linting (requires shellcheck installed on your system)
shellcheck path/to/script.sh

# Dockerfile linting (requires hadolint installed on your system)
hadolint path/to/Dockerfile
```

Install hadolint on Linux:

```bash
curl -sL -o /usr/local/bin/hadolint \
  https://github.com/hadolint/hadolint/releases/download/v2.12.0/hadolint-Linux-x86_64
chmod +x /usr/local/bin/hadolint
```

### Run Terraform checks locally

```bash
# Ensure you are in the Terraform directory
cd terraform/

# Format check (read-only)
terraform fmt -check -recursive

# Auto-fix formatting issues
terraform fmt -recursive

# Initialize without connecting to a remote backend
terraform init -backend=false

# Validate configuration
terraform validate
```

Run tflint:

```bash
# Install tflint (Linux)
curl -sL https://raw.githubusercontent.com/terraform-linters/tflint/master/install_linux.sh | bash

# Initialize plugins defined in .tflint.hcl
tflint --init

# Run tflint
tflint --recursive
```

### Run gitleaks locally

```bash
# Install gitleaks
brew install gitleaks   # macOS
# or download from https://github.com/gitleaks/gitleaks/releases

# Scan the full git history
gitleaks detect --source . -v

# Scan staged files only (faster during development)
gitleaks protect --staged
```

---

## 10. Versioning and Release Process

### Version tags

Consumers always reference a major version tag, never `@main`:

```yaml
# Correct
uses: org/shared-pipelines/.github/workflows/shared-lint.yml@v1

# Wrong — main can change at any time and break consuming repos
uses: org/shared-pipelines/.github/workflows/shared-lint.yml@main
```

The major tag (`v1`) is a mutable floating tag that always points to the latest compatible release within the `v1.x.x` series. A consumer referencing `@v1` automatically receives bug fixes and new tool versions without making any changes.

### Semantic versioning

| Change type | Examples | Action |
|---|---|---|
| Patch | Bug fix, tool version bump, config tweak | Tag `v1.x.Y+1`, move `v1` forward |
| Minor | Add a new optional input, add a new advisory tool | Tag `v1.X+1.0`, move `v1` forward |
| Major (breaking) | Remove an input, change a job name (breaks required status checks), change blocking behavior | Tag `v2.0.0`, create `v2` tag, announce migration |

### Release process (step by step)

**Step 1 — Merge changes to main via PR**

All changes to `shared-pipelines` go through a PR with at least one reviewer. Never push directly to `main`.

**Step 2 — Tag the patch release**

```bash
git checkout main
git pull origin main
git tag v1.2.3
git push origin v1.2.3
```

**Step 3 — Move the floating major tag forward**

```bash
git tag -f v1
git push --force origin v1
```

The `--force` flag is required because you are moving an existing tag. This is expected and intentional for the floating major version tag.

**Step 4 — Verify consuming repos**

Trigger a pipeline run in one or two consuming repos and confirm they pick up the changes correctly.

### Handling breaking changes

If you must make a breaking change (for example, renaming a job that is a required status check):

1. Implement the change on a new major version tag (`v2`).
2. Open issues or announcements notifying consuming teams.
3. Update each consuming repo's `ci.yml` to reference `@v2` and update their branch protection required checks.
4. Keep `v1` stable for a migration period (minimum 2 weeks).
5. After all repos have migrated, archive the `v1` branch or leave it frozen.

### What consuming repos need to do for compatible changes

Nothing. If a change is compatible (inputs are the same, job names are the same), consuming repos automatically get the new behavior on their next pipeline run.

---

## 11. Branch Protection Setup

After the first successful pipeline run on a PR, configure branch protection to enforce required checks. Without this, the pipeline provides visibility but does not actually block merges.

### Required status checks

These checks must pass before any PR can merge:

| Check name | Workflow | Blocking |
|---|---|---|
| `Lint / Secrets Scan (gitleaks)` | shared-lint.yml | YES |
| `Lint / YAML Lint` | shared-lint.yml | YES |
| `Lint / Python Lint (ruff + black + bandit)` | shared-lint.yml | YES |
| `Lint / Terraform Lint (fmt + validate + tflint)` | shared-lint.yml | YES |
| `Security / Checkov (IaC security)` | shared-security.yml | YES |
| `Terraform / Terraform (fmt + validate + tflint)` | shared-terraform.yml | YES |

Advisory checks (not required, but recommended to monitor):

| Check name | Workflow |
|---|---|
| `Security / Trivy (SCA / CVE — advisory)` | shared-security.yml |
| `Cost / Infracost (cost delta)` | shared-cost.yml |

### Configure via GitHub CLI

```bash
# Install gh CLI if not already installed
# https://cli.github.com/

# Configure branch protection for the main branch
gh api \
  --method PUT \
  -H "Accept: application/vnd.github+json" \
  /repos/YOUR_ORG/YOUR_REPO/branches/main/protection \
  --input - <<'EOF'
{
  "required_status_checks": {
    "strict": true,
    "contexts": [
      "Lint / Secrets Scan (gitleaks)",
      "Lint / YAML Lint",
      "Lint / Python Lint (ruff + black + bandit)",
      "Lint / Terraform Lint (fmt + validate + tflint)",
      "Security / Checkov (IaC security)",
      "Terraform / Terraform (fmt + validate + tflint)"
    ]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "dismiss_stale_reviews": true
  },
  "restrictions": null
}
EOF
```

### Configure via GitHub UI

1. Go to your repository on GitHub.
2. Click **Settings** → **Branches**.
3. Click **Add branch protection rule** (or edit the existing rule for `main`).
4. In **Branch name pattern**, enter `main`.
5. Check **Require status checks to pass before merging**.
6. Check **Require branches to be up to date before merging**.
7. In the search box, type each check name and select it:
   - `Lint / Secrets Scan (gitleaks)`
   - `Lint / YAML Lint`
   - `Lint / Python Lint (ruff + black + bandit)`
   - `Lint / Terraform Lint (fmt + validate + tflint)`
   - `Security / Checkov (IaC security)`
   - `Terraform / Terraform (fmt + validate + tflint)`
8. Check **Require a pull request before merging**.
9. Set **Required approvals** to `1`.
10. Check **Dismiss stale pull request approvals when new commits are pushed**.
11. Check **Do not allow bypassing the above settings** (enforces rules for admins too).
12. Click **Save changes**.

> **Note:** Status check names are case-sensitive and must exactly match the `name:` field of each job. GitHub Actions forms the check name as `<caller-job-name> / <callee-job-name>`. If the checks do not appear in the search box, the pipeline must have run at least once on a PR branch in that repository.

---

## 12. Troubleshooting

This section covers the most common failure scenarios. Each entry includes how to diagnose the problem and what to do to fix it.

---

### gitleaks false positive

**Symptom:** The `Lint / Secrets Scan (gitleaks)` check fails with a finding that is not actually a secret — for example, a test fixture, a documentation example, or a randomly generated string that matches a secret pattern.

**Diagnose:** Inspect the gitleaks output in the job log. Note the rule ID and the file/line where the false positive was detected.

**Fix — Option A: allowlist a specific string or file**

Add an allowlist entry to `.gitleaks.toml` in `shared-pipelines`:

```toml
[extend]
useDefault = true

[[allowlists]]
description = "Test fixtures with example keys"
regexes = ['''AKIAIOSFODNN7EXAMPLE''']
```

Or allowlist a specific file:

```toml
[[allowlists]]
description = "Documentation examples"
paths = ['''docs/examples/.*''']
```

**Fix — Option B: inline allowlist comment in the file**

Add a `gitleaks:allow` comment on the same line as the false positive:

```python
AWS_ACCESS_KEY_ID = "AKIAIOSFODNN7EXAMPLE"  # gitleaks:allow
```

> **Warning:** Use inline allowlists sparingly. A comment that allowlists a line will also allowlist any real secret that appears on that line in the future. Prefer allowlisting by rule ID and path pattern.

---

### checkov false positive / skip rule

**Symptom:** The `Security / Checkov (IaC security)` check fails on a finding that is an intentional design choice — for example, an S3 bucket without cross-region replication because the workload does not require it.

**Diagnose:** Note the check ID in the checkov output (for example, `CKV_AWS_144`).

**Fix — Option A: skip organization-wide (all repos)**

Add the check ID to `skip-check` in `.checkov.yml` in `shared-pipelines`. Document why it is skipped with a comment.

```yaml
skip-check:
  - CKV_AWS_144   # cross-region replication not required for non-critical workloads
```

**Fix — Option B: skip in a specific Terraform resource (preferred)**

Add an inline checkov skip comment to the Terraform resource in the consuming repo:

```hcl
resource "aws_s3_bucket" "logs" {
  bucket = "my-logs-bucket"
  #checkov:skip=CKV_AWS_144:Cross-region replication not required for log storage
}
```

This is preferred because it is visible in code review, scoped to the specific resource, and does not affect other resources or other repositories.

---

### tflint plugin init failure

**Symptom:** The `Lint / Terraform Lint (fmt + validate + tflint)` or `Terraform / Terraform (fmt + validate + tflint)` check fails during tflint with an error such as `Failed to install plugin` or `The plugin source host github.com is not accessible`.

**Diagnose:** Look for network errors or rate-limiting messages in the tflint step log. Also check if the tflint plugin cache step shows a miss.

**Fix — Option A: stale cache causing version mismatch**

If the cache was restored but the plugin version changed, invalidate the cache by appending a suffix to the cache key. In `shared-lint.yml` or `shared-terraform.yml`, change:

```yaml
key: tflint-${{ hashFiles('.tflint.hcl') }}
```

to:

```yaml
key: tflint-v2-${{ hashFiles('.tflint.hcl') }}
```

The `v2` suffix ensures a fresh cache is created. Remove the suffix on the next release once the cache is warm.

**Fix — Option B: GitHub API rate limit**

tflint downloads plugins from GitHub releases. On runners with many concurrent jobs, this can hit rate limits. Add a `GITHUB_TOKEN` environment variable to the tflint init step:

```yaml
- name: TFLint init
  run: tflint --init
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

**Fix — Option C: plugin version pinned in `.tflint.hcl` does not exist**

Verify the plugin version exists on the release page. Update `.tflint.hcl` to a version that exists.

---

### infracost cannot find Terraform resources

**Symptom:** The `Cost / Infracost (cost delta)` check completes but the PR comment shows `$0/month` or reports 0 resources, even though the Terraform code clearly defines priced resources.

**Diagnose:** Check the infracost step log for warnings about unrecognized resources or parsing errors. Also verify the `terraform-dir` input points to the correct directory.

**Fix — Option A: wrong `terraform-dir`**

The most common cause. If Terraform code is in `terraform/environments/prod`, set:

```yaml
with:
  terraform-dir: "./terraform/environments/prod"
```

**Fix — Option B: resources are in a Terraform module, not the root**

infracost analyzes the root module by default. If resources are defined in child modules, infracost should still find them during `breakdown`. If it does not, run infracost locally to debug:

```bash
infracost breakdown --path ./terraform --format table
```

**Fix — Option C: AWS credentials not available for data sources**

If the Terraform code uses `data` sources that require AWS credentials (for example, to look up an AMI ID), infracost cannot fully evaluate the plan without credentials. Provide the `aws-role-arn` input to enable OIDC authentication.

**Fix — Option D: resource type not yet supported by infracost**

Some newer resource types are not yet in infracost's pricing database. Check the [infracost supported resources list](https://www.infracost.io/docs/supported_resources/). If the resource is not supported, this is expected behavior and not a bug.

---

### SARIF upload permission denied

**Symptom:** The SARIF upload step in `shared-security.yml` fails with an error such as `Resource not accessible by integration` or `403 Forbidden`.

**Diagnose:** This is a permissions issue. The workflow is attempting to write to the Security tab but does not have `security-events: write` permission.

**Fix — Check the calling workflow's permissions**

When a reusable workflow is called with `secrets: inherit`, it also inherits the caller's permissions for `GITHUB_TOKEN`. The calling `ci.yml` must not override or restrict `security-events`.

Ensure the calling workflow's top-level `permissions` block either grants `security-events: write` explicitly, or does not restrict it (reusable workflows inherit the permissions they declare in their own `permissions:` block when called via `uses:`).

If your organization has a policy restricting `security-events: write`, contact the platform team to add an exemption for the `org/shared-pipelines` reusable workflow.

**Fix — Ensure GitHub Advanced Security is enabled on the repository**

SARIF upload requires GitHub Advanced Security (GHAS) to be enabled. For private repositories, GHAS requires a license. Go to **Settings → Security → Code security and analysis** and enable **Code scanning**.

---

### OIDC auth failure

**Symptom:** The `Terraform / Terraform (fmt + validate + tflint)` or `Cost / Infracost (cost delta)` check fails at the `aws-actions/configure-aws-credentials` step with an error like `Error: Could not assume role` or `OpenIDConnect provider's HTTPS certificate doesn't match configured thumbprint`.

**Diagnose:** Check the step log for the specific AWS error code. Common errors:

- `AccessDenied: Not authorized to perform sts:AssumeRoleWithWebIdentity` — the IAM trust policy condition does not match the GitHub Actions OIDC claims for this repository.
- `InvalidIdentityToken: No OpenIDConnect provider found` — the OIDC provider was not created in this AWS account.
- Thumbprint mismatch — the OIDC provider thumbprint is outdated.

**Fix — Trust policy subject mismatch**

The trust policy condition uses a `StringLike` match on the `sub` claim. The `sub` claim for a PR workflow is:
```
repo:YOUR_ORG/YOUR_REPO:pull_request
```

For a push to main:
```
repo:YOUR_ORG/YOUR_REPO:ref:refs/heads/main
```

Use a wildcard to allow all refs:

```json
"token.actions.githubusercontent.com:sub": "repo:YOUR_ORG/YOUR_REPO:*"
```

**Fix — OIDC provider not found**

Create the OIDC provider as described in [Section 6 — OIDC Setup](#oidc-setup-aws).

**Fix — Thumbprint outdated**

Update the OIDC provider thumbprint:

```bash
aws iam update-open-id-connect-provider-thumbprint \
  --open-id-connect-provider-arn arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

---

### Cache miss / stale cache

**Symptom:** Pipeline runs are consistently slower than expected. The cache restore step shows "Cache not found" on every run. Or: a cached tool version is outdated and causes failures.

**Diagnose:** Check the cache restore step log. It will say either "Cache restored successfully" or "Cache not found for key: ...". Note the full cache key being searched.

**Fix — Cache key too volatile**

If the cache key includes something that changes on every run (like a timestamp or `github.sha`), the cache will never hit. Ensure cache keys are based only on content hashes (`hashFiles()`).

**Fix — Manually invalidate a stale cache**

```bash
# List all caches for a repository
gh api /repos/YOUR_ORG/YOUR_REPO/actions/caches

# Delete a specific cache by ID
gh api --method DELETE /repos/YOUR_ORG/YOUR_REPO/actions/caches/CACHE_ID

# Or delete by key prefix
gh api --method DELETE \
  "/repos/YOUR_ORG/YOUR_REPO/actions/caches?key=tflint-"
```

After deleting the cache, the next run will create a fresh one.

---

### Concurrency cancel killed my build

**Symptom:** A pipeline run was cancelled mid-way, not because of a failure, but because a new push to the same branch triggered a new run. The cancelled run shows "This run was cancelled" in the Actions UI.

**Explanation:** This is expected behavior. All workflows use:

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.head_ref || github.ref }}
  cancel-in-progress: true
```

When you push a new commit to a branch while a pipeline is already running for that branch, the old run is cancelled to save runner minutes and avoid queueing delays.

**Exception — Terraform workflow**

`shared-terraform.yml` uses `cancel-in-progress: false` specifically to prevent this. If a Terraform validation is running and a new push arrives, the new run waits in a queue rather than cancelling the in-progress run. This prevents a mid-run `terraform init` from leaving the runner in an inconsistent state.

**Fix — If cancellation is causing problems for your workflow**

If your consuming workflow has a job that must not be interrupted, set `cancel-in-progress: false` for that specific job's concurrency group. Be aware this creates a queue, and queued runs consume minutes while waiting.

---

## 13. Contributing

### Adding a new tool to an existing workflow

**Step 1 — Test the tool locally first.** Confirm the tool works on a representative codebase, understand its exit codes, and identify which configuration it uses.

**Step 2 — Find the SHA of the action (if adding a third-party action).** Never use a mutable tag.

```bash
# Get the SHA for a specific tag
gh api repos/OWNER/REPO/git/refs/tags/vX.Y.Z --jq '.object.sha'

# If the tag points to a tag object (annotated tag), get the underlying commit SHA
gh api repos/OWNER/REPO/git/tags/SHA --jq '.object.sha'
```

**Step 3 — Add the step to the appropriate workflow file.** Place it in the correct stage. Add `timeout-minutes:` to the step if it can hang. Add an inline SHA comment.

**Step 4 — Add configuration** to the relevant config file in the repo root (for example, a new `.toolname.yml`).

**Step 5 — Update this README.** Add the tool to the tools matrix table in Section 2 and document its configuration file in Section 5. Update the workflow reference in Section 4.

**Step 6 — Open a PR.** Get at least one review. Ensure the pipeline is green in both `shared-pipelines` and in a test calling repo.

### Modifying an existing workflow

**Step 1 — Assess the impact.** Is this a compatible change (adding an optional input, changing a non-blocking tool's behavior) or a breaking change (renaming a job, removing an input, changing a blocking threshold)?

**Step 2 — For breaking changes**, follow the major version process in [Section 10](#10-versioning-and-release-process).

**Step 3 — Test in isolation.** Create a branch in `shared-pipelines` and reference that branch directly from a test repository:

```yaml
uses: org/shared-pipelines/.github/workflows/shared-lint.yml@your-branch-name
```

> **Warning:** Never reference a branch name in a production `ci.yml`. Branch references are for testing only. Merge to `main` and cut a release before consuming repos reference the change.

**Step 4 — Merge and release** following the process in Section 10.

### Testing changes to shared-pipelines

There is no automated test suite for the workflows themselves — GitHub Actions workflows can only be tested by running them. Use this process:

1. Create a branch in `shared-pipelines` with your changes.
2. In a test repository (or a fork), temporarily change `ci.yml` to reference your branch:
   ```yaml
   uses: org/shared-pipelines/.github/workflows/shared-lint.yml@feature/your-change
   ```
3. Open a PR in the test repository and observe the pipeline behavior.
4. Revert the test repository to `@v1` (or discard the test PR).
5. Open the PR in `shared-pipelines`.

### PR process

- All PRs require at least one reviewer who is not the author.
- The PR description must state: what changed, why, and what the impact on consuming repos is.
- For tool version bumps (including Dependabot PRs): confirm the pipeline is green before merging.
- For breaking changes: the PR description must include a migration guide.
- Squash merges are preferred to keep the `main` history clean.

---

## 14. Rollout Plan

This section describes the four-week phased rollout. It is intended as a reference for teams implementing `shared-pipelines` from scratch, or for retrospective review.

### Phase 1 — Foundation (Week 1)

Goal: establish the shared-pipelines repository and connect one pilot repository.

- [ ] Create the `shared-pipelines` repository in the organization with visibility `internal`.
- [ ] Implement `shared-lint.yml` with all lint jobs (secrets, yaml, python, shell, dockerfile, terraform).
- [ ] Add configuration files: `.yamllint.yml`, `ruff.toml`, `requirements-lint.txt`, `.gitleaks.toml`, `.pre-commit-config.yaml`.
- [ ] Create the initial `v1.0.0` tag and `v1` floating tag.
- [ ] Connect one pilot repository by adding `ci.yml` referencing `@v1`.
- [ ] Verify all lint jobs pass on a sample PR in the pilot repository.
- [ ] Confirm gitleaks scans the full git history.
- [ ] Document any false positives and add allowlists.

**Success criteria:** pilot repository's PR pipeline passes all lint jobs within 5 minutes.

---

### Phase 2 — IaC and Security (Week 2)

Goal: add Terraform validation, security scanning, and OIDC authentication.

- [ ] Implement `shared-terraform.yml` with fmt, init, validate, tflint.
- [ ] Add `.tflint.hcl` with AWS and AzureRM plugins.
- [ ] Implement `shared-security.yml` with checkov and trivy.
- [ ] Add `.checkov.yml` with framework list and severity thresholds.
- [ ] Configure GitHub Advanced Security on pilot repositories (required for SARIF upload).
- [ ] Create AWS IAM OIDC provider and IAM role for the pilot repository.
- [ ] Set `AWS_ROLE_ARN` as a repository variable in the pilot repository.
- [ ] Verify SARIF findings appear in the Security tab.
- [ ] Update pilot repository's `ci.yml` to call `shared-terraform.yml` and `shared-security.yml`.
- [ ] Review initial checkov findings and add appropriate skips or fixes.

**Success criteria:** SARIF findings visible in Security tab; OIDC authentication working; no static IAM credentials in Secrets.

---

### Phase 3 — FinOps and Scheduled Scanning (Week 3)

Goal: add cost estimation and continuous background security scanning.

- [ ] Register an Infracost API key at [infracost.io](https://www.infracost.io/docs/).
- [ ] Store the API key as an organization-level secret named `INFRACOST_API_KEY`.
- [ ] Implement `shared-cost.yml` with the two-run infracost pattern.
- [ ] Update pilot repository's `ci.yml` to call `shared-cost.yml` on PRs.
- [ ] Verify the infracost PR comment appears and updates correctly on re-push.
- [ ] Implement `scheduled-security.yml`.
- [ ] Enable the scheduled workflow in `shared-pipelines` (it runs against the `shared-pipelines` repo itself as a dogfood test).
- [ ] Configure code scanning alert notifications for the security team.

**Success criteria:** infracost PR comment shows correct cost delta; scheduled scan runs Monday–Friday at 06:00 UTC.

---

### Phase 4 — Full Rollout (Week 4)

Goal: migrate all repositories and lock down branch protection.

- [ ] Identify all repositories in the organization that contain Terraform, Python, or Docker code.
- [ ] For each repository: add `ci.yml`, set `AWS_ROLE_ARN` variable, confirm pipeline is green.
- [ ] Configure branch protection required checks on all repositories (see Section 11).
- [ ] Enable Dependabot on `shared-pipelines` (`.github/dependabot.yml` already exists; ensure it is active in **Settings → Security → Dependabot**).
- [ ] Conduct a retrospective: review false positive rates, pipeline durations, and any blocking issues that arose during rollout.
- [ ] Set baseline values for all SLO metrics (see Section 15).
- [ ] Share the final README with all engineering teams.

**Success criteria:** 100% of Terraform repositories have infracost coverage; zero long-lived cloud credentials remaining in any repository's Secrets; all repositories have branch protection enforcing required checks.

---

## 15. Metrics and SLOs

The following metrics define the success of this pipeline. Review them monthly using the GitHub Actions usage dashboard and the Security tab analytics.

### SLO table

| Metric | Target | Current | How to measure |
|---|---|---|---|
| Pipeline duration p95 | < 10 min | — | GitHub Actions usage export; filter by workflow name; compute p95 of run duration |
| Cache hit rate | > 80% | — | Parse "Cache restored" vs "Cache not found" from Actions logs; or use the GitHub REST API for cache statistics |
| checkov false positive rate | < 5% | — | Count `skip-check` entries + inline `#checkov:skip` annotations divided by total checkov findings per month |
| Cost visibility coverage | 100% of Terraform repos | — | Count repos with `shared-cost.yml` call / total repos with `.tf` files |
| Secret leak incidents | 0 | — | Count security incidents where a secret was committed and reached the remote (gitleaks should catch these at PR time) |
| Long-lived cloud credentials in CI | 0 | — | Audit GitHub Secrets across all repos for keys named `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AZURE_CREDENTIALS` etc.; target is zero |
| Unpinned actions | 0 | — | Grep all workflow files across all repos for `uses:` lines that do not match a 40-char SHA pattern |

### Metric explanations

**Pipeline duration p95 < 10 min**
The 95th percentile of total pipeline duration (from PR open to all required checks green) must be under 10 minutes. Outliers above 10 minutes indicate a tool hanging, a cache miss cascade, or an overloaded runner pool. Investigate the specific step that exceeds its expected duration using the step-level timing in the Actions UI.

**Cache hit rate > 80%**
When caches miss consistently, every run downloads providers, plugins, and Python packages from the internet. This adds 2–5 minutes per run and increases egress costs. If the hit rate drops below 80%, audit the cache keys for volatility and check whether Dependabot bumped a dependency that invalidated a large cache (expected and acceptable, but should recover within one run).

**checkov false positive rate < 5%**
False positives erode trust in the pipeline. Engineers start adding `#checkov:skip` annotations reflexively rather than evaluating each finding. Track the number of skipped checks relative to total findings. If the rate exceeds 5%, review the skip list and either remove stale skips or raise the default `fail-on-severity` threshold if findings are genuinely low-risk.

**Cost visibility coverage 100%**
Every repository containing Terraform code should have the `shared-cost.yml` workflow enabled. Coverage below 100% means cost-changing PRs are being merged without review of their financial impact. Enforce coverage by adding a check to the Phase 4 rollout checklist and auditing monthly.

**Secret leak incidents 0**
gitleaks running on every PR and on every commit in the scheduled scan should prevent any secret from reaching the remote. An incident occurs when a secret is discovered in the git history of any branch (including merged PRs). Track this at zero. Any incident triggers an immediate response: rotate the secret, audit where it was used, and conduct a post-mortem.

**Long-lived cloud credentials in CI: 0**
Audit all repository Secrets across the organization using the GitHub API. Any repository storing `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `ARM_CLIENT_SECRET`, or similar static credentials should be migrated to OIDC. Long-lived credentials cannot be rotated automatically, cannot be scoped to specific workflows, and pose a significant blast radius if compromised.

**Unpinned actions: 0**
All `uses:` references in all workflow files across all repositories must pin to a full 40-character SHA. Run this audit monthly:

```bash
# Find all workflow files across all repos and grep for unpinned uses
# This assumes you have all repos checked out locally, or use the GitHub API
grep -rn 'uses:' .github/workflows/ | grep -v '@[0-9a-f]\{40\}'
```

Any line that does not match a 40-char SHA is unpinned and must be fixed.

---

*This document was last updated: 2026-03-08. If you find an error or a gap, open a PR against `shared-pipelines` with the correction.*
