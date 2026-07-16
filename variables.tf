variable "environment" {
  type        = string
  description = "Deployment environment name. Used in resource names and the Secrets Manager secret path (e.g. `staging`, `prod`)."
  nullable    = false
}

variable "region" {
  type        = string
  description = "AWS region. WAFv2 CLOUDFRONT-scoped resources require us-east-1 regardless of this value — set your provider block accordingly."
  default     = "us-east-1"
  nullable    = false
}

variable "account_id" {
  type        = string
  description = "Optional AWS account id. When set, the module asserts the caller identity matches — guards against workspace/tfvars mismatch. Leave empty to skip the check."
  default     = ""
  nullable    = false
}

variable "name_prefix" {
  type        = string
  description = "Prefix for named resources (Lambda functions, KVS, WebACL, etc.)."
  default     = "cta-secure-media"
  nullable    = false
}

variable "signing_key_length" {
  type        = number
  description = "HMAC signing key length in bytes. 64 matches the CDK reference solution."
  default     = 64
  nullable    = false
}

variable "rotation_schedule" {
  type        = string
  description = "EventBridge schedule expression for the signing-key rotation Step Function. Default matches the CDK reference solution's 30-day cadence."
  default     = "rate(30 days)"
  nullable    = false
}

variable "secret_recovery_window_days" {
  type        = number
  description = "Recovery window for the Secrets Manager signing-key secret. 0 destroys immediately (safe for dev/stage); 7-30 gives an undo window in prod."
  default     = 0
  nullable    = false
}

variable "token_rate_limit_per_5min" {
  type        = number
  description = "WAFv2 rate-based rule limit for POST /api/token per source IP, per rolling 5-minute window. Default 300 (~60/min) is well above legitimate player traffic for typical CTA token cadences."
  default     = 300
  nullable    = false
}
