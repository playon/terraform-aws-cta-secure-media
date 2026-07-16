/**
 * KVS Cleanup — purges expired revocation entries from CloudFront KeyValueStore.
 * Runs on a schedule via EventBridge. Removes revoked:* entries older than TTL.
 */

const { CloudFrontKeyValueStoreClient, ListKeysCommand, DeleteKeyCommand, DescribeKeyValueStoreCommand } = require('@aws-sdk/client-cloudfront-keyvaluestore');
require('@aws-sdk/signature-v4a');

const kvsClient = new CloudFrontKeyValueStoreClient({});
const KVS_ARN = process.env.KVS_ARN;
const TTL_HOURS = parseInt(process.env.TTL_HOURS || '24');

exports.handler = async () => {
    const cutoff = Math.floor(Date.now() / 1000) - (TTL_HOURS * 3600);
    const resp = await kvsClient.send(new ListKeysCommand({ KvsARN: KVS_ARN }));
    const expired = (resp.Items || []).filter(item => {
        if (!item.Key.startsWith('revoked:')) return false;
        try {
            const meta = JSON.parse(item.Value);
            return meta.revokedAt && meta.revokedAt < cutoff;
        } catch { return false; }
    });

    let deleted = 0;
    for (const item of expired) {
        try {
            const etag = (await kvsClient.send(new DescribeKeyValueStoreCommand({ KvsARN: KVS_ARN }))).ETag;
            await kvsClient.send(new DeleteKeyCommand({ KvsARN: KVS_ARN, Key: item.Key, IfMatch: etag }));
            deleted++;
        } catch (err) {
            console.error(`Failed to delete ${item.Key}: ${err.message}`);
        }
    }

    return { expired: expired.length, deleted, cutoffAge: `${TTL_HOURS}h` };
};
