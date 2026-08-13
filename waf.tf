# WAFv2 Web ACL — rate-limit POST /api/token per source IP. Mitigates
# automated CWT minting attempts even when the IAM lockdown is off.

locals {
  rate_limit_body_key = "CTAWebAclRateLimit429"
}

resource "aws_wafv2_web_acl" "this" {
  name        = "${local.name_prefix}-${local.environment}-token-rate-limit"
  description = "Rate-limit POST /api/token to mitigate automated CWT minting."
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  custom_response_body {
    key          = local.rate_limit_body_key
    content_type = "APPLICATION_JSON"
    content = jsonencode({
      error   = "rate_limited"
      message = "Too many token mint requests from this IP; try again in a few minutes."
    })
  }

  rule {
    name     = "TokenMintRateLimit"
    priority = 0

    action {
      block {
        custom_response {
          response_code            = 429
          custom_response_body_key = local.rate_limit_body_key
        }
      }
    }

    statement {
      rate_based_statement {
        limit              = var.token_rate_limit_per_5min
        aggregate_key_type = "IP"

        scope_down_statement {
          byte_match_statement {
            search_string         = "/api/token"
            positional_constraint = "STARTS_WITH"

            field_to_match {
              uri_path {}
            }

            text_transformation {
              priority = 0
              type     = "NONE"
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-${local.environment}-token-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name_prefix}-${local.environment}-web-acl"
    sampled_requests_enabled   = true
  }
}
