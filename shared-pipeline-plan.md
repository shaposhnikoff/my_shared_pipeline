# Shared CI/CD Pipeline — Implementation Plan
**Stack:** Terraform · Python · Infrastructure-as-Code
**Platform:** GitHub Actions (Reusable Workflows)

---

## 1. Architecture Overview

```
.github/
├── workflows/
│   ├── shared-lint.yml          ← reusable: все линтеры
│   ├── shared-security.yml      ← reusable: security checks
│   ├── shared-terraform.yml     ← reusable: tf validate/plan
│   ├── shared-cost.yml          ← reusable: infracost
│   └── scheduled-security.yml  ← scheduled: weekday scans
│
calling-repo/
└── .github/workflows/
    └── ci.yml                   ← вызывает shared workflows
```

**Принцип:** один репо `shared-pipelines` содержит все reusable workflows.
Каждый продуктовый репо вызывает их через `uses: org/shared-pipelines/.github/workflows/...@v1`.

---

## 2. Pipeline Flow (порядок критичен)

```
PR opened/updated
       │
       ▼
┌─────────────────┐
│  changes job    │  path-based filtering (dorny/paths-filter)
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Stage 1: FAST  │  ~1-2 min  ← fail fast, дёшево
│  secrets scan   │
│  yaml/json lint │
└────────┬────────┘
         │ pass
         ▼
┌─────────────────────────────┐
│  Stage 2+3: parallel        │  ~5-10 min
│  left:  tf fmt/validate     │
│         tflint              │
│  right: checkov + trivy     │
└────────┬────────────────────┘
         │ pass
         ▼
┌─────────────────────┐
│  Stage 4: ADVISORY  │  ~2-3 min  ← non-blocking
│  infracost diff     │
└─────────────────────┘
         │
         ▼
      PR Comment с результатами
```

**Dependency chain:** `lint → (terraform + security in parallel) → cost`

---

## 3. Tools Matrix

| Stage | Tool | Blocking | Цель |
|-------|------|----------|------|
| 1 | `gitleaks` | ✅ | Секреты в коде/истории |
| 1 | `yamllint` | ✅ | YAML синтаксис |
| 2 | `ruff` | ✅ | Python lint + isort + pyflakes |
| 2 | `black --check` | ✅ | Python форматирование |
| 2 | `bandit` | ✅ HIGH/CRITICAL | Python security |
| 2 | `shellcheck` | ✅ | Bash/sh скрипты |
| 2 | `hadolint` | ✅ | Dockerfile |
| 3 | `terraform fmt -check` | ✅ | TF форматирование |
| 3 | `terraform validate` | ✅ | TF синтаксис |
| 3 | `tflint` | ✅ | TF best practices |
| 3 | `checkov` | ✅ HIGH/CRITICAL | IaC security misconfig |
| 4 | `infracost diff` | ❌ | Cost estimation (PR comment) |
| 4 | `trivy` | ❌ MEDIUM/LOW | SCA, CVE в зависимостях |

---

## 4. Reusable Workflow: shared-lint.yml

```yaml
# .github/workflows/shared-lint.yml
name: Shared Lint

on:
  workflow_call:
    inputs:
      python-version:
        type: string
        default: "3.11"
      terraform-version:
        type: string
        default: "1.9.x"
      working-directory:
        type: string
        default: "."

# Минимальные права по умолчанию
permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.head_ref || github.ref }}
  cancel-in-progress: true

jobs:
  secrets:
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v7.0.0
        with:
          fetch-depth: 0          # gitleaks нужна вся история
      - uses: gitleaks/gitleaks-action@v3.0.0
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

  yaml-lint:
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v7.0.0
      - name: Install linters
        run: |
          python -m venv /tmp/lint-venv
          /tmp/lint-venv/bin/pip install -r requirements-lint.txt
          echo "/tmp/lint-venv/bin" >> $GITHUB_PATH
      - run: yamllint -c .yamllint.yml .

  python-lint:
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v7.0.0
      - uses: actions/setup-python@v7.0.0
        with:
          python-version: ${{ inputs.python-version }}
          cache: pip
      - name: Install linters
        run: |
          python -m venv /tmp/lint-venv
          /tmp/lint-venv/bin/pip install -r requirements-lint.txt
          echo "/tmp/lint-venv/bin" >> $GITHUB_PATH
      - run: ruff check .
      - run: black --check .
      - run: bandit -r . -ll -ii  # HIGH severity + HIGH confidence

  shell-lint:
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v7.0.0
      - uses: ludeeus/action-shellcheck@2.0.0

  dockerfile-lint:
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v7.0.0
      - uses: hadolint/hadolint-action@v3.1.0
        with:
          recursive: true

  terraform-lint:
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    defaults:
      run:
        working-directory: ${{ inputs.working-directory }}
    steps:
      - uses: actions/checkout@v7.0.0
      - uses: hashicorp/setup-terraform@v4.0.1
        with:
          terraform_version: ${{ inputs.terraform-version }}
      - uses: actions/cache@v6.1.0
        with:
          path: ~/.tflint.d/plugins
          key: tflint-${{ hashFiles('.tflint.hcl') }}
      - uses: terraform-linters/setup-tflint@v6.3.0
      - run: terraform fmt -check -recursive
      - run: terraform init -backend=false
      - run: terraform validate
      - run: tflint --recursive
```

---

## 5. Reusable Workflow: shared-security.yml

```yaml
# .github/workflows/shared-security.yml
name: Shared Security

on:
  workflow_call:
    inputs:
      working-directory:
        type: string
        default: "."
      fail-on-severity:
        type: string
        default: "HIGH"        # LOW | MEDIUM | HIGH | CRITICAL

# SARIF upload требует security-events: write
permissions:
  contents: read
  security-events: write

concurrency:
  group: ${{ github.workflow }}-${{ github.head_ref || github.ref }}
  cancel-in-progress: true

jobs:
  checkov:
    runs-on: ubuntu-24.04
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v7.0.0
      - uses: bridgecrewio/checkov-action@v12.3088.0
        with:
          directory: ${{ inputs.working-directory }}
          # Расширенный набор фреймворков: IaC + секреты + dockerfile + GHA
          framework: terraform,secrets,dockerfile,github_actions
          soft_fail: false
          output_format: sarif
          output_file_path: results.sarif
      - uses: github/codeql-action/upload-sarif@v4.32.6
        if: always()
        with:
          sarif_file: results.sarif

  trivy:
    runs-on: ubuntu-24.04
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v7.0.0
      - uses: aquasecurity/trivy-action@0.35.0
        with:
          scan-type: fs
          scan-ref: .
          severity: ${{ inputs.fail-on-severity }},CRITICAL
          exit-code: 0          # advisory, не блокирует
          format: sarif
          output: trivy.sarif
      - uses: github/codeql-action/upload-sarif@v4.32.6
        if: always()
        with:
          sarif_file: trivy.sarif
```

---

## 6. Reusable Workflow: shared-terraform.yml

```yaml
# .github/workflows/shared-terraform.yml
name: Shared Terraform

on:
  workflow_call:
    inputs:
      terraform-version:
        type: string
        default: "1.9.x"
      working-directory:
        type: string
        default: "."
      aws-role-arn:
        type: string
        default: ""             # опционально: OIDC role ARN

# id-token нужен для OIDC auth в AWS/Azure/GCP
permissions:
  contents: read
  id-token: write

# cancel-in-progress: false — terraform plan не прерываем,
# чтобы не оставлять незавершённые lock-файлы в state backend
concurrency:
  group: ${{ github.workflow }}-${{ github.head_ref || github.ref }}
  cancel-in-progress: false

jobs:
  terraform:
    runs-on: ubuntu-24.04
    timeout-minutes: 20
    defaults:
      run:
        working-directory: ${{ inputs.working-directory }}
    steps:
      - uses: actions/checkout@v7.0.0

      # OIDC auth — выполняется только если передан aws-role-arn
      - uses: aws-actions/configure-aws-credentials@v6.2.2
        if: inputs.aws-role-arn != ''
        with:
          role-to-assume: ${{ inputs.aws-role-arn }}
          aws-region: us-east-1

      - uses: hashicorp/setup-terraform@v4.0.1
        with:
          terraform_version: ${{ inputs.terraform-version }}

      - uses: actions/cache@v6.1.0
        with:
          path: ~/.tflint.d/plugins
          key: tflint-${{ hashFiles('.tflint.hcl') }}

      - uses: terraform-linters/setup-tflint@v6.3.0

      - name: Terraform fmt check
        run: terraform fmt -check -recursive

      - name: Terraform init (no backend)
        run: terraform init -backend=false

      - name: Terraform validate
        run: terraform validate

      - name: TFLint
        run: tflint --recursive
```

---

## 7. Reusable Workflow: shared-cost.yml

```yaml
# .github/workflows/shared-cost.yml
name: Shared Cost Estimation

on:
  workflow_call:
    secrets:
      infracost-api-key:
        required: true
    inputs:
      terraform-dir:
        type: string
        default: "."
      aws-role-arn:
        type: string
        default: ""             # опционально: OIDC role ARN

# pull-requests: write нужен для создания/обновления PR comment
permissions:
  contents: read
  pull-requests: write

concurrency:
  group: ${{ github.workflow }}-${{ github.head_ref || github.ref }}
  cancel-in-progress: true

jobs:
  infracost:
    runs-on: ubuntu-24.04
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v7.0.0

      # OIDC auth — нужен если Terraform читает remote state из S3/GCS
      - uses: aws-actions/configure-aws-credentials@v6.2.2
        if: inputs.aws-role-arn != ''
        with:
          role-to-assume: ${{ inputs.aws-role-arn }}
          aws-region: us-east-1

      - uses: infracost/actions/setup@57f9f3f29d42f5fda3b1d3e5e5e5e5e5e5e5e5e  # v3.0.0
        with:
          api-key: ${{ secrets.infracost-api-key }}

      # Двухпроходный паттерн: base → diff → comment
      # Сначала считаем стоимость base ветки
      - name: Checkout base branch
        run: git checkout ${{ github.event.pull_request.base.sha }}

      - name: Infracost breakdown (base)
        run: |
          infracost breakdown \
            --path ${{ inputs.terraform-dir }} \
            --format json \
            --out-file /tmp/infracost-base.json

      # Возвращаемся на HEAD ветку PR
      - name: Checkout PR branch
        run: git checkout ${{ github.sha }}

      # Считаем diff между base и HEAD
      - name: Infracost diff (PR vs base)
        run: |
          infracost diff \
            --path ${{ inputs.terraform-dir }} \
            --compare-to /tmp/infracost-base.json \
            --format json \
            --out-file /tmp/infracost-diff.json

      # Публикуем/обновляем PR comment с результатами diff
      - uses: infracost/actions/comment@v3.0.1
        with:
          path: /tmp/infracost-diff.json
          behavior: update       # обновляет существующий PR comment
```

---

## 8. Вызов из продуктового репо (ci.yml)

```yaml
# calling-repo/.github/workflows/ci.yml
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
  # Path-based filtering: определяем что изменилось,
  # чтобы не запускать лишние jobs
  changes:
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    permissions:
      contents: read
      pull-requests: read
    outputs:
      terraform: ${{ steps.filter.outputs.terraform }}
      python: ${{ steps.filter.outputs.python }}
      docker: ${{ steps.filter.outputs.docker }}
    steps:
      - uses: actions/checkout@v7.0.0
      - uses: dorny/paths-filter@v4.0.2
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

  lint:
    needs: changes
    # Запускаем lint если изменился terraform, python или docker
    if: >
      needs.changes.outputs.terraform == 'true' ||
      needs.changes.outputs.python == 'true' ||
      needs.changes.outputs.docker == 'true'
    uses: org/shared-pipelines/.github/workflows/shared-lint.yml@v1
    with:
      python-version: "3.11"
      terraform-version: "1.9.x"
      working-directory: "./terraform"
    secrets: inherit

  terraform:
    needs: lint
    if: needs.changes.outputs.terraform == 'true'
    uses: org/shared-pipelines/.github/workflows/shared-terraform.yml@v1
    with:
      working-directory: "./terraform"
      aws-role-arn: ${{ vars.AWS_ROLE_ARN }}
    secrets: inherit

  security:
    needs: lint
    uses: org/shared-pipelines/.github/workflows/shared-security.yml@v1
    with:
      working-directory: "./terraform"
      fail-on-severity: "HIGH"
    secrets: inherit

  cost:
    # cost запускается после того как terraform и security прошли
    needs: [terraform, security]
    if: github.event_name == 'pull_request'
    uses: org/shared-pipelines/.github/workflows/shared-cost.yml@v1
    with:
      terraform-dir: "./terraform"
      aws-role-arn: ${{ vars.AWS_ROLE_ARN }}
    secrets:
      infracost-api-key: ${{ secrets.INFRACOST_API_KEY }}
```

---

## 9. Scheduled Security Workflow

```yaml
# .github/workflows/scheduled-security.yml
name: Scheduled Security Scan

on:
  # Запускается в будние дни в 06:00 UTC
  schedule:
    - cron: '0 6 * * 1-5'
  workflow_dispatch:   # ручной запуск при необходимости

permissions:
  contents: read
  security-events: write

concurrency:
  group: ${{ github.workflow }}-scheduled
  cancel-in-progress: true

jobs:
  full-security-scan:
    runs-on: ubuntu-24.04
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v7.0.0

      - uses: gitleaks/gitleaks-action@v3.0.0
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

      - uses: bridgecrewio/checkov-action@v12.3088.0
        with:
          framework: terraform,secrets,dockerfile,github_actions
          soft_fail: false
          output_format: sarif
          output_file_path: checkov.sarif

      - uses: github/codeql-action/upload-sarif@v4.32.6
        if: always()
        with:
          sarif_file: checkov.sarif

      - uses: aquasecurity/trivy-action@0.35.0
        with:
          scan-type: fs
          scan-ref: .
          severity: HIGH,CRITICAL
          exit-code: 0
          format: sarif
          output: trivy.sarif

      - uses: github/codeql-action/upload-sarif@v4.32.6
        if: always()
        with:
          sarif_file: trivy.sarif
```

---

## 10. Конфигурационные файлы (в корне репо)

### `.yamllint.yml`
```yaml
extends: default
rules:
  line-length:
    max: 120
  truthy:
    allowed-values: ['true', 'false']
```

### `ruff.toml`
```toml
line-length = 120
target-version = "py311"
select = ["E", "F", "I", "B", "UP"]
ignore = ["E501"]

[format]
quote-style = "double"
```

### `.tflint.hcl`
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

### `.checkov.yml`
```yaml
framework:
  - terraform
  - secrets
  - dockerfile
  - github_actions
skip-check:
  - CKV_AWS_144   # пример: cross-region replication (не всегда нужно)
soft-fail-on:
  - MEDIUM
  - LOW
```

### `.gitleaks.toml`
```toml
[extend]
useDefault = true

[[rules]]
description = "Custom: Internal API tokens"
id = "internal-api-token"
regex = '''PERISCOPE_[A-Z0-9]{32}'''
```

---

## 11. Caching Strategy

```yaml
# Кэши которые дают максимальный эффект:

# 1. Terraform providers (самые тяжёлые)
- uses: actions/cache@v6.1.0
  with:
    path: ~/.terraform.d/plugin-cache
    key: tf-providers-${{ hashFiles('**/.terraform.lock.hcl') }}

# 2. tflint plugins
- uses: actions/cache@v6.1.0
  with:
    path: ~/.tflint.d/plugins
    key: tflint-${{ hashFiles('.tflint.hcl') }}

# 3. Python deps (setup-python делает сам при cache: pip)
- uses: actions/setup-python@v7.0.0
  with:
    cache: pip

# 4. Trivy DB (обновляется раз в 24ч)
- uses: actions/cache@v6.1.0
  with:
    path: ~/.cache/trivy
    key: trivy-db-${{ steps.date.outputs.date }}
```

---

## 12. Rollout Plan

### Phase 1 — Foundation (неделя 1)
- [ ] Создать репо `shared-pipelines` в org
- [ ] Имплементировать `shared-lint.yml` (без terraform)
- [ ] Добавить конфиги: `.yamllint.yml`, `ruff.toml`, `requirements-lint.txt`
- [ ] Подключить 1 пилотный репо

### Phase 2 — IaC (неделя 2)
- [ ] Имплементировать `shared-terraform.yml` (fmt + validate + tflint)
- [ ] Имплементировать `shared-security.yml` (checkov + trivy)
- [ ] Настроить `.tflint.hcl` с провайдерами (aws/azurerm)
- [ ] SARIF upload → GitHub Security tab
- [ ] Настроить OIDC роли в AWS/Azure (отказ от long-lived credentials)

### Phase 3 — FinOps (неделя 3)
- [ ] Зарегистрировать Infracost API key → GitHub Org Secrets
- [ ] Имплементировать `shared-cost.yml` (двухпроходный паттерн)
- [ ] Настроить PR comment behavior
- [ ] Добавить `scheduled-security.yml`

### Phase 4 — Rollout (неделя 4)
- [ ] Подключить все репо
- [ ] Документация в README shared-pipelines
- [ ] Настроить branch protection rules (required checks)
- [ ] Настроить dependabot для автообновления action version tags
- [ ] Ретроспектива: что блокирует vs advisory

---

## 13. Branch Protection (финальная конфигурация)

```
Required status checks before merging:
  ✅ Lint / Secrets Scan (gitleaks)
  ✅ Lint / YAML Lint
  ✅ Lint / Python Lint (ruff + black + bandit)
  ✅ Lint / Terraform Lint (fmt + validate + tflint)
  ✅ Security / Checkov (IaC security)
  ✅ Terraform / Terraform (fmt + validate + tflint)

Advisory (не блокируют):
  ℹ️  Security / Trivy (SCA / CVE — advisory)
  ℹ️  Cost / Infracost (cost delta)
```

---

## 14. Метрики успеха

| Метрика | Target |
|---------|--------|
| Pipeline duration (p95) | < 10 min |
| Cache hit rate | > 80% |
| False positive rate (checkov) | < 5% |
| Cost visibility coverage | 100% TF репо |
| Secret leak incidents | 0 |
| Long-lived credentials в CI | 0 (100% OIDC) |

---

## 15. Версионирование workflows

### Стратегия: `@v1` vs `@main`

Продуктовые репо **всегда** ссылаются на тег `@v1`, а не на `@main`:

```yaml
# Правильно: стабильный тег
uses: org/shared-pipelines/.github/workflows/shared-lint.yml@v1

# Неправильно: main может сломать всё сразу
uses: org/shared-pipelines/.github/workflows/shared-lint.yml@main
```

**Процесс выпуска новой версии:**
1. Все изменения идут в `main` через PR
2. После стабилизации: `git tag v1.x.x && git push --tags`
3. Двигаем major тег: `git tag -f v1 && git push --force origin v1`
4. Breaking changes → новый major тег `v2`

---

## 16. Дополнительные файлы

### `requirements-lint.txt`

Файл с зафиксированными версиями всех линтеров.
Используется в venv-паттерне вместо `pip install --break-system-packages`.

```text
# Python linters — версии зафиксированы для воспроизводимости
ruff==0.4.4
black==24.4.2
bandit==1.7.8
yamllint==1.35.1
```

### `.pre-commit-config.yaml`

Локальная проверка перед коммитом — зеркало CI-линтеров.
Разработчики получают быструю обратную связь без ожидания pipeline.

```yaml
# .pre-commit-config.yaml
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

### `.github/dependabot.yml`

Автоматическое обновление action version tags через Dependabot.
Dependabot создаёт PR при выходе новых версий — точные tags в `uses:` обновляются автоматически.

```yaml
# .github/dependabot.yml
version: 2
updates:
  # Обновление GitHub Actions exact version tags
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
      day: "monday"
      time: "06:00"
      timezone: "UTC"
    groups:
      # Группируем все action-обновления в один PR
      actions-minor:
        patterns: ["*"]
        update-types: ["minor", "patch"]
    labels:
      - "dependencies"
      - "github-actions"
    commit-message:
      prefix: "chore(deps)"

  # Обновление Python зависимостей (requirements-lint.txt)
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
