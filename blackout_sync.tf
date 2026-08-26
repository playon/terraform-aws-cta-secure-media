# Blackout sync-writer.
#
# Reconciler Lambda that mirrors per-broadcast DMA blocklists from an
# upstream service into CloudFront KVS every 5 minutes. Consumed by the
# CTA validator, which reads `blackout:<broadcast_id>` per viewer request.
#
# Gated on `dma_enforcement_mode` — the whole stack (Lambda, IAM, schedule)
# is only created when the DMA gate is `log` or `enforce`. Consumers who
# don't want DMA enforcement pay zero (no idle 5-min invocations, no IAM
# footprint).

locals {
  blackout_sync_enabled = var.dma_enforcement_mode != "off" ? 1 : 0
}

# --- Zip the blackout_sync subdir separately ----------------------------

data "archive_file" "lambda_blackout_sync" {
  count       = local.blackout_sync_enabled
  type        = "zip"
  source_dir  = "${path.module}/source/lambda/blackout_sync"
  output_path = "${path.module}/.terraform/lambda-blackout-sync.zip"
  excludes    = ["__tests__/**", "node_modules/.cache/**"]

  lifecycle {
    precondition {
      condition     = var.blackout_api_base_url != ""
      error_message = "blackout_api_base_url is required when dma_enforcement_mode is 'log' or 'enforce'."
    }
  }
}

# --- IAM ---------------------------------------------------------------

resource "aws_iam_role" "blackout_sync" {
  count              = local.blackout_sync_enabled
  name               = "${local.name_prefix}-${local.environment}-blackout-sync"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "blackout_sync_logs" {
  count      = local.blackout_sync_enabled
  role       = aws_iam_role.blackout_sync[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "blackout_sync_kvs" {
  count  = local.blackout_sync_enabled
  name   = "kvs-reconcile"
  role   = aws_iam_role.blackout_sync[0].id
  policy = data.aws_iam_policy_document.kvs_reconcile.json
}

# --- Lambda -----------------------------------------------------------

resource "aws_lambda_function" "blackout_sync" {
  count            = local.blackout_sync_enabled
  function_name    = "${local.name_prefix}-${local.environment}-blackout-sync"
  role             = aws_iam_role.blackout_sync[0].arn
  runtime          = "nodejs22.x"
  handler          = "index.handler"
  filename         = data.archive_file.lambda_blackout_sync[0].output_path
  source_code_hash = data.archive_file.lambda_blackout_sync[0].output_base64sha256
  timeout          = 300
  memory_size      = 512

  environment {
    variables = {
      KVS_ARN                = aws_cloudfront_key_value_store.this.arn
      BLACKOUT_API_BASE_URL  = var.blackout_api_base_url
      PAGE_SIZE              = "1000"
      SCAN_WINDOW_PAST_HOURS = "24"
      # 6 hours forward is ~72 sync cycles of buffer at the 5-minute
      # EventBridge cadence. Broadcasts scheduled further out roll into
      # the window as their start_time approaches; a much wider window
      # preloads broadcasts that won't be viewable for weeks and hammers
      # the upstream service for zero correctness benefit.
      SCAN_WINDOW_FUTURE_HOURS = "6"
    }
  }
}

# --- EventBridge 5-min schedule ----------------------------------------

resource "aws_cloudwatch_event_rule" "blackout_sync_schedule" {
  count               = local.blackout_sync_enabled
  name                = "${local.name_prefix}-${local.environment}-blackout-sync"
  description         = "Trigger CTA DMA blackout reconciliation."
  schedule_expression = "rate(5 minutes)"
}

resource "aws_cloudwatch_event_target" "blackout_sync_target" {
  count     = local.blackout_sync_enabled
  rule      = aws_cloudwatch_event_rule.blackout_sync_schedule[0].name
  target_id = "BlackoutSyncLambda"
  arn       = aws_lambda_function.blackout_sync[0].arn
}

resource "aws_lambda_permission" "blackout_sync_events" {
  count         = local.blackout_sync_enabled
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.blackout_sync[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.blackout_sync_schedule[0].arn
}
