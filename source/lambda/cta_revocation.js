/**
 * CTA Token Revocation Handler
 * Manages token revocation via CloudFront KeyValueStore
 */

const { CloudFrontKeyValueStoreClient, PutKeyCommand, DescribeKeyValueStoreCommand } = require("@aws-sdk/client-cloudfront-keyvaluestore");
require("@aws-sdk/signature-v4a");

const kvsClient = new CloudFrontKeyValueStoreClient({});

async function getEtag(kvsArn) {
    const resp = await kvsClient.send(new DescribeKeyValueStoreCommand({ KvsARN: kvsArn }));
    return resp.ETag;
}

exports.handler = async (event) => {
    const headers = { "Access-Control-Allow-Origin": "*" };
    try {
        const { tokenId, reason = "manual" } = JSON.parse(event.body);

        if (!tokenId) {
            return { statusCode: 400, headers, body: JSON.stringify({ error: "Missing tokenId" }) };
        }

        const kvsArn = process.env.KVS_ARN;
        const etag = await getEtag(kvsArn);

        await kvsClient.send(new PutKeyCommand({
            KvsARN: kvsArn,
            Key: `revoked:${tokenId}`,
            Value: JSON.stringify({ reason, revokedAt: Math.floor(Date.now() / 1000) }),
            IfMatch: etag
        }));

        return {
            statusCode: 200, headers,
            body: JSON.stringify({ success: true, tokenId, reason, message: "Token revoked" })
        };
    } catch (error) {
        return { statusCode: 500, headers, body: JSON.stringify({ error: error.message }) };
    }
};
