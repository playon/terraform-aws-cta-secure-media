# VID-3459 — blackout sync-writer.
#
# Reconciler Lambda that mirrors DMA blackout rules from unity-api
# Postgres into CloudFront KVS every 5 minutes. Consumed by the CTA
# validator (VID-3458) which reads `blackout:<broadcast_id>` per
# viewer-request.

# --- Zip the blackout_sync subdir separately ----------------------------

data "archive_file" "lambda_blackout_sync" {
  type        = "zip"
  source_dir  = "${path.module}/../source/lambda/blackout_sync"
  output_path = "${path.module}/.terraform/lambda-blackout-sync.zip"
  excludes    = ["__tests__/**", "node_modules/.cache/**"]
}

# --- IAM ---------------------------------------------------------------

resource "aws_iam_role" "blackout_sync" {
  name               = "${local.name_prefix}-${local.environment}-blackout-sync"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "blackout_sync_logs" {
  role       = aws_iam_role.blackout_sync.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "blackout_sync_kvs" {
  name   = "kvs-reconcile"
  role   = aws_iam_role.blackout_sync.id
  policy = data.aws_iam_policy_document.kvs_reconcile.json
}

# --- Lambda -----------------------------------------------------------

resource "aws_lambda_function" "blackout_sync" {
  function_name    = "${local.name_prefix}-${local.environment}-blackout-sync"
  role             = aws_iam_role.blackout_sync.arn
  runtime          = "nodejs22.x"
  handler          = "index.handler"
  filename         = data.archive_file.lambda_blackout_sync.output_path
  source_code_hash = data.archive_file.lambda_blackout_sync.output_base64sha256
  timeout          = 300
  memory_size      = 512

  environment {
    variables = {
      KVS_ARN                = aws_cloudfront_key_value_store.this.arn
      UNITY_API_BASE         = var.unity_api_base
      PAGE_SIZE              = "1000"
      SCAN_WINDOW_PAST_HOURS = "24"
      # 6 hours forward is ~72 sync cycles of buffer at the 5-minute
      # EventBridge cadence. Broadcasts scheduled further out roll into
      # the window as their start_time approaches; the previous 30-day
      # window preloaded ~100x more broadcasts than needed and hammered
      # unity-api for zero correctness benefit.
      SCAN_WINDOW_FUTURE_HOURS = "6"
    }
  }
}

# --- EventBridge 5-min schedule ----------------------------------------

resource "aws_cloudwatch_event_rule" "blackout_sync_schedule" {
  name                = "${local.name_prefix}-${local.environment}-blackout-sync"
  description         = "Trigger CTA DMA blackout reconciliation."
  schedule_expression = "rate(5 minutes)"
}

resource "aws_cloudwatch_event_target" "blackout_sync_target" {
  rule      = aws_cloudwatch_event_rule.blackout_sync_schedule.name
  target_id = "BlackoutSyncLambda"
  arn       = aws_lambda_function.blackout_sync.arn
}

resource "aws_lambda_permission" "blackout_sync_events" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.blackout_sync.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.blackout_sync_schedule.arn
}
