/**
 * List Revoked Sessions — reads revoked:* keys from CloudFront KeyValueStore
 * Returns JSON array of revoked sessions for the dashboard.
 */

const { CloudFrontKeyValueStoreClient, ListKeysCommand } = require('@aws-sdk/client-cloudfront-keyvaluestore');
require('@aws-sdk/signature-v4a');

const kvsClient = new CloudFrontKeyValueStoreClient({});
const KVS_ARN = process.env.KVS_ARN;

exports.handler = async () => {
    const headers = { 'Access-Control-Allow-Origin': '*' };
    try {
        const resp = await kvsClient.send(new ListKeysCommand({ KvsARN: KVS_ARN }));
        const revoked = (resp.Items || [])
            .filter(item => item.Key.startsWith('revoked:'))
            .map(item => {
                let meta = {};
                try { meta = JSON.parse(item.Value); } catch {}
                return {
                    sessionId: item.Key.replace('revoked:', ''),
                    reason: meta.reason || 'unknown',
                    revokedAt: meta.revokedAt || null,
                };
            })
            .sort((a, b) => (b.revokedAt || 0) - (a.revokedAt || 0));

        return { statusCode: 200, headers, body: JSON.stringify({ revoked, count: revoked.length }) };
    } catch (err) {
        return { statusCode: 500, headers, body: JSON.stringify({ error: err.message }) };
    }
};
