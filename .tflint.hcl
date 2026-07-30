plugin "aws" {
  enabled = true
  version = "0.31.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

rule "terraform_deprecated_interpolation" { enabled = true }
rule "terraform_unused_declarations" { enabled = true }
rule "terraform_comment_syntax" { enabled = true }
rule "terraform_documented_variables" { enabled = true }
rule "terraform_documented_outputs" { enabled = false } # not every output needs prose, names are descriptive
rule "terraform_naming_convention" { enabled = true }
rule "terraform_typed_variables" { enabled = true }
rule "terraform_module_pinned_source" { enabled = false } # intentional: local paths in this monorepo, see README
