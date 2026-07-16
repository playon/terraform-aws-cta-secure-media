# Lambda functions — mint (Node/Python/Ruby), revoke, list-revoked, kvs-cleanup.
# The rotation Lambda (SyncKeysToKvs) lives in rotation.tf next to its
# Step Functions + EventBridge setup.
#
# Note on packaging: archive_file zips the source directory as-is. For
# the Node lambda, its package.json declares cbor-x + @aws-sdk/* which
# must be installed BEFORE `terraform apply`. Run `make lambda-deps` at
# the repo root, or `npm install --omit=dev --prefix source/lambda`
# manually. Python + Ruby lambdas are stdlib-only.

# --- Zip source directories --------------------------------------------

data "archive_file" "lambda_node" {
  type        = "zip"
  source_dir  = "${path.module}/source/lambda"
  output_path = "${path.module}/.terraform/lambda-node.zip"
  # Exclude the sync_keys subdir — it's a separate function.
  excludes = ["sync_keys/**", ".jest-cache/**", "__tests__/**"]
}

data "archive_file" "lambda_python" {
  type        = "zip"
  source_dir  = "${path.module}/source/lambda-python"
  output_path = "${path.module}/.terraform/lambda-python.zip"
}

data "archive_file" "lambda_ruby" {
  type        = "zip"
  source_dir  = "${path.module}/source/lambda-ruby"
  output_path = "${path.module}/.terraform/lambda-ruby.zip"
}

# --- Shared IAM for Lambda logging -------------------------------------

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# --- Token generator (Node) --------------------------------------------

resource "aws_iam_role" "generator" {
  name               = "${local.name_prefix}-${local.environment}-generator"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "generator_logs" {
  role       = aws_iam_role.generator.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "generator_secret_read" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.signing_key.arn]
  }
}

resource "aws_iam_role_policy" "generator_secret_read" {
  name   = "read-signing-key"
  role   = aws_iam_role.generator.id
  policy = data.aws_iam_policy_document.generator_secret_read.json
}

resource "aws_lambda_function" "generator" {
  function_name    = "${local.name_prefix}-${local.environment}-generator"
  role             = aws_iam_role.generator.arn
  runtime          = "nodejs22.x"
  handler          = "cta_token_generator.handler"
  filename         = data.archive_file.lambda_node.output_path
  source_code_hash = data.archive_file.lambda_node.output_base64sha256
  timeout          = 10

  environment {
    variables = {
      SECRET_NAME = aws_secretsmanager_secret.signing_key.arn
    }
  }
}

# --- Token generator (Python) ------------------------------------------

resource "aws_iam_role" "generator_python" {
  name               = "${local.name_prefix}-${local.environment}-generator-python"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "generator_python_logs" {
  role       = aws_iam_role.generator_python.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "generator_python_secret_read" {
  name   = "read-signing-key"
  role   = aws_iam_role.generator_python.id
  policy = data.aws_iam_policy_document.generator_secret_read.json
}

resource "aws_lambda_function" "generator_python" {
  function_name    = "${local.name_prefix}-${local.environment}-generator-python"
  role             = aws_iam_role.generator_python.arn
  runtime          = "python3.13"
  handler          = "handler.handler"
  filename         = data.archive_file.lambda_python.output_path
  source_code_hash = data.archive_file.lambda_python.output_base64sha256
  timeout          = 10

  environment {
    variables = {
      SECRET_NAME = aws_secretsmanager_secret.signing_key.arn
    }
  }
}

# --- Token generator (Ruby) --------------------------------------------

resource "aws_iam_role" "generator_ruby" {
  name               = "${local.name_prefix}-${local.environment}-generator-ruby"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "generator_ruby_logs" {
  role       = aws_iam_role.generator_ruby.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "generator_ruby_secret_read" {
  name   = "read-signing-key"
  role   = aws_iam_role.generator_ruby.id
  policy = data.aws_iam_policy_document.generator_secret_read.json
}

resource "aws_lambda_function" "generator_ruby" {
  function_name    = "${local.name_prefix}-${local.environment}-generator-ruby"
  role             = aws_iam_role.generator_ruby.arn
  runtime          = "ruby3.3"
  handler          = "handler.handler"
  filename         = data.archive_file.lambda_ruby.output_path
  source_code_hash = data.archive_file.lambda_ruby.output_base64sha256
  timeout          = 10

  environment {
    variables = {
      SECRET_NAME = aws_secretsmanager_secret.signing_key.arn
    }
  }
}

# --- Revoker -----------------------------------------------------------

resource "aws_iam_role" "revoker" {
  name               = "${local.name_prefix}-${local.environment}-revoker"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "revoker_logs" {
  role       = aws_iam_role.revoker.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "kvs_write" {
  statement {
    actions = [
      "cloudfront-keyvaluestore:PutKey",
      "cloudfront-keyvaluestore:DescribeKeyValueStore",
    ]
    resources = [aws_cloudfront_key_value_store.this.arn]
  }
}

resource "aws_iam_role_policy" "revoker_kvs" {
  name   = "kvs-write"
  role   = aws_iam_role.revoker.id
  policy = data.aws_iam_policy_document.kvs_write.json
}

resource "aws_lambda_function" "revoker" {
  function_name    = "${local.name_prefix}-${local.environment}-revoker"
  role             = aws_iam_role.revoker.arn
  runtime          = "nodejs22.x"
  handler          = "cta_revocation.handler"
  filename         = data.archive_file.lambda_node.output_path
  source_code_hash = data.archive_file.lambda_node.output_base64sha256
  timeout          = 10

  environment {
    variables = {
      KVS_ARN = aws_cloudfront_key_value_store.this.arn
    }
  }
}

# --- List revoked ------------------------------------------------------

resource "aws_iam_role" "list_revoked" {
  name               = "${local.name_prefix}-${local.environment}-list-revoked"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "list_revoked_logs" {
  role       = aws_iam_role.list_revoked.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "kvs_read" {
  statement {
    actions = [
      "cloudfront-keyvaluestore:ListKeys",
      "cloudfront-keyvaluestore:DescribeKeyValueStore",
    ]
    resources = [aws_cloudfront_key_value_store.this.arn]
  }
}

resource "aws_iam_role_policy" "list_revoked_kvs" {
  name   = "kvs-read"
  role   = aws_iam_role.list_revoked.id
  policy = data.aws_iam_policy_document.kvs_read.json
}

resource "aws_lambda_function" "list_revoked" {
  function_name    = "${local.name_prefix}-${local.environment}-list-revoked"
  role             = aws_iam_role.list_revoked.arn
  runtime          = "nodejs22.x"
  handler          = "list_revoked.handler"
  filename         = data.archive_file.lambda_node.output_path
  source_code_hash = data.archive_file.lambda_node.output_base64sha256
  timeout          = 10

  environment {
    variables = {
      KVS_ARN = aws_cloudfront_key_value_store.this.arn
    }
  }
}

# --- KVS Cleanup (purge expired revocations hourly) --------------------

resource "aws_iam_role" "kvs_cleanup" {
  name               = "${local.name_prefix}-${local.environment}-kvs-cleanup"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "kvs_cleanup_logs" {
  role       = aws_iam_role.kvs_cleanup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "kvs_cleanup_perms" {
  statement {
    actions = [
      "cloudfront-keyvaluestore:ListKeys",
      "cloudfront-keyvaluestore:DeleteKey",
      "cloudfront-keyvaluestore:DescribeKeyValueStore",
    ]
    resources = [aws_cloudfront_key_value_store.this.arn]
  }
}

resource "aws_iam_role_policy" "kvs_cleanup_kvs" {
  name   = "kvs-cleanup"
  role   = aws_iam_role.kvs_cleanup.id
  policy = data.aws_iam_policy_document.kvs_cleanup_perms.json
}

resource "aws_lambda_function" "kvs_cleanup" {
  function_name    = "${local.name_prefix}-${local.environment}-kvs-cleanup"
  role             = aws_iam_role.kvs_cleanup.arn
  runtime          = "nodejs22.x"
  handler          = "kvs_cleanup.handler"
  filename         = data.archive_file.lambda_node.output_path
  source_code_hash = data.archive_file.lambda_node.output_base64sha256
  timeout          = 120

  environment {
    variables = {
      KVS_ARN   = aws_cloudfront_key_value_store.this.arn
      TTL_HOURS = "24"
    }
  }
}

resource "aws_cloudwatch_event_rule" "kvs_cleanup_schedule" {
  name                = "${local.name_prefix}-${local.environment}-kvs-cleanup"
  description         = "Purge expired KVS revocation entries hourly."
  schedule_expression = "rate(1 hour)"
}

resource "aws_cloudwatch_event_target" "kvs_cleanup_target" {
  rule      = aws_cloudwatch_event_rule.kvs_cleanup_schedule.name
  target_id = "KvsCleanupLambda"
  arn       = aws_lambda_function.kvs_cleanup.arn
}

resource "aws_lambda_permission" "kvs_cleanup_events" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.kvs_cleanup.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.kvs_cleanup_schedule.arn
}
