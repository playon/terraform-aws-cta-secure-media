# CTA-5007-B secure media delivery — Terraform port of the
# aws-solutions-library-samples CDK reference solution.
# See README.md for module usage.

locals {
  environment = var.environment
  name_prefix = var.name_prefix

  # Safety check: assert the caller identity matches the account_id
  # variable before letting apply run. Guards against pointing the
  # wrong workspace at a shared account.
  _account_check = var.account_id == "" || data.aws_caller_identity.current.account_id == var.account_id ? "" : file("ERROR: caller account ${data.aws_caller_identity.current.account_id} does not match var.account_id ${var.account_id}")
}

# --------------------------------------------------------------------------
# CloudFront KeyValueStore — holds the signing key + revocation list.
# --------------------------------------------------------------------------
resource "aws_cloudfront_key_value_store" "this" {
  name    = "${local.name_prefix}-${local.environment}"
  comment = "CTA-5007-B signing key + revocation list."
}

# --------------------------------------------------------------------------
# Secrets Manager — HMAC signing key.
#
# random_password generates the initial value; the sync_keys Lambda
# (rotation.tf) copies it into the KVS so the validator function can
# read it. Rotation is driven by a Step Functions workflow on an
# EventBridge schedule (rotation.tf).
# --------------------------------------------------------------------------
resource "random_password" "signing_key" {
  length  = var.signing_key_length
  special = false
}

resource "aws_secretsmanager_secret" "signing_key" {
  name        = "${local.name_prefix}/${local.environment}/signing-key"
  description = "CTA-5007-B HMAC signing key."

  recovery_window_in_days = var.secret_recovery_window_days
}

resource "aws_secretsmanager_secret_version" "signing_key" {
  secret_id = aws_secretsmanager_secret.signing_key.id
  secret_string = jsonencode({
    algorithm  = "HMAC-SHA256"
    signingKey = random_password.signing_key.result
  })
}

# --------------------------------------------------------------------------
# CloudFront Function — CTA validator.
#
# Consumers reference this function by ARN (see outputs.tf) and attach
# it to their own distributions' viewer-request event. The function
# reads its signing key + revocation list from the KVS above.
# --------------------------------------------------------------------------
resource "aws_cloudfront_function" "validator" {
  name    = "${local.name_prefix}-${local.environment}-validator"
  runtime = "cloudfront-js-2.0"
  comment = "CTA-5007-B CWT validator."
  publish = true
  code = templatefile("${path.module}/source/lambda/cta_token_validator.js.tftpl", {
    token_validation_enabled = var.token_validation_enabled ? "true" : "false"
    geo_validation_enabled   = var.geo_validation_enabled ? "true" : "false"
  })

  key_value_store_associations = [aws_cloudfront_key_value_store.this.arn]
}
