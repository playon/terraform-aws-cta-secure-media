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
| `rotation_enabled` | Opt in only after the coordinated deployment/rotation gate passes. | `bool` | `false` |
| `rotation_overlap_seconds` | Previous-key overlap after promotion, minimum 7200; cache/in-flight margins added automatically. Increase to cover legacy token lifetimes when needed. | `number` | `7200` |
| `rotation_propagation_seconds` | Verified edge propagation allowance before mint promotion, minimum 300. | `number` | `300` |
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

## Key Rotation

Scheduled rotation is **disabled by default**. Do not manually start rotation until the updated validators and mints are deployed together and the deployment checks below pass.

The Step Functions workflow uses one stable execution ARN as its rotation ID:

1. **Prepare:** atomically publish the new raw signing key at `key:default`, the old key at `key:previous` as `{"signingKey":"…","expiresAt":null}`, and ownership state at `key:rotation`. The mint still reads the old Secrets Manager `AWSCURRENT` version. Both keys validate; normal token expiry, revocation, and policy checks still apply.
2. **Wait for propagation:** wait at least 300 seconds, measured from confirmation of the atomic KVS update. This is a configured propagation allowance, **not an acknowledgement from every edge location**. Verify the allowance for each deployment before allowing rotation; increase it if needed.
3. **Promote:** create an idempotent `AWSPENDING` secret version, then move `AWSCURRENT` with the old version as an ownership guard. Confirm the new version before starting the overlap clock.
4. **Finalize overlap:** set the previous-key expiry to promotion confirmation + configured overlap + 60-second mint-cache allowance + 60-second in-flight allowance. Overlap must be at least 7200 seconds (2 hours). At expiry, validators reject old-key signatures even if physical cleanup is delayed.
5. **Cleanup:** after the deadline, confirm the mint still uses the new version, remove the pending label, and atomically delete `key:previous` and remove signing material from active rotation state. A key-free completion tombstone prevents old execution retries from affecting later rotations.

Lambda mints refresh their signing key within **60 seconds** of a fetch starting, including fetch latency. A failed refresh refuses to mint with stale cached material. Supported TTLs are positive integer-valued JSON numbers (for example, `3600.0` or `1e3`) or integer `s/m/h` durations, up to **7200 seconds (2 hours)**; only an omitted TTL defaults to `2h`. Booleans, fractional or non-finite numbers, and durations above that maximum, including `1d`, are rejected.

The combined **propagation + overlap + 60-second mint-cache allowance + in-flight allowance** must not exceed **31,449,600 seconds (364 days)**. Terraform uses the default 60-second in-flight allowance; the Lambda also includes any configured `ROTATION_IN_FLIGHT_SECONDS` override in this bound. This reserves one day within the Standard workflow's one-year execution limit for tasks and retries. A resource precondition compatible with Terraform 1.5 rejects an excessive combined duration at plan time; the Lambda also rejects it before staging. The 2-hour maximum/default token TTL and minimum overlap remain unchanged.

### Failure recovery and deployment gate

- Deploy validators and mints before changing rotation behavior. Keep existing EventBridge rotation rules disabled during rollout; applying these changes sets the schedule disabled unless explicitly opted in. Do not invoke the old `{rotate:true}` Lambda interface.
- **Interim deployment block:** live rotation schedule disables are out-of-band changes against old `main`, not protection encoded in that revision. Do not apply CTA roots sourced from old `main` until the reviewed disabled-default branch is deployed; an old-main apply can re-enable rotation. Keep manual rotation blocked throughout this gate.
- Inventory legacy/custom issuer TTLs. Previously issued tokens longer than 2 hours must expire before the first rotation, or the configured overlap must cover their maximum remaining lifetime. Longer overlap remains configurable for these legacy tokens. All continuing issuers must comply with the supported TTL/cache bounds.
- Verify old- and new-key requests through the actual CloudFront distribution, warm mint refresh, original token expiry, revocation/policy checks, and previous-key expiry/deletion. Local cryptographic tests do not prove AWS edge propagation.
- Consumers attached to an unchanged validator ARN do not need a distribution code/configuration change. Deploy the owning CTA stack, publish the updated LIVE function, and verify through the existing consumer distribution before permitting rotation. If the function ARN changes, update the consumer association only after the replacement validator and mint are ready.
- Within the 14-day Step Functions redrive window, redrive an eligible failed execution with its **same execution ARN**. After that window, use the direct recovery procedure below. Do not start a second rotation or overwrite KVS/secret state. CAS ownership rejects competing executions. Initial deployment sync skips an active rotation rather than resetting it.
- Before confirmed promotion, the previous-key deadline stays `null`, so a partial failure cannot expire the key still used by the mint. Resume the execution to finish promotion/finalization. After finalization, an interrupted cleanup does not extend signature acceptance; resume cleanup to physically delete the retained key.
- Rotation inputs, outputs, and logs contain no signing material. Do not enable SDK wire logging or print KVS/secret contents during troubleshooting.

Terraform controls: `rotation_enabled = false`, `rotation_overlap_seconds = 7200` (minimum 7200), and `rotation_propagation_seconds = 300` by default. The monthly cadence applies only after opt-in.

Terraform removes full-line JavaScript comments from the uploaded validator, retaining readable source while leaving room for configured allowlists within CloudFront's 10 KiB limit.

### Direct recovery after the redrive window

Keep all rotation schedules disabled throughout recovery. First use Step Functions `DescribeExecution` on the **original execution ARN** and confirm its status is terminal (`FAILED`, `TIMED_OUT`, or `ABORTED`), not `RUNNING`. Never restart the workflow with a new execution ARN or change the stored ownership ID.

Invoke the existing SyncKeysToKvs Lambda directly with `InvocationType: RequestResponse`. Each payload must be `{"action":"<action>","executionId":"<original execution ARN>"}`. For **every** invocation, inspect the Invoke response metadata: require `StatusCode: 200` and an absent `FunctionError` before using its returned JSON payload or continuing. HTTP success alone does not establish function success. On an error, stop and diagnose without printing secret/KVS values; retry only the same action and execution ID.

1. Invoke `prepare`; retain its key-free `propagationReadyTimestamp`.
2. Wait until that absolute UTC timestamp has passed. Do not substitute a new relative timer or shorten the wait because the execution is old.
3. Invoke `promote`, then invoke `finalize`; retain the latter's key-free `cleanupTimestamp`.
4. Wait until `cleanupTimestamp` has passed, then invoke `cleanup` and require the key-free result's `phase` to be `complete`.

Repeated actions are idempotent for this original execution ID: already-completed phases retain their recorded deadlines, and completion tombstones prevent a replay from starting another rotation. If recovery is interrupted, repeat this sequence with the same ARN. Lambda action results contain only execution ID, phase, and timestamps, never signing keys. Record only those fields and invocation status; do not enable SDK wire logging or dump Secrets Manager/KVS contents. No new workflow execution, manual KVS edit, or manual secret-stage mutation is part of this procedure. These instructions do not authorize live recovery or rotation before the deployment gate passes.

### Legacy previous-key migration

Only when `key:rotation` is absent, a nonempty ASCII-alphanumeric `key:previous` is recognized as the legacy raw-key format, covering both initial generated passwords and later hexadecimal rotation keys, including configured key lengths. Raw previous records were not consumed by the pre-change validator; migration does not grant them a new acceptance window. Initial deployment sync atomically initializes a missing/empty `key:default` from the current secret key and deletes the raw previous key, or keeps an already-matching default key and atomically deletes the raw previous key. If a nonempty default key differs from the mint's current signing key, initialization fails closed without changing either key. `prepare` likewise requires mint/edge agreement, then atomically replaces the legacy raw previous key with the structured previous record for the currently minted key while staging the new default. Apply the legacy-token lifetime deployment gate before this migration. An existing rotation state protects ownership and retained keys; a structured previous record or unknown/malformed previous value is never silently discarded. Conflicts fail closed and require investigation, not manual deletion of ownership or retained-key state.



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
- 1× Step Functions state machine + EventBridge schedule (30-day cadence; rotation disabled by default)
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
