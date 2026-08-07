# terraform-aws-cta-secure-media

Terraform port of the AWS reference solution [**Secure Media Delivery at the Edge on AWS**](https://github.com/aws-solutions-library-samples/secure-media-delivery-at-the-edge-on-aws) — a [CTA-5007-B](https://shop.cta.tech/products/common-access-token-cta-5007-b) (Common Access Token / CBOR Web Token) implementation for CloudFront-signed streaming URLs.

Feature-parity with the upstream CDK stack, plus:

- **Two edge gates in one CloudFront Function.** Token validation and DMA blackout enforcement run inline on every viewer request, with independent `off` / `log` / `enforce` toggles.
- **DMA blackout pipeline.** A dedicated `blackout-sync` Lambda reconciles per-broadcast blocklists from an upstream service into the CloudFront KeyValueStore on a 5-minute schedule. The validator joins the viewer's `CloudFront-Viewer-Metro-Code` against the blocklist and returns `451 Unavailable For Legal Reasons` on a match.
- **User-Agent allowlist bridge.** Regex patterns matched against the viewer UA bypass token validation entirely — for legacy clients that can't ship CTA minting before enforcement lands. Sunsets when legacy clients age out.
- **APIGW `/token` lockdown.** Optional `AWS_IAM` authorization + resource policy pinning `POST /api/token` to a single IAM role (typically your server-side token-minting Lambda). Anonymous callers hit 403 at APIGW.
- **WAFv2 rate limit** on `POST /api/token` — defense-in-depth against automated minting even if the IAM lockdown is off.
- **CloudFront Function** to strip `/api/` prefix before forwarding to API Gateway — fixes 403s when hitting the token API through CloudFront.
- **Hourly KVS cleanup Lambda** — purges expired revocation entries so the KeyValueStore doesn't grow unbounded.
- **Hybrid token transport.** The validator accepts the token via `CTA-Common-Access-Token` header, `?CAT=` query param, or URL path segment. (Note: path-segment transport requires your content behavior to be the default cache behavior; otherwise CloudFront routes on the un-stripped URI and misses your ordered pattern.)

## Usage

```hcl
provider "aws" {
  region = "us-east-1"  # WAFv2 CLOUDFRONT scope requires us-east-1
}

module "cta" {
  source = "github.com/playon/terraform-aws-cta-secure-media"

  environment    = "prod"
  account_id     = "123456789012"                     # optional caller-identity guard
  unity_api_base = "https://api.example.com"           # upstream service that supplies DMA blocklists

  # Enable the token gate — flip to "log" first, then "enforce"
  # once clients are minting tokens.
  token_enforcement_mode = "off"                       # off | log | enforce

  # Enable the DMA gate — flip to "log" first, then "enforce"
  # once the log-mode signal is clean.
  dma_enforcement_mode = "off"                         # off | log | enforce

  # Lock the mint API to your server-side signer's IAM role.
  drm_api_lambda_role_arn = "arn:aws:iam::123456789012:role/token-minter"

  # Transitional User-Agent allowlist (bypasses token check).
  legacy_client_allowlist = [
    "^Roku/DVP-",
    "^AppleCoreMedia/",
  ]
}

# Attach the validator to your own content distribution
resource "aws_cloudfront_distribution" "content" {
  # ... your distribution config ...

  default_cache_behavior {
    function_association {
      event_type   = "viewer-request"
      function_arn = module.cta.validator_function_arn
    }
    # ...
  }
}
```

See [`examples/basic/`](examples/basic/) for a full worked example.

## Inputs

| Name | Description | Type | Default |
|---|---|---|---|
| `environment` | Deployment environment slug (e.g., `staging`, `prod`). Used in resource names and the APIGW `stage_name`. | `string` | *(required)* |
| `unity_api_base` | Base URL of the upstream service supplying per-broadcast DMA blocklists. Read from `<base>/v2/broadcasts/dmas`. | `string` | *(required)* |
| `region` | AWS region. WAFv2 CLOUDFRONT scope requires `us-east-1`. | `string` | `"us-east-1"` |
| `account_id` | Optional guard: assert caller identity matches. Empty skips the check. | `string` | `""` |
| `name_prefix` | Prefix for named resources. | `string` | `"cta-secure-media"` |
| `signing_key_length` | HMAC signing key length in bytes. | `number` | `64` |
| `rotation_schedule` | EventBridge schedule for the rotation Step Function. | `string` | `"rate(30 days)"` |
| `demo_origin_domain` | Default-behavior origin. Override to point at a real content origin. | `string` | `"cdn.mediaplaypen.com"` |
| `token_enforcement_mode` | Token gate: `off` skips check entirely; `log` computes but forwards + emits log line; `enforce` rejects with 401. | `string` | `"enforce"` |
| `dma_enforcement_mode` | DMA gate: same shape as `token_enforcement_mode`. Enforcement returns `451` with body `blackout_dma`. | `string` | `"off"` |
| `drm_api_lambda_role_arn` | When non-empty, flips `POST /api/token` to `AWS_IAM` and pins invoke to this role via a resource policy. Empty = anonymous mint (reference-solution behavior). | `string` | `""` |
| `legacy_client_allowlist` | Regex patterns matched against viewer `User-Agent`. Matching requests bypass the token check (DMA check still runs). Keep the list small (<20 entries) — matched linearly per request. | `list(string)` | `[]` |

## Outputs

| Name | Description |
|---|---|
| `validator_function_arn` | CloudFront Function ARN — attach to your distribution's viewer-request event |
| `kvs_arn` / `kvs_id` | CloudFront KeyValueStore (holds signing key + revocation entries + DMA blocklists) |
| `signing_secret_arn` | Secrets Manager secret ARN holding the HMAC signing key |
| `api_endpoint` | Base URL for the token API (`POST /api/token`, `POST /api/revoke`, `GET /api/revoked`) |
| `cloudfront_distribution_id` / `cloudfront_domain_name` | The demo distribution created by this module |
| `web_acl_arn` | WAFv2 Web ACL rate-limiting the token API |
| `rotation_workflow_name` | Step Functions state machine name for signing-key rotation |
| `demo_website_url` | Demo website URL (only meaningful when the demo bucket is populated) |

## Upstream DMA blocklist contract

The `blackout-sync` Lambda expects `<unity_api_base>/v2/broadcasts/dmas` to accept:

- `start_time_gte` and `start_time_lte` — ISO 8601 timestamps bounding the scan window
- `exclude_pixellot=true` — filter out broadcasts sourced from the Pixellot platform (drop this in `source/lambda/blackout_sync/unity_client.js` if not relevant to your setup)
- `per_page` and `page` — pagination

And return an array of `{ key: string, dma_list: number[] | null }` objects. Adapt `source/lambda/blackout_sync/` if your upstream shape differs.

## What this module creates

- 1× CloudFront KeyValueStore (signing key + revocation list + per-broadcast DMA blocklists)
- 1× Secrets Manager secret + version (HMAC signing key)
- 8× Lambda functions (Node token generator, Python variant, Ruby variant, revoker, list-revoked, KVS-cleanup, sync-keys, blackout-sync)
- 1× Step Functions state machine + EventBridge schedule (30-day key rotation)
- 1× EventBridge schedule (hourly KVS revocation cleanup)
- 1× EventBridge schedule (5-minute DMA blocklist reconcile)
- 1× CloudFront distribution (demo/reference) + 1× cache policy + 1× OAC
- 2× CloudFront Functions (CTA validator + `/api/*` path rewriter)
- 1× CloudFront realtime log config + 1× Kinesis stream
- 1× API Gateway REST API with 5 resources (token, token-python, token-ruby, revoke, revoked)
- 1× WAFv2 Web ACL (rate limit on `POST /api/token`)
- 1× S3 demo bucket + demo website files

## Relationship to upstream

This is an independent port maintained by [PlayOn! Sports](https://github.com/playon), not officially blessed by AWS. The CTA-5007-B specification and the runtime Lambda code (`source/**`) are largely unchanged from the upstream reference solution, with additions for the DMA blackout gate and the UA allowlist. The Terraform configuration is original work.

Upstream CDK reference: <https://github.com/aws-solutions-library-samples/secure-media-delivery-at-the-edge-on-aws>

## License

Apache License 2.0. See [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).
