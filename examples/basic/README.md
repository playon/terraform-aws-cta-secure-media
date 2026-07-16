# Basic example

Deploys the module against your default AWS credentials with sensible defaults.

```bash
cd examples/basic
terraform init
terraform apply
```

After apply, the outputs give you everything you need to integrate:

- `validator_function_arn` — attach to your own distribution's `viewer-request` event
- `api_endpoint` — where clients POST to mint (`/api/token`) and revoke (`/api/revoke`)
- `kvs_arn` — CloudFront KeyValueStore holding the signing key + revocation list

## Attaching the validator to your distribution

```hcl
resource "aws_cloudfront_distribution" "content" {
  # ... your existing distribution config ...

  default_cache_behavior {
    # ... your existing cache config ...

    function_association {
      event_type   = "viewer-request"
      function_arn = module.cta.validator_function_arn
    }
  }
}
```

## Teardown

```bash
terraform destroy
```

Note: the KVS is destroyed immediately. If you're running this against
a live token flow, existing tokens become invalid and clients must re-mint.
