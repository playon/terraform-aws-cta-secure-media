/**
 * Batched CloudFront KVS reconciliation.
 *
 * Uses UpdateKeysCommand (batch put/delete in one call) instead of
 * per-key PutKey — one ETag fetch + one API call per batch of ~50 ops.
 * Batch size capped conservatively at 50 to stay under AWS's per-call
 * limit.
 *
 * All operations scoped to the `blackout:` key prefix. Other keys in
 * the KVS (key:default, revoked:*) are untouched.
 *
 * Deletion scope: only broadcasts SEEN in the current scan window can
 * have their KVS entries deleted. Broadcasts outside the window
 * (aged-out historical archives) are left untouched — their entries
 * persist. This matches the "future VODs only" scoping decision on
 * VID-3459.
 */

require("@aws-sdk/signature-v4-crt");

const {
    CloudFrontKeyValueStoreClient,
    DescribeKeyValueStoreCommand,
    ListKeysCommand,
    UpdateKeysCommand,
} = require("@aws-sdk/client-cloudfront-keyvaluestore");

const KEY_PREFIX = "blackout:";
const BATCH_SIZE = 50;

const client = new CloudFrontKeyValueStoreClient({});

async function getEtag(kvsArn) {
    const resp = await client.send(new DescribeKeyValueStoreCommand({ KvsARN: kvsArn }));
    return resp.ETag;
}

async function listBlackoutKeys(kvsArn) {
    const keys = new Set();
    let nextToken;
    do {
        const resp = await client.send(new ListKeysCommand({ KvsARN: kvsArn, NextToken: nextToken }));
        for (const item of resp.Items || []) {
            if (item.Key && item.Key.startsWith(KEY_PREFIX)) {
                keys.add(item.Key);
            }
        }
        nextToken = resp.NextToken;
    } while (nextToken);
    return keys;
}

/**
 * Compute puts + deletes given:
 *   existingKeys — full "blackout:*" set currently in KVS
 *   desired      — Map<broadcastKey, dmaListCsv> — broadcasts in window WITH DMAs
 *   inScan       — Set<broadcastKey> — every broadcast seen in the current scan window
 *
 * Deletion rule: only delete existing KVS entries whose broadcast is
 * IN the scan window (inScan) but NOT in desired (i.e. DMAs cleared
 * since last write). Entries outside the scan window are preserved.
 */
function diff(existingKeys, desired, inScan) {
    const puts = [];
    const deletes = [];
    for (const [broadcastKey, value] of desired) {
        puts.push({ Key: KEY_PREFIX + broadcastKey, Value: value });
    }
    for (const existing of existingKeys) {
        if (!existing.startsWith(KEY_PREFIX)) continue;
        const broadcastKey = existing.slice(KEY_PREFIX.length);
        if (inScan.has(broadcastKey) && !desired.has(broadcastKey)) {
            deletes.push({ Key: existing });
        }
    }
    return { puts, deletes };
}

function chunk(arr, size) {
    const out = [];
    for (let i = 0; i < arr.length; i += size) {
        out.push(arr.slice(i, i + size));
    }
    return out;
}

async function reconcile(kvsArn, desired, inScan) {
    const existingKeys = await listBlackoutKeys(kvsArn);
    const { puts, deletes } = diff(existingKeys, desired, inScan);

    if (puts.length === 0 && deletes.length === 0) {
        return { puts: 0, deletes: 0, batches: 0, existing: existingKeys.size };
    }

    // AWS caps UpdateKeys at 50 ops per call — batch puts + deletes together.
    const ops = [
        ...puts.map(p => ({ type: "put", op: p })),
        ...deletes.map(d => ({ type: "delete", op: d })),
    ];
    const batches = chunk(ops, BATCH_SIZE);

    for (const batch of batches) {
        const etag = await getEtag(kvsArn);
        await client.send(new UpdateKeysCommand({
            KvsARN: kvsArn,
            IfMatch: etag,
            Puts: batch.filter(o => o.type === "put").map(o => o.op),
            Deletes: batch.filter(o => o.type === "delete").map(o => o.op),
        }));
    }

    return { puts: puts.length, deletes: deletes.length, batches: batches.length, existing: existingKeys.size };
}

module.exports = { reconcile, listBlackoutKeys, diff, KEY_PREFIX };
