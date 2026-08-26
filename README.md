# terraform-aws-cta-secure-media

Terraform port of the AWS reference solution [**Secure Media Delivery at the Edge on AWS**](https://github.com/aws-solutions-library-samples/secure-media-delivery-at-the-edge-on-aws) — a [CTA-5007-B](https://shop.cta.tech/products/common-access-token-cta-5007-b) (Common Access Token / CBOR Web Token) implementation for CloudFront-signed streaming URLs.

Feature-parity with the upstream CDK stack, plus:

- **Two edge gates in one CloudFront Function.** Token validation and DMA blackout enforcement run inline on every viewer request, with independent `off` / `log` / `enforce` toggles. The token check enforces CTA-5007-B's `EXP`, `NBF`, `CATU` (URI prefix), `CATNIP` (IP allowlist), and `CATGEOISO3166` (country allowlist) claims. Revocation lookup on `CTI` returns `410 Gone` distinct from generic `401`.
- **DMA blackout pipeline.** A dedicated `blackout-sync` Lambda reconciles per-broadcast blocklists from an upstream service into the CloudFront KeyValueStore on a 5-minute schedule. The validator joins the viewer's `CloudFront-Viewer-Metro-Code` against the blocklist and returns `451 Unavailable For Legal Reasons` on a match.
- **User-Agent allowlist bridge.** Regex patterns matched against the viewer UA bypass token validation entirely — for legacy clients that can't ship CTA minting before enforcement lands. Sunsets when legacy clients age out.
- **APIGW `/token` lockdown.** Optional `AWS_IAM` authorization + resource policy pinning `POST /api/token` to a single IAM role (typically your server-side token-minting Lambda). Anonymous callers hit 403 at APIGW.
- **WAFv2 rate limit** on `POST /api/token` — defense-in-depth against automated minting even if the IAM lockdown is off.
- **CloudFront Function** to strip `/api/` prefix before forwarding to API Gateway — fixes 403s when hitting the token API through CloudFront.
- **Hourly KVS cleanup Lambda** — purges expired revocation entries so the KeyValueStore doesn't grow unbounded.
- **Hybrid token transport.** The validator accepts the token via `CTA-Common-Access-Token` header, `?CAT=` query param, or URL path segment. (Note: path-segment transport requires your content behavior to be the default cache behavior; otherwise CloudFront routes on the un-stripped URI and misses your ordered pattern.)

## Usage

The module must be planned and applied against `us-east-1` — the WAFv2 Web ACL is `CLOUDFRONT`-scoped, which AWS only serves from us-east-1. The module doesn't accept a `region` input; point your provider there:

```hcl
provider "aws" {
  region = "us-east-1"
}

module "cta" {
  source = "github.com/playon/terraform-aws-cta-secure-media"

  environment    = "prod"
  account_id     = "123456789012"                     # optional caller-identity guard
  blackout_api_base_url = "https://api.example.com"           # upstream service that supplies DMA blocklists

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

Before the first `terraform apply`, install the Lambda runtime deps:

```bash
make lambda-deps
```

This installs `source/lambda/node_modules` and `source/lambda/blackout_sync/node_modules`. `archive_file` zips each source directory as-is, so without this step the deployed Lambdas 500 on cold start with `Cannot find module ...`.

## Consumer cache policy

The validator reads two CloudFront-populated viewer headers:

- `CloudFront-Viewer-Country` — checked against the token's `CATGEOISO3166` (claim 316) country allowlist.
- `CloudFront-Viewer-Metro-Code` — checked against the per-broadcast DMA blocklist in KVS.

**CloudFront only populates viewer-* headers when they're on the attached cache policy's whitelist.** The cache policy this module ships (`aws_cloudfront_cache_policy.validator_headers`) whitelists both, but when you attach `validator_function_arn` to your own distribution's cache behavior, that behavior's cache policy also needs to forward them — the managed `CachingOptimized` / `CachingDisabled` policies forward *no* headers and will silently break both gates. Missing `Country` returns `401 geo_restricted` on every token carrying a 316 claim; missing `Metro-Code` fail-opens the DMA gate (auditable via the `blackout_dma_missing_metro` CloudWatch log line).

### Cache-key cost of the visibility requirement

The two viewer-* headers this module needs don't just have to be forwarded to the origin — they have to be in the *cache key* of the behavior the validator is attached to, or the function can't see them (see above). That makes the cache key vary by geography, and the cost can be substantial on high-volume paths:

- **Cardinality.** Adding `CloudFront-Viewer-Metro-Code` to a US-served behavior's cache key multiplies cache slots by ~210 (one per Nielsen DMA) *per URI*. Adding `CloudFront-Viewer-Country` adds a country dimension on top. Fine on low-request paths (master playlist, sparse assets); painful on high-request ones (per-viewer manifest polling), where every cold slot is an origin miss.
- **Don't couple query-string forwarding with the headers list via legacy `forwarded_values`.** In legacy mode the cache key is the cross-product of forwarded headers and `query_string=true`; on manifest paths with a handful of query params, hit ratio drops from the mid-90s % to single digits under real load. Attach a modern cache/origin-request policy pair (`cache_policy_id` + `origin_request_policy_id`) instead — cache-key composition and origin forwarding become independent, and only the fields you name land in the key.
- **Enable Origin Shield on the origin behind this behavior.** Shield is a second cache layer keyed the same way as the edge, so it collapses `variants × POPs` edge misses into `variants` origin fetches — restoring most of what the DMA multiplier costs. On a Lambda or API Gateway origin, running without shield is a *concurrency* exposure at peak, not just a cost delta: worst-case miss fan-out becomes `variants × active-POP count` against the origin, all at once.
- **Disable shield with `origin_shield = null`, never `{ enabled = false, ... }`.** CloudFront doesn't persist a region when shield is off, so a disabled block with `origin_shield_region` set produces a perpetual plan diff on every subsequent `terraform plan`.

## Inputs

| Name | Description | Type | Default |
|---|---|---|---|
| `environment` | Deployment environment slug (e.g., `staging`, `prod`). Used in resource names and the APIGW `stage_name`. | `string` | *(required)* |
| `account_id` | Optional guard: assert caller identity matches. Empty skips the check. | `string` | `""` |
| `name_prefix` | Prefix for named resources. | `string` | `"cta-secure-media"` |
| `signing_key_length` | HMAC signing key length in bytes. | `number` | `64` |
| `secret_recovery_window_days` | Secrets Manager recovery window (in days) for the signing-key secret. `0` = immediate destroy (fine for throwaway envs); `7-30` keeps the secret recoverable for that window after `terraform destroy`. | `number` | `30` |
| `rotation_schedule` | EventBridge schedule for the rotation Step Function. | `string` | `"rate(30 days)"` |
| `demo_origin_domain` | Default-behavior origin. Override to point at a real content origin. | `string` | `"cdn.mediaplaypen.com"` |
| `demo_bucket_force_destroy` | When true, `terraform destroy` empties + removes the demo S3 bucket even if it still holds objects. Set true for throwaway envs; false in prod so an accidental destroy fails loudly. | `bool` | `false` |
| `token_enforcement_mode` | Token gate: `off` skips check entirely; `log` computes but forwards + emits log line; `enforce` rejects with 401. Recommended rollout: `off` → `log` → `enforce`. | `string` | `"enforce"` |
| `dma_enforcement_mode` | DMA gate: same shape as `token_enforcement_mode`. `enforce` returns `451` with body `blackout_dma`. The blackout_sync Lambda + 5-min schedule are only created when this is `log` or `enforce`. | `string` | `"off"` |
| `blackout_api_base_url` | Base URL of the upstream service supplying per-broadcast DMA blocklists. Read from `<base>/v2/broadcasts/dmas`. Required when `dma_enforcement_mode` is `log` or `enforce`; ignored when `off`. | `string` | `""` |
| `broadcast_uri_prefix` | URI prefix under which broadcasts are served (e.g., `/broadcast/`). Used by the validator to extract the broadcast id from the request URI for DMA blocklist lookup. Must begin and end with a slash. | `string` | `"/broadcast/"` |
| `drm_api_lambda_role_arn` | When non-empty, flips `POST /api/token` to `AWS_IAM` and pins invoke to this role via a resource policy. Empty = anonymous mint (reference-solution behavior). | `string` | `""` |
| `token_rate_limit_per_5min` | WAFv2 rate-based limit (per source IP, 5-minute sliding window) on `POST /api/token`. Tune to your minter cadence — the default is well above one-mint-per-session traffic but tight enough to catch scraping. | `number` | `300` |
| `legacy_client_allowlist` | Regex patterns matched against viewer `User-Agent`. Matching requests bypass the token check (DMA check still runs). Keep the list small (<20 entries) — matched linearly per request. | `list(string)` | `[]` |
| `geo_restriction_type` | CloudFront distribution geo restriction: `none` / `whitelist` / `blacklist`. Distribution-level control (whole country blocked regardless of token); pair with `geo_restriction_locations` when non-`none`. | `string` | `"none"` |
| `geo_restriction_locations` | ISO 3166-1 alpha-2 country codes for the geo restriction. Ignored when `geo_restriction_type = "none"`. | `list(string)` | `[]` |

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

The `blackout-sync` Lambda expects `<blackout_api_base_url>/v2/broadcasts/dmas` to accept:

- `start_time_gte` and `start_time_lte` — ISO 8601 timestamps bounding the scan window
- `exclude_pixellot=true` — filter out broadcasts sourced from the Pixellot platform (drop this in `source/lambda/blackout_sync/blackout_client.js` if not relevant to your setup)
- `per_page` and `page` — pagination

And return an array of `{ key: string, dma_list: number[] | null }` objects. Adapt `source/lambda/blackout_sync/` if your upstream shape differs.

## What this module creates

- 1× CloudFront KeyValueStore (signing key + revocation list + per-broadcast DMA blocklists)
- 1× Secrets Manager secret + version (HMAC signing key)
- 6× Lambda functions (Node token generator, revoker, list-revoked, KVS-cleanup, sync-keys, blackout-sync)
- 1× Step Functions state machine + EventBridge schedule (30-day key rotation)
- 1× EventBridge schedule (hourly KVS revocation cleanup)
- 1× EventBridge schedule (5-minute DMA blocklist reconcile)
- 1× CloudFront distribution (demo/reference) + 1× cache policy + 1× OAC
- 2× CloudFront Functions (CTA validator + `/api/*` path rewriter)
- 1× CloudFront realtime log config + 1× Kinesis stream
- 1× API Gateway REST API with 3 resources (token, revoke, revoked)
- 1× WAFv2 Web ACL (rate limit on `POST /api/token`)
- 1× S3 demo bucket + demo website files

## Migration notes

- **`CATGEOISO3166` (claim 316) is enforced whenever a token carries it.** There is no toggle to opt out — the check runs inside `validateClaims` for any token whose payload includes the claim. If you were previously running with `geo_validation_enabled = false` and minters were still emitting the claim, viewers whose `CloudFront-Viewer-Country` isn't in the token's country list will now get `401 geo_restricted`. Either stop emitting claim 316 at mint time, or verify your minters produce the correct country set.
- The `blackout_sync` stack (Lambda, IAM, 5-min EventBridge schedule) is only created when `dma_enforcement_mode` is `log` or `enforce`. When on, `blackout_api_base_url` is required.
- Run `make lambda-deps` before the first `terraform apply` — the Lambda zips depend on it.

## Relationship to upstream

This is an independent port maintained by [PlayOn! Sports](https://github.com/playon), not officially blessed by AWS. The CTA-5007-B specification and the runtime Lambda code (`source/**`) are largely unchanged from the upstream reference solution, with additions for the DMA blackout gate and the UA allowlist, and with the Python and Ruby token-minter ports removed — this fork only ships the Node minter. The Terraform configuration is original work.

Upstream CDK reference: <https://github.com/aws-solutions-library-samples/secure-media-delivery-at-the-edge-on-aws>

## License

Apache License 2.0. See [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).
