output "kvs_arn" {
  description = "CloudFront KeyValueStore ARN. Referenced by any consumer that wants to attach a CloudFront Function reading from this KVS."
  value       = aws_cloudfront_key_value_store.this.arn
}

output "kvs_id" {
  description = "CloudFront KeyValueStore ID."
  value       = aws_cloudfront_key_value_store.this.id
}

output "validator_function_arn" {
  description = "CTA validator CloudFront Function ARN. Attach this to the viewer-request phase of your content distribution's cache behaviors to enable token + DMA blackout enforcement."
  value       = aws_cloudfront_function.validator.arn
}

output "signing_secret_arn" {
  description = "Secrets Manager secret ARN holding the HMAC signing key."
  value       = aws_secretsmanager_secret.signing_key.arn
}

output "api_endpoint" {
  description = "CTA API endpoint (via CloudFront). Consumers POST to <endpoint>/token, /revoke, etc."
  value       = "https://${aws_cloudfront_distribution.this.domain_name}/api"
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID."
  value       = aws_cloudfront_distribution.this.id
}

output "cloudfront_domain_name" {
  description = "CloudFront distribution domain name."
  value       = aws_cloudfront_distribution.this.domain_name
}

output "demo_website_url" {
  description = "Demo website URL (only meaningful when the demo bucket is populated)."
  value       = "https://${aws_cloudfront_distribution.this.domain_name}/website/index.html"
}

output "rotation_workflow_name" {
  description = "Step Functions state machine name for signing-key rotation."
  value       = aws_sfn_state_machine.rotation.name
}

output "web_acl_arn" {
  description = "WAFv2 Web ACL ARN — rate-limits POST /api/token."
  value       = aws_wafv2_web_acl.this.arn
}

