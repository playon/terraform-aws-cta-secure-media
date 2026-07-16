/**
 * Sync signing key from Secrets Manager to CloudFront KeyValueStore.
 * Used as:
 *   1. Custom resource on deploy (initial key sync)
 *   2. Step Functions task during key rotation
 */

// Load SigV4a CRT signer — required for CloudFront KVS API
require("@aws-sdk/signature-v4-crt");

const { SecretsManagerClient, GetSecretValueCommand, PutSecretValueCommand } = require("@aws-sdk/client-secrets-manager");
const { CloudFrontKeyValueStoreClient, DescribeKeyValueStoreCommand, PutKeyCommand } = require("@aws-sdk/client-cloudfront-keyvaluestore");
const crypto = require("crypto");

const sm = new SecretsManagerClient({});
const kvs = new CloudFrontKeyValueStoreClient({});

async function getKvsEtag(kvsArn) {
    const resp = await kvs.send(new DescribeKeyValueStoreCommand({ KvsARN: kvsArn }));
    return resp.ETag;
}

async function putKvsKey(kvsArn, key, value) {
    const etag = await getKvsEtag(kvsArn);
    await kvs.send(new PutKeyCommand({ KvsARN: kvsArn, Key: key, Value: value, IfMatch: etag }));
}

async function getSecret(secretId) {
    const resp = await sm.send(new GetSecretValueCommand({ SecretId: secretId }));
    return JSON.parse(resp.SecretString);
}

async function putSecret(secretId, value) {
    await sm.send(new PutSecretValueCommand({ SecretId: secretId, SecretString: JSON.stringify(value) }));
}

exports.handler = async (event) => {
    console.log("Event:", JSON.stringify(event));

    const secretName = process.env.SECRET_NAME;
    const kvsArn = process.env.KVS_ARN;

    // Custom resource handling
    if (event.RequestType) {
        if (event.RequestType === "Delete") {
            return { PhysicalResourceId: event.PhysicalResourceId || "key-sync", Status: "SUCCESS" };
        }
        // Create or Update — sync current key to KVS
        const secret = await getSecret(secretName);
        await putKvsKey(kvsArn, "key:default", secret.signingKey);
        console.log("Initial key synced to KVS");
        return { PhysicalResourceId: "key-sync", Status: "SUCCESS" };
    }

    // Step Functions rotation invocation
    if (event.rotate) {
        // 1. Get current key (will become previous)
        const currentSecret = await getSecret(secretName);
        const previousKey = currentSecret.signingKey;

        // 2. Generate new signing key
        const newKey = crypto.randomBytes(32).toString("hex");

        // 3. Update Secrets Manager with new key
        await putSecret(secretName, { algorithm: "HMAC-SHA256", signingKey: newKey });
        console.log("New signing key stored in Secrets Manager");

        // 4. Write new key to KVS as default
        await putKvsKey(kvsArn, "key:default", newKey);
        console.log("New key synced to KVS as key:default");

        // 5. Keep previous key in KVS for graceful transition
        await putKvsKey(kvsArn, "key:previous", previousKey);
        console.log("Previous key stored in KVS as key:previous");

        return { status: "rotated" };
    }

    throw new Error("Unknown event type");
};
