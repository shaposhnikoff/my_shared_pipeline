# .tflint.hcl
#
# TFLint configuration — Terraform best practices and provider-specific rules.
# Docs: https://github.com/terraform-linters/tflint/blob/master/docs/user-guide/config.md

# ── Provider plugins ──────────────────────────────────────────────────────────

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

# ── Rules ─────────────────────────────────────────────────────────────────────

# Enforce consistent naming conventions across all resource types
rule "terraform_naming_convention" {
  enabled = true
}

# Require description on all variables — prevents undocumented inputs
rule "terraform_documented_variables" {
  enabled = true
}

# Require description on all outputs — prevents undocumented outputs
rule "terraform_documented_outputs" {
  enabled = true
}

# Warn on deprecated interpolation syntax (e.g. "${var.foo}" → var.foo)
rule "terraform_deprecated_interpolation" {
  enabled = true
}

# Require explicit type on all variables
rule "terraform_typed_variables" {
  enabled = true
}
