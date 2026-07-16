# CloudFront distribution + api-path-rewriter function + Kinesis real-time
# logging pipeline.
#
# Demo variant (stage): HttpOrigin cdn.mediaplaypen.com on default, /api/*
# → APIGW, /website/* → S3 demo. Matches the CDK enableDemo=true path.

# --- api-path-rewriter function ----------------------------------------

resource "aws_cloudfront_function" "api_path_rewriter" {
  name    = "${local.name_prefix}-${local.environment}-api-path-rewriter"
  runtime = "cloudfront-js-2.0"
  comment = "Strip /api prefix before forwarding to APIGW."
  publish = true
  code    = <<-EOT
    function handler(event) {
      var req = event.request;
      if (req.uri.indexOf('/api/') === 0) {
        req.uri = req.uri.substring(4);
      }
      return req;
    }
  EOT
}

# --- Kinesis real-time log stream --------------------------------------

resource "aws_kinesis_stream" "realtime_logs" {
  name             = "${local.name_prefix}-${local.environment}-realtime-logs"
  retention_period = 24

  stream_mode_details {
    stream_mode = "ON_DEMAND"
  }
}

data "aws_iam_policy_document" "cf_kinesis_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cf_kinesis" {
  name               = "${local.name_prefix}-${local.environment}-cf-kinesis"
  assume_role_policy = data.aws_iam_policy_document.cf_kinesis_assume.json
}

data "aws_iam_policy_document" "cf_kinesis_write" {
  statement {
    actions = [
      "kinesis:PutRecord",
      "kinesis:PutRecords",
      "kinesis:DescribeStreamSummary",
      "kinesis:DescribeStream",
    ]
    resources = [aws_kinesis_stream.realtime_logs.arn]
  }
}

resource "aws_iam_role_policy" "cf_kinesis_write" {
  name   = "kinesis-write"
  role   = aws_iam_role.cf_kinesis.id
  policy = data.aws_iam_policy_document.cf_kinesis_write.json
}

resource "aws_cloudfront_realtime_log_config" "this" {
  name          = "${local.name_prefix}-${local.environment}-realtime-logs"
  sampling_rate = 100
  fields = [
    "timestamp", "c-ip", "sc-status", "cs-uri-stem", "cs-method",
    "cs-host", "cs-user-agent", "sc-bytes", "time-taken", "c-country",
  ]

  endpoint {
    stream_type = "Kinesis"

    kinesis_stream_config {
      role_arn   = aws_iam_role.cf_kinesis.arn
      stream_arn = aws_kinesis_stream.realtime_logs.arn
    }
  }
}

# --- Custom cache policy for default behavior (allowlist Country header) --

resource "aws_cloudfront_cache_policy" "with_country_header" {
  name        = "${local.name_prefix}-${local.environment}-cache-policy"
  min_ttl     = 0
  default_ttl = 86400
  max_ttl     = 31536000

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_brotli = true
    enable_accept_encoding_gzip   = true

    cookies_config {
      cookie_behavior = "none"
    }

    query_strings_config {
      query_string_behavior = "none"
    }

    headers_config {
      header_behavior = "whitelist"
      headers {
        items = ["CloudFront-Viewer-Country"]
      }
    }
  }
}

# --- Distribution ------------------------------------------------------

resource "aws_cloudfront_distribution" "this" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "CTA-5007-B secure media distribution."
  web_acl_id      = aws_wafv2_web_acl.this.arn

  # Default behavior — demo origin, validator on viewer-request, real-time logs
  origin {
    origin_id   = "demo-origin"
    domain_name = "cdn.mediaplaypen.com"

    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_protocol_policy   = "https-only"
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_keepalive_timeout = 5
      origin_read_timeout      = 30
    }
  }

  default_cache_behavior {
    target_origin_id         = "demo-origin"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD"]
    cached_methods           = ["GET", "HEAD"]
    compress                 = true
    cache_policy_id          = aws_cloudfront_cache_policy.with_country_header.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
    realtime_log_config_arn  = aws_cloudfront_realtime_log_config.this.arn

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.validator.arn
    }
  }

  # /api/* → APIGW (with the URL-rewrite function stripping /api/ prefix)
  origin {
    origin_id   = "api-origin"
    domain_name = "${aws_api_gateway_rest_api.this.id}.execute-api.${data.aws_region.current.region}.amazonaws.com"
    origin_path = "/${aws_api_gateway_stage.prod.stage_name}"

    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_protocol_policy   = "https-only"
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_keepalive_timeout = 5
      origin_read_timeout      = 30
    }
  }

  ordered_cache_behavior {
    path_pattern             = "/api/*"
    target_origin_id         = "api-origin"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods           = ["GET", "HEAD"]
    compress                 = true
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.api_path_rewriter.arn
    }
  }

  # /website/* → S3 demo bucket
  origin {
    origin_id                = "demo-website"
    domain_name              = aws_s3_bucket.demo.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.demo.id
  }

  ordered_cache_behavior {
    path_pattern           = "/website/*"
    target_origin_id       = "demo-website"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = data.aws_cloudfront_cache_policy.caching_optimized.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  price_class = "PriceClass_100"
}

# --- Managed policy lookups --------------------------------------------

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}
