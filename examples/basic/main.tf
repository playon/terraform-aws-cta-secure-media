terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.88"
    }
  }
}

# WAFv2 CLOUDFRONT-scoped resources must be in us-east-1 regardless of
# where your other infrastructure lives.
provider "aws" {
  region = "us-east-1"
}

module "cta" {
  source = "../.."

  environment = "dev"

  # A fresh deploy has no minted tokens; leave the gate at "off" until
  # your minter is wired up, flip to "log" to observe the reject
  # population, then to "enforce" once that signal is clean.
  token_enforcement_mode = "off"

  # DMA gate defaults to "off"; when you turn it on ("log" / "enforce"),
  # set `blackout_api_base_url = "https://your-upstream.example.com"`
  # and re-apply — the blackout_sync Lambda is only created when the
  # gate is on.
  # dma_enforcement_mode = "off"

  # account_id = "123456789012"  # optional caller-identity guard
}

output "validator_function_arn" {
  description = "Attach this to your own distribution's viewer-request event."
  value       = module.cta.validator_function_arn
}

output "api_endpoint" {
  description = "POST here to mint / revoke tokens."
  value       = module.cta.api_endpoint
}

output "kvs_arn" {
  value = module.cta.kvs_arn
}
