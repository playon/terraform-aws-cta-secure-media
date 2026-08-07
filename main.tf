# CTA-5007-B secure media delivery — Terraform port of the
# aws-solutions-library-samples CDK reference solution.
#
# See README.md for module usage.

locals {
  account_id  = var.account_id
  region      = var.region
  environment = var.environment
  name_prefix = var.name_prefix

  # Belt-and-braces: assert the workspace / tfvars was pointed at the
  # right account before letting apply run. Skipped when account_id is
  # left empty (single-account setups).
  _account_check = var.account_id == "" || data.aws_caller_identity.current.account_id == var.account_id ? "" : file("ERROR: caller account ${data.aws_caller_identity.current.account_id} does not match var.account_id ${var.account_id}")
}

# --------------------------------------------------------------------------
# CloudFront KeyValueStore — holds the signing key + revocation list.
# --------------------------------------------------------------------------
resource "aws_cloudfront_key_value_store" "this" {
  name    = "${local.name_prefix}-${local.environment}"
  comment = "CTA-5007-B signing key + revocation list. VID-3439."
}

# --------------------------------------------------------------------------
# Secrets Manager — HMAC signing key.
#
# aws_secretsmanager_secret + aws_secretsmanager_secret_version generate the
# key on first apply; the plaintext value is held in Terraform state (see
# README security section). Rotation is driven by the Step Functions
# workflow in rotation.tf on the schedule set by var.rotation_schedule.
# --------------------------------------------------------------------------
resource "random_password" "signing_key" {
  length  = var.signing_key_length
  special = false
}

resource "aws_secretsmanager_secret" "signing_key" {
  name        = "${local.name_prefix}/${local.environment}/signing-key"
  description = "CTA-5007-B HMAC signing key. VID-3439."

  # Match CDK stack's removal semantics — stage can be destroyed clean.
  recovery_window_in_days = local.environment == "prod" ? 30 : 0
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
# JS source lives at ../source/lambda/cta_token_validator.js (CDK
# app's convention — everything under source/). Once VID-3439's port
# is complete and source/ is deleted, move lambda*/ up one level and
# update this path.
#
# In-repo reference means no drift with the SDK code the Lambdas use
# (../source/lambda/sdk/cta-client.js), which is the important invariant.
#
# Consumers reference this function by ARN (see `validator_function_arn`
# in outputs.tf) and attach it to the viewer-request phase of their own
# content distribution's cache behaviors.
# --------------------------------------------------------------------------
resource "aws_cloudfront_function" "validator" {
  name    = "${local.name_prefix}-${local.environment}-validator"
  runtime = "cloudfront-js-2.0"
  comment = "CTA-5007-B CWT validator. VID-3439."
  publish = true
  code = templatefile("${path.module}/../source/lambda/cta_token_validator.js.tftpl", {
    dma_enforcement_mode         = var.dma_enforcement_mode
    token_enforcement_mode       = var.token_enforcement_mode
    legacy_client_allowlist_json = jsonencode(var.legacy_client_allowlist)
  })

  key_value_store_associations = [aws_cloudfront_key_value_store.this.arn]
}
