variable "account_id" {
  type        = string
  description = "Optional guard: assert the caller identity matches this account id before applying. Guards against pointing the wrong workspace at a shared account. Leave empty to skip the check."
  default     = ""
  nullable    = false
}

variable "region" {
  type        = string
  description = "AWS region for module resources. WAFv2 CLOUDFRONT-scoped resources always live in us-east-1 regardless of this value, so if you set a non-us-east-1 region here you also need `provider \"aws\" { alias = \"us_east_1\" }` in the calling config — the WAF resource explicitly uses us-east-1."
  default     = "us-east-1"
  nullable    = false
}

variable "environment" {
  type        = string
  description = "Deployment environment slug (e.g., staging, prod). Used in resource names and the APIGW stage_name."
  nullable    = false
}

variable "name_prefix" {
  type        = string
  description = "Prefix for named resources (function, key group, WebACL, etc.)."
  default     = "cta-secure-media"
  nullable    = false
}

variable "signing_key_length" {
  type        = number
  description = "HMAC signing key length. 64 matches the CDK reference solution."
  default     = 64
  nullable    = false
}

variable "secret_recovery_window_days" {
  type        = number
  description = "AWS Secrets Manager recovery window (in days) for the signing-key secret. 0 = immediate destroy (fine for ephemeral non-prod envs); 7-30 keeps the secret recoverable for that many days after a `terraform destroy`. Default `30` is the safe production choice — flip to `0` in throwaway environments so `terraform destroy` doesn't leave orphan secrets that block re-apply for a month."
  default     = 30
  nullable    = false

  validation {
    condition     = var.secret_recovery_window_days == 0 || (var.secret_recovery_window_days >= 7 && var.secret_recovery_window_days <= 30)
    error_message = "secret_recovery_window_days must be 0, or between 7 and 30 (inclusive)."
  }
}

variable "demo_bucket_force_destroy" {
  type        = bool
  description = "When true, `terraform destroy` empties + removes the demo S3 bucket even if it still holds objects. Convenient for throwaway envs. Set false in prod so an accidental destroy fails loudly rather than silently taking demo objects with it."
  default     = false
  nullable    = false
}

variable "token_rate_limit_per_5min" {
  type        = number
  description = "WAFv2 rate-based limit (per source IP, 5-minute sliding window) for POST /api/token. The 'well above legitimate traffic' threshold depends entirely on the consumer's token cadence — a viewer who mints once per session sits at ~1/hr, but a burst-y refresh pattern can hit dozens per session. Default 300 matches PlayOn's minter cadence; tune per consumer."
  default     = 300
  nullable    = false

  validation {
    condition     = var.token_rate_limit_per_5min >= 100 && var.token_rate_limit_per_5min <= 20000000
    error_message = "token_rate_limit_per_5min must be within AWS WAF rate-based limits (100 - 20,000,000)."
  }
}

variable "rotation_schedule" {
  type        = string
  description = "EventBridge schedule expression for the signing-key rotation Step Function. Default matches the CDK stack's 30-day cadence."
  default     = "rate(30 days)"
  nullable    = false
}

variable "demo_origin_domain" {
  type        = string
  description = "Default-behavior origin domain. Stage default matches the CDK reference solution's demo playback host. Override in prod tfvars to point at real content origin."
  default     = "cdn.mediaplaypen.com"
  nullable    = false
}

variable "geo_restriction_type" {
  type        = string
  description = "CloudFront distribution geo restriction. 'none' allows worldwide access; 'whitelist' + `geo_restriction_locations` limits to the listed ISO country codes; 'blacklist' blocks those. Default 'none' since the module is meant to work worldwide out of the box; set a whitelist if your CDN policy requires it."
  default     = "none"
  nullable    = false

  validation {
    condition     = contains(["none", "whitelist", "blacklist"], var.geo_restriction_type)
    error_message = "geo_restriction_type must be one of: none, whitelist, blacklist."
  }
}

variable "geo_restriction_locations" {
  type        = list(string)
  description = "ISO 3166-1 alpha-2 country codes for the geo restriction. Ignored when geo_restriction_type = 'none'. Example: [\"US\", \"CA\"]."
  default     = []
  nullable    = false
}

variable "broadcast_uri_prefix" {
  type        = string
  description = "URI prefix under which broadcasts are served (e.g., '/broadcast/'). The validator uses this to extract the broadcast id from the request URI for DMA blackout lookup. Must begin and end with a slash. Set to the prefix that fronts your own content."
  default     = "/broadcast/"
  nullable    = false

  validation {
    condition     = can(regex("^/.*/$", var.broadcast_uri_prefix))
    error_message = "broadcast_uri_prefix must start and end with '/', e.g., '/broadcast/'."
  }
}

variable "blackout_api_base_url" {
  type        = string
  description = "Base URL of the upstream service the blackout sync-writer reads per-broadcast DMA blocklists from. The Lambda hits `<base>/v2/broadcasts/dmas`. Anonymous read endpoint by default; if your upstream needs auth, extend `source/lambda/blackout_sync/blackout_client.js`. Required when `dma_enforcement_mode` is `log` or `enforce`; ignored (and the blackout_sync resources are not created) when `off`."
  default     = ""
  nullable    = false
}

# Per-broadcast DMA blackout enforcement at the CloudFront edge via the
# sync-writer's KVS entries. Independent of token validation — DMA
# check runs even when token enforcement is off.
variable "dma_enforcement_mode" {
  type        = string
  description = "DMA blackout enforcement mode. 'off' skips the check entirely (zero KVS lookups per request). 'log' computes the block decision and emits a CloudWatch log line but always forwards — useful for measuring the population that WOULD be blocked before flipping to enforce. 'enforce' rejects blocked viewers with 451 Unavailable For Legal Reasons and body 'blackout_dma'."
  default     = "off"
  nullable    = false

  validation {
    condition     = contains(["off", "log", "enforce"], var.dma_enforcement_mode)
    error_message = "dma_enforcement_mode must be one of: off, log, enforce."
  }
}

variable "drm_api_lambda_role_arn" {
  type        = string
  description = "ARN of the IAM role your server-side token-minting Lambda assumes (typically the license/DRM API). When non-empty, flips POST /api/token to AWS_IAM authorization and installs a resource policy allowing invoke only from this role — anonymous callers hit 403 at APIGW. Leave empty to preserve the reference-solution behavior (authorization = NONE, anyone can mint)."
  default     = ""
  nullable    = false
}

# Transitional User-Agent allowlist. Legacy native app installs
# (iOS, Android, tvOS, Roku) can't always ship CTA-minting builds on
# the enforcement cutover date, and a hard flip blacks them out.
# Patterns here are regex strings matched against the viewer
# User-Agent header at the CTA validator; matches bypass token
# validation entirely (DMA blackout still runs).
variable "legacy_client_allowlist" {
  type        = list(string)
  description = "Regex patterns matched against the viewer User-Agent. Requests whose UA matches ANY pattern bypass CTA token validation. Order: after DMA blackout, before token check. Keep list small (< 20 entries) — matcher is linear per request. Empty list disables the bridge."
  default     = []
  nullable    = false

  # Guard against a bad regex bricking the edge. new RegExp(...) runs at
  # CloudFront-Function-init on every invocation; an uncompilable pattern
  # throws before we reach the handler and every viewer request 5xxs.
  # Terraform's `regex` is RE2, which is stricter than JS (no lookaheads,
  # etc.), so this catches obvious syntax errors at plan time. Anchored
  # literal prefixes are the intended shape here — RE2 handles them fine.
  validation {
    condition     = alltrue([for p in var.legacy_client_allowlist : can(regex(p, ""))])
    error_message = "Each legacy_client_allowlist entry must be a valid RE2 regex."
  }
}

# Token-check enforcement mode. Parallel shape to dma_enforcement_mode.
variable "token_enforcement_mode" {
  type        = string
  description = "CTA token validation mode. 'off' skips the check entirely — the validator forwards every viewer request without inspecting the token (break-glass bypass; DMA enforcement still runs). 'log' runs the check and emits a Kinesis/CloudWatch log line on failure but forwards anyway — measures the population that WOULD be blocked before flipping to enforce. 'enforce' rejects with 401 (missing/invalid/expired) or 410 (revoked). DMA blackout enforcement is independent (dma_enforcement_mode)."
  default     = "enforce"
  nullable    = false

  validation {
    condition     = contains(["off", "log", "enforce"], var.token_enforcement_mode)
    error_message = "token_enforcement_mode must be one of: off, log, enforce."
  }
}
