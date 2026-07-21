# terraform-aws-cta-secure-media

Terraform port of the AWS reference solution [**Secure Media Delivery at the Edge on AWS**](https://github.com/aws-solutions-library-samples/secure-media-delivery-at-the-edge-on-aws) — a [CTA-5007-B](https://shop.cta.tech/products/common-access-token-cta-5007-b) (Common Access Token / CBOR Web Token) implementation for CloudFront-signed streaming URLs.

Feature-parity with the upstream CDK stack, plus:

- **WAFv2 rate limit** on `POST /api/token` — mitigates automated token minting
- **CloudFront Function** to strip `/api/` prefix before forwarding to API Gateway — fixes 403s when hitting the token API through CloudFront
- **Hourly KVS cleanup Lambda** — purges expired revocation entries so the KeyValueStore doesn't grow unbounded
- **Hybrid token support** in the validator function — accepts token via `CTA-Common-Access-Token` header, `?CAT=` query param, or URL path segment

## Usage

```hcl
provider "aws" {
  region = "us-east-1"  # WAFv2 CLOUDFRONT scope requires us-east-1
}

module "cta" {
  source = "github.com/playon/terraform-aws-cta-secure-media"

  environment = "prod"
  # Optional: assert caller identity matches the intended account
  account_id  = "123456789012"
}

# Attach the validator to your own distribution
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
| `environment` | Deployment environment name. Used in resource names and Secrets Manager path. | `string` | *(required)* |
| `region` | AWS region. WAFv2 CLOUDFRONT scope requires us-east-1. | `string` | `"us-east-1"` |
| `account_id` | Optional guard: assert caller identity matches. Leave empty to skip. | `string` | `""` |
| `name_prefix` | Prefix for named resources. | `string` | `"cta-secure-media"` |
| `signing_key_length` | HMAC signing key length in bytes. | `number` | `64` |
| `rotation_schedule` | EventBridge schedule for the rotation Step Function. | `string` | `"rate(30 days)"` |
| `secret_recovery_window_days` | Secrets Manager recovery window. 0 = destroy immediately (dev/stage); 7-30 = undo window (prod). | `number` | `0` |
| `token_rate_limit_per_5min` | WAFv2 rate-based rule limit for `POST /api/token` per source IP, per 5-min window. | `number` | `300` |
| `token_authorized_role_arn` | IAM role ARN allowed to invoke `POST /api/token`. When set, the route flips to `AWS_IAM` authorization and only SigV4-signed calls from this role reach the mint. Empty preserves reference behavior (anyone can mint). | `string` | `""` |
| `token_validation_enabled` | Master switch for CTA validation at the edge. `false` = break-glass bypass; the validator forwards every request without inspecting the token. Baked at deploy time — flipping requires a TF apply. | `bool` | `true` |
| `geo_validation_enabled` | Enforce geo restrictions at the edge (`catgeoiso3166` today; zip/DMA extension per VID-3450). Other claim checks (URI/IP/exp/nbf/revocation) run regardless. | `bool` | `true` |

## Outputs

| Name | Description |
|---|---|
| `validator_function_arn` | CloudFront Function ARN — attach to your distribution's viewer-request event |
| `kvs_arn` / `kvs_id` | CloudFront KeyValueStore (holds signing key + revocation list) |
| `signing_secret_arn` | Secrets Manager secret ARN holding the HMAC signing key |
| `api_endpoint` | Base URL for the token API (`POST /api/token`, `POST /api/revoke`, `GET /api/revoked`) |
| `cloudfront_distribution_id` / `cloudfront_domain_name` | The demo distribution created by this module |
| `web_acl_arn` | WAFv2 Web ACL rate-limiting the token API |
| `rotation_workflow_name` | Step Functions state machine name for signing-key rotation |

## What this module creates

- 1× CloudFront KeyValueStore (signing key + revocation list)
- 1× Secrets Manager secret + version (HMAC signing key)
- 7× Lambda functions (Node token generator, Python variant, Ruby variant, revoker, list-revoked, KVS-cleanup, sync-keys)
- 1× Step Functions state machine + EventBridge schedule (30-day key rotation)
- 1× EventBridge schedule (hourly KVS revocation cleanup)
- 1× CloudFront distribution (demo/reference) + 1× cache policy + 1× OAC
- 2× CloudFront Functions (CTA validator + `/api/*` path rewriter)
- 1× CloudFront realtime log config + 1× Kinesis stream
- 1× API Gateway REST API with 5 resources (token, token-python, token-ruby, revoke, revoked)
- 1× WAFv2 Web ACL (rate limit on `POST /api/token`)
- 1× S3 demo bucket + demo website files

## Relationship to upstream

This is an independent port maintained by [PlayOn! Sports](https://github.com/playon), not officially blessed by AWS. The CTA-5007-B specification and the runtime Lambda code (`source/**`) are unchanged from the upstream reference solution. The Terraform configuration is original work.

Upstream CDK reference: <https://github.com/aws-solutions-library-samples/secure-media-delivery-at-the-edge-on-aws>

## License

Apache License 2.0. See [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).
