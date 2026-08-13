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

  environment           = "dev"
  blackout_api_base_url = "https://example.invalid/api" # required — point at your DMA blocklist upstream
  # account_id          = "123456789012"                # optional guard
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
