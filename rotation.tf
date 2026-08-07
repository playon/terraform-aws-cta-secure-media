# Key rotation: SyncKeysToKvs Lambda + Step Functions + EventBridge rule +
# initial-sync invocation (TF-native replacement for the CDK custom resource).

# --- Zip the sync_keys subdir separately (its own handler at index.js) --

data "archive_file" "lambda_sync_keys" {
  type        = "zip"
  source_dir  = "${path.module}/../source/lambda/sync_keys"
  output_path = "${path.module}/.terraform/lambda-sync-keys.zip"
}

# --- Sync keys Lambda: rotates the secret + writes new pubkey to KVS ---

resource "aws_iam_role" "sync_keys" {
  name               = "${local.name_prefix}-${local.environment}-sync-keys"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "sync_keys_logs" {
  role       = aws_iam_role.sync_keys.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "sync_keys_secret" {
  statement {
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:PutSecretValue",
      "secretsmanager:UpdateSecret",
    ]
    resources = [aws_secretsmanager_secret.signing_key.arn]
  }
}

resource "aws_iam_role_policy" "sync_keys_secret" {
  name   = "secret-read-write"
  role   = aws_iam_role.sync_keys.id
  policy = data.aws_iam_policy_document.sync_keys_secret.json
}

resource "aws_iam_role_policy" "sync_keys_kvs" {
  name   = "kvs-write"
  role   = aws_iam_role.sync_keys.id
  policy = data.aws_iam_policy_document.kvs_write.json
}

resource "aws_lambda_function" "sync_keys" {
  function_name    = "${local.name_prefix}-${local.environment}-sync-keys"
  role             = aws_iam_role.sync_keys.arn
  runtime          = "nodejs22.x"
  handler          = "index.handler"
  filename         = data.archive_file.lambda_sync_keys.output_path
  source_code_hash = data.archive_file.lambda_sync_keys.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      SECRET_NAME = aws_secretsmanager_secret.signing_key.arn
      KVS_ARN     = aws_cloudfront_key_value_store.this.arn
    }
  }
}

# --- Initial sync: TF-native replacement for the CDK custom resource ---
#
# CDK wraps this Lambda in a CustomResource with `Timestamp: Date.now()`
# to force invocation on each deploy. TF equivalent: aws_lambda_invocation
# with a CFN-shaped event so the Lambda's existing RequestType branch
# fires without needing a code change (see source/lambda/sync_keys/index.js
# — it checks event.RequestType for the CDK path, event.rotate for the
# SFN path). Rerun is keyed on the secret version so a rotation-driven
# secret change triggers a resync on the next apply.
resource "aws_lambda_invocation" "initial_key_sync" {
  function_name = aws_lambda_function.sync_keys.function_name
  input = jsonencode({
    RequestType    = "Create"
    secret_version = aws_secretsmanager_secret_version.signing_key.version_id
  })
  triggers = {
    secret_version = aws_secretsmanager_secret_version.signing_key.version_id
  }
}

# --- Step Functions workflow: rotate the key on schedule ---------------

data "aws_iam_policy_document" "sfn_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "rotation_sfn" {
  name               = "${local.name_prefix}-${local.environment}-rotation-sfn"
  assume_role_policy = data.aws_iam_policy_document.sfn_assume.json
}

data "aws_iam_policy_document" "rotation_sfn_invoke" {
  statement {
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.sync_keys.arn]
  }
}

resource "aws_iam_role_policy" "rotation_sfn_invoke" {
  name   = "invoke-sync-keys"
  role   = aws_iam_role.rotation_sfn.id
  policy = data.aws_iam_policy_document.rotation_sfn_invoke.json
}

resource "aws_sfn_state_machine" "rotation" {
  name     = "${local.name_prefix}-${local.environment}-RotateKeys"
  role_arn = aws_iam_role.rotation_sfn.arn

  definition = jsonencode({
    StartAt = "RotateSigningKey"
    States = {
      RotateSigningKey = {
        Type       = "Task"
        Resource   = "arn:aws:states:::lambda:invoke"
        End        = true
        ResultPath = null
        Parameters = {
          FunctionName = aws_lambda_function.sync_keys.arn
          Payload      = { rotate = true }
        }
        Retry = [{
          ErrorEquals = [
            "Lambda.ClientExecutionTimeoutException",
            "Lambda.ServiceException",
            "Lambda.AWSLambdaException",
            "Lambda.SdkClientException",
          ]
          IntervalSeconds = 2
          MaxAttempts     = 6
          BackoffRate     = 2
        }]
      }
    }
  })
}

# --- EventBridge rule triggering rotation ------------------------------

data "aws_iam_policy_document" "rotation_events_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "rotation_events" {
  name               = "${local.name_prefix}-${local.environment}-rotation-events"
  assume_role_policy = data.aws_iam_policy_document.rotation_events_assume.json
}

data "aws_iam_policy_document" "rotation_events_start" {
  statement {
    actions   = ["states:StartExecution"]
    resources = [aws_sfn_state_machine.rotation.arn]
  }
}

resource "aws_iam_role_policy" "rotation_events_start" {
  name   = "start-rotation"
  role   = aws_iam_role.rotation_events.id
  policy = data.aws_iam_policy_document.rotation_events_start.json
}

resource "aws_cloudwatch_event_rule" "rotation_schedule" {
  name                = "${local.name_prefix}-${local.environment}-key-rotation"
  description         = "Trigger CTA signing key rotation on a schedule. VID-3439."
  schedule_expression = var.rotation_schedule
}

resource "aws_cloudwatch_event_target" "rotation_target" {
  rule      = aws_cloudwatch_event_rule.rotation_schedule.name
  target_id = "RotationStateMachine"
  arn       = aws_sfn_state_machine.rotation.arn
  role_arn  = aws_iam_role.rotation_events.arn
}
