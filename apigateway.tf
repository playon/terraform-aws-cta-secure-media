# API Gateway REST API — token mint (Node/Python/Ruby), revoke, list-revoked.

locals {
  # When token_authorized_role_arn is set, POST /token requires SigV4-signed
  # requests from that specific role (IAM auth + resource policy). Anonymous
  # POSTs return 403. Empty string preserves the reference-solution shape.
  token_authorization = var.token_authorized_role_arn != "" ? "AWS_IAM" : "NONE"
}

resource "aws_api_gateway_rest_api" "this" {
  name        = "${local.name_prefix}-${local.environment}"
  description = "CTA Token API."

  endpoint_configuration {
    types = ["EDGE"]
  }

  # Resource policy pins invoke on POST /token to the configured role.
  # Other routes stay open on the resource-policy dimension (the module
  # doesn't attempt to lock /revoke or /revoked — adopters can layer
  # additional policy if needed).
  policy = var.token_authorized_role_arn == "" ? null : jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowAuthorizedRoleToMint"
        Effect    = "Allow"
        Principal = { AWS = var.token_authorized_role_arn }
        Action    = "execute-api:Invoke"
        Resource  = "execute-api:/*/POST/token"
      },
      {
        Sid       = "AllowAnyToOtherRoutes"
        Effect    = "Allow"
        Principal = "*"
        Action    = "execute-api:Invoke"
        Resource = [
          "execute-api:/*/POST/revoke",
          "execute-api:/*/GET/revoked",
          "execute-api:/*/POST/token-python",
          "execute-api:/*/POST/token-ruby",
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

# --- /token-python -----------------------------------------------------

resource "aws_api_gateway_resource" "token_python" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "token-python"
}

resource "aws_api_gateway_method" "token_python_post" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.token_python.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "token_python_post" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.token_python.id
  http_method             = aws_api_gateway_method.token_python_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.generator_python.invoke_arn
}

resource "aws_lambda_permission" "token_python_apigw" {
  statement_id  = "AllowAPIGatewayInvokeTokenPython"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.generator_python.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/POST/token-python"
}

# --- /token-ruby -------------------------------------------------------

resource "aws_api_gateway_resource" "token_ruby" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "token-ruby"
}

resource "aws_api_gateway_method" "token_ruby_post" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.token_ruby.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "token_ruby_post" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.token_ruby.id
  http_method             = aws_api_gateway_method.token_ruby_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.generator_ruby.invoke_arn
}

resource "aws_lambda_permission" "token_ruby_apigw" {
  statement_id  = "AllowAPIGatewayInvokeTokenRuby"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.generator_ruby.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/POST/token-ruby"
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

  # Triggers redeploy on any change to routes/methods/integrations, plus
  # the REST API policy + token method authorization so flipping IAM auth
  # forces a fresh deployment out to the stage.
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_rest_api.this.policy,
      aws_api_gateway_resource.token.id,
      aws_api_gateway_method.token_post.id,
      aws_api_gateway_method.token_post.authorization,
      aws_api_gateway_integration.token_post.id,
      aws_api_gateway_resource.token_python.id,
      aws_api_gateway_method.token_python_post.id,
      aws_api_gateway_integration.token_python_post.id,
      aws_api_gateway_resource.token_ruby.id,
      aws_api_gateway_method.token_ruby_post.id,
      aws_api_gateway_integration.token_ruby_post.id,
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
  stage_name    = "prod"
}
