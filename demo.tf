# S3 demo bucket + upload of resources/demo-website/.
#
# Currently unconditional — this port covers stage only (per VID-3439
# ticket scope), and stage always wants the demo. When prod deployment
# is scoped, add an `enable_demo` variable and gate these resources
# with `count`; the distribution's /website/* behavior + demo-website
# origin need matching conditionalization at that time.
#
# Dashboard is not included in this port (was optional in the CDK
# stack too).

resource "aws_s3_bucket" "demo" {
  bucket_prefix = "${local.name_prefix}-${local.environment}-demo-"
  # Stage: force_destroy so `terraform destroy` wipes the bucket cleanly.
  # PROD_TODO: flip to false (or make env-gated) on the prod cutover so
  # accidental destroys fail loudly rather than silently take down demo
  # objects. See README "Prod cutover" section.
  force_destroy = local.environment == "prod" ? false : true
}

resource "aws_s3_bucket_public_access_block" "demo" {
  bucket                  = aws_s3_bucket.demo.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "demo" {
  name                              = "${local.name_prefix}-${local.environment}-demo-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_iam_policy_document" "demo_bucket_policy" {
  statement {
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.demo.arn}/*"]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.this.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "demo" {
  bucket = aws_s3_bucket.demo.id
  policy = data.aws_iam_policy_document.demo_bucket_policy.json
}

# Upload every file under resources/demo-website/ to s3://<bucket>/website/
resource "aws_s3_object" "demo_files" {
  for_each = fileset("${path.module}/../source/resources/demo-website", "**/*")

  bucket = aws_s3_bucket.demo.id
  key    = "website/${each.value}"
  source = "${path.module}/../source/resources/demo-website/${each.value}"
  etag   = filemd5("${path.module}/../source/resources/demo-website/${each.value}")

  content_type = lookup(
    {
      "html" = "text/html"
      "css"  = "text/css"
      "js"   = "application/javascript"
      "json" = "application/json"
      "png"  = "image/png"
      "jpg"  = "image/jpeg"
      "svg"  = "image/svg+xml"
    },
    element(reverse(split(".", each.value)), 0),
    "application/octet-stream"
  )
}
