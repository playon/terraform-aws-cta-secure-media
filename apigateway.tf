# API Gateway REST API — token mint (Node), revoke, list-revoked.
#
# The CDK stack disables the auto-created AWS::ApiGateway::Account resource
# (SCP blocks apigateway:PATCH on /account in some orgs). TF's
# aws_api_gateway_rest_api does NOT create an Account resource, so we
# don't need the workaround.
#
# POST /token is IAM-gated when var.drm_api_lambda_role_arn is set —
# only calls signed as that role reach the mint. Anonymous callers hit
# 403 at APIGW. Empty preserves the reference-solution behavior.

locals {
  # Present the token route with AWS_IAM auth when a caller ARN is
  # configured. Reference-solution behavior (NONE) is preserved for envs
  # that don't set the variable, so this stays a safe roll-out toggle.
  token_authorization = var.drm_api_lambda_role_arn != "" ? "AWS_IAM" : "NONE"
}

resource "aws_api_gateway_rest_api" "this" {
  name        = "${local.name_prefix}-${local.environment}"
  description = "CTA Token API."

  endpoint_configuration {
    types = ["EDGE"]
  }

  # Policy is on aws_api_gateway_rest_api_policy.this (defined below)
  # so its Resource strings can reference this API's .id. Terraform
  # disallows self-references inside a resource's own attributes but
  # allows them from a separate resource that depends on this one.
}

# VID-3449 (rehomed by VID-3484): resource policy restricts invoke on
# POST /token to the drm-api-lambda role. AWS_IAM auth on the method +
# this policy = only calls signed by that role's temporary creds reach
# the integration. /revoke and /revoked stay open on the resource-policy
# dimension (they're still individually AuthN'd if we add that later).
#
# Full-ARN Resource strings match what AWS stores — the service accepts
# either the short form `execute-api:/*/...` or the full ARN as input,
# but normalizes to the full ARN on write-back. Writing the full form
# ourselves makes desired == stored, no cosmetic drift on every plan.
resource "aws_api_gateway_rest_api_policy" "this" {
  count       = var.drm_api_lambda_role_arn == "" ? 0 : 1
  rest_api_id = aws_api_gateway_rest_api.this.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowDrmApiLambdaToMint"
        Effect    = "Allow"
        Principal = { AWS = var.drm_api_lambda_role_arn }
        Action    = "execute-api:Invoke"
        Resource  = "arn:aws:execute-api:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:${aws_api_gateway_rest_api.this.id}/*/POST/token"
      },
      {
        Sid       = "AllowAnyToRevocationEndpoints"
        Effect    = "Allow"
        Principal = "*"
        Action    = "execute-api:Invoke"
        Resource = [
          "arn:aws:execute-api:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:${aws_api_gateway_rest_api.this.id}/*/POST/revoke",
          "arn:aws:execute-api:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:${aws_api_gateway_rest_api.this.id}/*/GET/revoked",
        ]
      },
    ]
  })
}

# --- /token → generator (Node) -----------------------------------------

resource "aws_api_gateway_resource" "token" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "token"
}

resource "aws_api_gateway_method" "token_post" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.token.id
  http_method   = "POST"
  authorization = local.token_authorization
}

resource "aws_api_gateway_integration" "token_post" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.token.id
  http_method             = aws_api_gateway_method.token_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.generator.invoke_arn
}

resource "aws_lambda_permission" "token_apigw" {
  statement_id  = "AllowAPIGatewayInvokeToken"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.generator.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/POST/token"
}

# --- /revoke -----------------------------------------------------------

resource "aws_api_gateway_resource" "revoke" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "revoke"
}

resource "aws_api_gateway_method" "revoke_post" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.revoke.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "revoke_post" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.revoke.id
  http_method             = aws_api_gateway_method.revoke_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.revoker.invoke_arn
}

resource "aws_lambda_permission" "revoke_apigw" {
  statement_id  = "AllowAPIGatewayInvokeRevoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.revoker.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/POST/revoke"
}

# --- /revoked (GET) ----------------------------------------------------

resource "aws_api_gateway_resource" "revoked" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "revoked"
}

resource "aws_api_gateway_method" "revoked_get" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.revoked.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "revoked_get" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.revoked.id
  http_method             = aws_api_gateway_method.revoked_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.list_revoked.invoke_arn
}

resource "aws_lambda_permission" "revoked_apigw" {
  statement_id  = "AllowAPIGatewayInvokeRevoked"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.list_revoked.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/GET/revoked"
}

# --- Deployment + stage ------------------------------------------------

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  # Triggers redeploy on any change to routes/methods/integrations.
  # Also hash token_post.authorization so flipping the AWS_IAM gate
  # forces a fresh deployment out to the stage.
  #
  # Do NOT include aws_api_gateway_rest_api.this.policy here. AWS
  # normalizes the resource policy JSON on write-back (reorders keys,
  # rewraps Principal), so sha1(jsonencode([...policy...])) evaluates
  # differently on plan (config input) vs apply (state read-back),
  # producing the "Provider produced inconsistent final plan" error
  # deterministically. Resource policies attach at the API level and
  # take effect immediately without a deployment, so the trigger was
  # overzealous — policy changes don't need a stage redeploy anyway.
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.token.id,
      aws_api_gateway_method.token_post.id,
      aws_api_gateway_method.token_post.authorization,
      aws_api_gateway_integration.token_post.id,
      aws_api_gateway_resource.revoke.id,
      aws_api_gateway_method.revoke_post.id,
      aws_api_gateway_integration.revoke_post.id,
      aws_api_gateway_resource.revoked.id,
      aws_api_gateway_method.revoked_get.id,
      aws_api_gateway_integration.revoked_get.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "prod" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  deployment_id = aws_api_gateway_deployment.this.id
  # The stage_name is the last path segment of the APIGW invoke URL.
  # The aws-solutions-library-samples reference solution hardcodes it to
  # "prod" — which reads as "prod stage" regardless of the actual AWS
  # environment (confusing on non-prod accounts). Parameterize on
  # environment so the URL path reflects the environment name.
  #
  # `stage_name` is `ForceNew`, so changing this value on an existing
  # deployment destroys+recreates the APIGW stage. Coordinate any
  # downstream callers (e.g., server-side token minters holding the
  # invoke URL) with the apply window.
  stage_name = local.environment
}
