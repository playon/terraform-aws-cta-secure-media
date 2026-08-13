.PHONY: lambda-deps lambda-deps-node lambda-deps-blackout-sync test test-node test-blackout-sync fmt validate

# Install runtime dependencies for every Lambda package before
# `terraform apply`. archive_file zips each source directory as-is;
# without these installs the resulting zip is missing node_modules and
# the function 500s on cold start with "Cannot find module ...".
lambda-deps: lambda-deps-node lambda-deps-blackout-sync

lambda-deps-node:
	npm install --omit=dev --prefix source/lambda

lambda-deps-blackout-sync:
	npm install --omit=dev --prefix source/lambda/blackout_sync

test: test-node test-blackout-sync

test-node:
	cd source/lambda && npx jest

test-blackout-sync:
	cd source/lambda/blackout_sync && npm test

fmt:
	terraform fmt -recursive

validate:
	terraform validate
	cd examples/basic && terraform init -backend=false -input=false && terraform validate
