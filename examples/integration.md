# Integration Guide

Step-by-step guide for integrating shared CI/CD pipelines into your repository.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Quick Start](#quick-start)
3. [Step-by-Step Integration](#step-by-step-integration)
4. [Configuration Files](#configuration-files)
5. [GitHub Settings](#github-settings)
6. [Verification](#verification)
7. [Troubleshooting](#troubleshooting)

---

## Prerequisites

Before starting, ensure you have:

- A GitHub repository with code to lint/test
- Admin access to the repository (for settings configuration)
- Basic knowledge of GitHub Actions workflows
- (Optional) AWS account with OIDC configured for Terraform state access
- (Optional) Infracost API key for cost estimation ([sign up free](https://www.infracost.io/))

---

## Quick Start

**TL;DR** for experienced users:

```bash
# 1. Copy configuration files to your repo root
curl -O https://raw.githubusercontent.com/shaposhnikoff/my_shared_pipeline/main/examples/.checkov.yml
curl -O https://raw.githubusercontent.com/shaposhnikoff/my_shared_pipeline/main/examples/.hadolint.yaml
curl -O https://raw.githubusercontent.com/shaposhnikoff/my_shared_pipeline/main/examples/.yamllint.yml
curl -O https://raw.githubusercontent.com/shaposhnikoff/my_shared_pipeline/main/examples/ruff.toml

# 2. Copy workflow file
mkdir -p .github/workflows
curl -o .github/workflows/ci.yml https://raw.githubusercontent.com/shaposhnikoff/my_shared_pipeline/main/examples/ci.yml

# 3. Adjust workflow parameters (python-version, terraform-version, working-directory)

# 4. Configure GitHub secrets/variables (see GitHub Settings section)

# 5. Commit and push
git add .
git commit -m "feat: add shared CI pipeline"
git push origin main
```

---

## Step-by-Step Integration

### Step 1: Copy Configuration Files

These config files tell linters how to scan your code. Copy them to your repository root:

```bash
cd /path/to/your/repo

# Download all config files
curl -O https://raw.githubusercontent.com/shaposhnikoff/my_shared_pipeline/main/examples/.checkov.yml
curl -O https://raw.githubusercontent.com/shaposhnikoff/my_shared_pipeline/main/examples/.hadolint.yaml
curl -O https://raw.githubusercontent.com/shaposhnikoff/my_shared_pipeline/main/examples/.yamllint.yml
curl -O https://raw.githubusercontent.com/shaposhnikoff/my_shared_pipeline/main/examples/ruff.toml
```

**File purposes:**

| File | Tool | Purpose |
|------|------|---------|
| `.checkov.yml` | Checkov | IaC security scanner config (Terraform, Dockerfiles, GitHub Actions) |
| `.hadolint.yaml` | hadolint | Dockerfile linter config |
| `.yamllint.yml` | yamllint | YAML file linter config (workflows, configs) |
| `ruff.toml` | Ruff | Python linter/formatter config (replaces Black, Flake8, isort) |

### Step 2: Create CI Workflow

Create the main workflow file that orchestrates the pipeline:

```bash
mkdir -p .github/workflows
curl -o .github/workflows/ci.yml https://raw.githubusercontent.com/shaposhnikoff/my_shared_pipeline/main/examples/ci.yml
```

### Step 3: Customize Workflow Parameters

Edit `.github/workflows/ci.yml` and adjust these parameters for your project:

```yaml
# Line 75-77: Lint stage
with:
  python-version:    "3.11"        # ← Change to your Python version
  terraform-version: "1.9.x"       # ← Change to your Terraform version
  working-directory: "."           # ← Change if code is in subdirectory
```

```yaml
# Line 85-87: Terraform stage
with:
  terraform-version: "1.9.x"       # ← Match the version above
  working-directory: "."           # ← Path to Terraform root module
  aws-role-arn: ${{ vars.AWS_ROLE_ARN }}  # ← Optional: for Terraform state access
```

```yaml
# Line 95-97: Security stage
with:
  working-directory: "."           # ← Directory to scan for security issues
  fail-on-severity: "HIGH"         # ← Options: LOW, MEDIUM, HIGH, CRITICAL
```

```yaml
# Line 108-110: Cost stage (optional)
with:
  terraform-dir: "."               # ← Path to Terraform directory
  aws-role-arn:  ${{ vars.AWS_ROLE_ARN }}  # ← Optional: for pricing API
```

### Step 4: Adjust File Path Filters (Optional)

If your project structure is unique, customize the path filters in the `changes` job:

```yaml
# Line 52-68: Detect Changes filters
filters: |
  terraform:
    - 'terraform/**'               # ← Add/modify paths that trigger Terraform jobs
    - '**/*.tf'
  python:
    - '**/*.py'                    # ← Add/modify paths that trigger Python lint
    - 'requirements*.txt'
  docker:
    - '**/Dockerfile'              # ← Add/modify paths that trigger Dockerfile lint
```

---

## Configuration Files

### `.checkov.yml` - IaC Security Scanner

**What it does:** Scans Terraform, Dockerfiles, and GitHub Actions workflows for security misconfigurations.

**Customize:**
- Add paths to `skip-path` to exclude directories (e.g., `vendor/`, `examples/`)
- Add check IDs to `skip-check` to suppress specific findings (e.g., `CKV_GIT_1`)
- Adjust `framework` list to enable/disable scanners

**Example customization:**
```yaml
skip-path:
  - .venv
  - vendor
  - examples

skip-check:
  - CKV_GIT_1   # GitHub org settings not applicable for personal repos
  - CKV_DOCKER_2  # HEALTHCHECK not needed for batch jobs
```

### `.hadolint.yaml` - Dockerfile Linter

**What it does:** Checks Dockerfiles for best practices and common mistakes.

**Customize:**
- Add rule IDs to `ignore` to disable specific checks
- Change `failure-threshold` to `warning` for advisory-only mode
- Add trusted registries to skip image pinning warnings

**Example customization:**
```yaml
ignore:
  - DL3008  # Pin apt packages — too strict for dev images
  - DL3018  # Pin apk packages — allow latest for base images

failure-threshold: warning  # Don't fail build on lint warnings
```

### `.yamllint.yml` - YAML Linter

**What it does:** Validates YAML syntax and enforces style consistency.

**Customize:**
- Adjust `line-length.max` for your team's preference
- Change rule `level` from `error` to `warning` to make advisory
- Modify `indentation.spaces` if you prefer 4-space indents

**Example customization:**
```yaml
rules:
  line-length:
    max: 200         # Allow longer lines for long URLs
    level: warning   # Don't fail on long lines
```

### `ruff.toml` - Python Linter

**What it does:** Fast Python linter (replaces Black, Flake8, isort, pylint).

**Customize:**
- Adjust `line-length` for your style guide
- Modify `select` to enable additional rule categories (see [Ruff rules](https://docs.astral.sh/ruff/rules/))
- Add patterns to `lint.per-file-ignores` for test files or legacy code

**Example customization:**
```yaml
[lint]
select = ["E", "F", "I", "B", "UP", "S", "C90"]  # Add C90 for complexity checks

[lint.per-file-ignores]
"scripts/**" = ["S603", "S605"]  # Allow subprocess in automation scripts
"legacy/**" = ["E", "F"]         # Only check syntax errors in legacy code
```

---

## GitHub Settings

### Required: Repository Permissions

1. Go to **Settings** → **Actions** → **General**
2. Under **Workflow permissions**, select:
   - ✅ **Read and write permissions**
   - ✅ **Allow GitHub Actions to create and approve pull requests**

### Optional: Secrets and Variables

Configure these if using advanced features:

#### Secrets (Settings → Secrets and variables → Actions → Secrets)

| Secret Name | Required For | How to Get |
|-------------|-------------|------------|
| `INFRACOST_API_KEY` | Cost estimation | Sign up at [infracost.io](https://www.infracost.io/) (free tier available) |

#### Variables (Settings → Secrets and variables → Actions → Variables)

| Variable Name | Required For | Example Value |
|---------------|-------------|---------------|
| `AWS_ROLE_ARN` | Terraform with AWS backend | `arn:aws:iam::123456789012:role/github-actions` |

**Setting up AWS OIDC (optional):**
```bash
# Create IAM role for GitHub Actions OIDC
# See: https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services

aws iam create-role \
  --role-name github-actions-terraform \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
          "token.actions.githubusercontent.com:sub": "repo:YOUR_ORG/YOUR_REPO:ref:refs/heads/main"
        }
      }
    }]
  }'
```

---

## Verification

### Step 1: Commit and Push

```bash
git add .
git commit -m "feat: integrate shared CI pipeline"
git push origin main
```

### Step 2: Check GitHub Actions

1. Go to your repository on GitHub
2. Click **Actions** tab
3. You should see the "CI" workflow running

### Step 3: Verify Each Stage

A successful run should show:

```
✅ Detect Changes
✅ Lint / Secrets Scan (gitleaks)
✅ Lint / Python Lint (ruff + black + bandit)
✅ Lint / YAML Lint
✅ Lint / Dockerfile Lint (hadolint)
✅ Lint / Terraform Lint (fmt + validate + tflint)
✅ Lint / Shell Lint (shellcheck)
✅ Terraform / Terraform (fmt + validate + tflint)
✅ Security / Checkov (IaC security)
✅ Security / Trivy (SCA / CVE — advisory)
⏭️ Cost (skipped - only runs on PRs)
```

### Step 4: Create Test PR

To verify the full pipeline including cost estimation:

```bash
git checkout -b test/pipeline-verification
echo "# Test" >> README.md
git add README.md
git commit -m "test: verify CI pipeline"
git push origin test/pipeline-verification

# Create PR via GitHub CLI
gh pr create --title "Test: Verify CI Pipeline" --body "Testing shared pipeline integration"
```

---

## Troubleshooting

### Issue: "Resource not accessible by integration"

**Symptom:** Security jobs fail with upload-sarif permission error.

**Solution:** This is expected behavior when `security-events: write` permission can't be inherited. The scanners still run successfully — only the SARIF upload to GitHub Security tab fails. This doesn't affect the actual security checks.

**Fix (optional):** Add `continue-on-error: true` has already been added to the shared workflows, so this should not cause pipeline failures.

---

### Issue: "Directory ./terraform does not exist"

**Symptom:** Terraform/Security jobs fail with "No such file or directory".

**Solution:** Adjust `working-directory` in your workflow:

```yaml
# If you don't have Terraform
terraform:
  ...
  with:
    working-directory: "."  # ← Change to "." or skip terraform stage

# If Terraform is in a subdirectory
terraform:
  ...
  with:
    working-directory: "./infrastructure"  # ← Path to your terraform files
```

**Alternative:** Skip Terraform stages entirely if not applicable:

```yaml
terraform:
  name: Terraform
  needs: [lint, changes]
  if: needs.changes.outputs.terraform == 'true'  # ← Add this condition
  uses: shaposhnikoff/my_shared_pipeline/.github/workflows/shared-terraform.yml@main
  ...
```

---

### Issue: Checkov fails with too many findings

**Symptom:** Security job fails because Checkov found HIGH/CRITICAL issues.

**Solution 1:** Fix the security issues (recommended).

**Solution 2:** Suppress false positives by adding check IDs to `.checkov.yml`:

```yaml
skip-check:
  - CKV_GIT_1   # Example: GitHub org settings
  - CKV_DOCKER_2  # Example: HEALTHCHECK not needed
```

**Solution 3:** Change severity threshold:

```yaml
security:
  ...
  with:
    fail-on-severity: "CRITICAL"  # ← Only fail on CRITICAL (not HIGH)
```

---

### Issue: Python/Shell/YAML lint fails on existing code

**Symptom:** Lint jobs fail on legacy code not following style guidelines.

**Solution 1:** Auto-fix formatting issues:

```bash
# Python (Ruff can auto-fix many issues)
ruff check --fix .
ruff format .

# YAML
yamllint --config .yamllint.yml . || true

# Review and commit changes
git add .
git commit -m "style: auto-fix linting issues"
```

**Solution 2:** Suppress rules for legacy code in config files:

```toml
# ruff.toml
[lint.per-file-ignores]
"legacy/**" = ["E", "F"]  # Only syntax errors, no style checks
```

---

### Issue: Cost job fails with "INFRACOST_API_KEY not set"

**Symptom:** Cost stage fails looking for API key.

**Solution:** The shared workflow now gracefully skips when the API key is missing. If you see this error on recent pipeline runs, update your workflow:

```yaml
# .github/workflows/ci.yml
uses: shaposhnikoff/my_shared_pipeline/.github/workflows/shared-cost.yml@main  # ← Ensure @main (not pinned to old commit)
```

**Alternative:** Get a free Infracost API key:
1. Sign up at https://www.infracost.io/
2. Copy your API key
3. Add to **Settings** → **Secrets** → `INFRACOST_API_KEY`

---

### Issue: Workflow fails with "workflow file issue"

**Symptom:** Entire workflow fails immediately with validation error.

**Solution:** Check workflow syntax:

```bash
# Install actionlint
brew install actionlint  # macOS
# or
go install github.com/rhysd/actionlint/cmd/actionlint@latest

# Validate workflow
actionlint .github/workflows/ci.yml
```

Common issues:
- Incorrect indentation (YAML is whitespace-sensitive)
- Missing `secrets: inherit` when using reusable workflows
- Invalid `uses:` reference (check repo/path@ref format)

---

## Next Steps

### Customize for Your Team

1. **Add branch protection rules:**
   - Settings → Branches → Add rule for `main`
   - ✅ Require status checks (select all CI jobs)
   - ✅ Require branches to be up to date

2. **Enable Security tab features:**
   - Settings → Code security → Enable Dependabot alerts
   - Settings → Code security → Enable Secret scanning

3. **Add team-specific linters:**
   - Edit `shared-lint.yml` in your own fork
   - Add custom checks (e.g., ESLint for JS, golangci-lint for Go)

### Advanced: Pin to Specific Version

For production stability, pin workflows to a specific commit or tag:

```yaml
# Instead of @main (tracks latest)
uses: shaposhnikoff/my_shared_pipeline/.github/workflows/shared-lint.yml@main

# Pin to tag (recommended for production)
uses: shaposhnikoff/my_shared_pipeline/.github/workflows/shared-lint.yml@v1.0.0

# Or pin to commit SHA (most secure)
uses: shaposhnikoff/my_shared_pipeline/.github/workflows/shared-lint.yml@52fcbbd5a4bfae29dd0ccb9673f0ca07295d355f
```

---

## Support

- **Issues:** [github.com/shaposhnikoff/my_shared_pipeline/issues](https://github.com/shaposhnikoff/my_shared_pipeline/issues)
- **Discussions:** [github.com/shaposhnikoff/my_shared_pipeline/discussions](https://github.com/shaposhnikoff/my_shared_pipeline/discussions)
- **Examples:** Check `examples/` directory for full working samples

---

**Happy CI/CD! 🚀**
