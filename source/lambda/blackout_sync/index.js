/**
 * VID-3459 — blackout sync-writer.
 *
 * Every 5 min: enumerate broadcasts from unity-api within a bounded
 * scan window [now - SCAN_WINDOW_PAST_HOURS, now + SCAN_WINDOW_FUTURE_HOURS].
 * For each broadcast seen, upsert blackout:{key} if it has DMAs; delete
 * the KVS entry if DMAs were cleared. Broadcasts OUTSIDE the scan
 * window are left alone — their KVS entries persist stale-but-correct-
 * at-time-of-last-write.
 *
 * Both bounds matter — start_time_gte alone (unbounded future) 504's on
 * prod-scale data because NFHS Network schedules months of games in
 * advance. Broadcasts scheduled further out roll into the window as
 * they approach start_time; no preload is needed since viewers can only
 * hit an active stream near start_time and the sync cycles every 5 min.
 *
 * Idempotent, stateless, restart-safe. On any error before writes
 * commit, exits without touching KVS.
 */

const { iterateBroadcasts } = require("./unity_client");
const { reconcile } = require("./kvs_client");

function computeIso(nowMs, offsetHours) {
    return new Date(nowMs + offsetHours * 3600 * 1000).toISOString();
}

async function collectScan(unityBase, gteIso, lteIso, perPage) {
    const desired = new Map();
    const inScan = new Set();
    for await (const b of iterateBroadcasts(unityBase, gteIso, lteIso, perPage)) {
        inScan.add(b.key);
        if (b.dma_list && Array.isArray(b.dma_list) && b.dma_list.length > 0) {
            desired.set(b.key, b.dma_list.join(","));
        }
    }
    return { desired, inScan };
}

exports.handler = async (event) => {
    const start = Date.now();
    const kvsArn = process.env.KVS_ARN;
    const unityBase = process.env.UNITY_API_BASE;
    const perPage = parseInt(process.env.PAGE_SIZE || "1000", 10);
    const pastHours = parseInt(process.env.SCAN_WINDOW_PAST_HOURS || "24", 10);
    const futureHours = parseInt(process.env.SCAN_WINDOW_FUTURE_HOURS || "6", 10);

    if (!kvsArn) throw new Error("KVS_ARN not set");
    if (!unityBase) throw new Error("UNITY_API_BASE not set");

    const gteIso = computeIso(start, -pastHours);
    const lteIso = computeIso(start, futureHours);
    console.log(JSON.stringify({
        msg: "reconcile_start",
        unityBase,
        kvsArn,
        window_hours_past: pastHours,
        window_hours_future: futureHours,
        start_time_gte: gteIso,
        start_time_lte: lteIso,
    }));

    const { desired, inScan } = await collectScan(unityBase, gteIso, lteIso, perPage);
    console.log(JSON.stringify({
        msg: "unity_scan_complete",
        broadcasts_in_scan: inScan.size,
        broadcasts_with_dmas: desired.size,
    }));

    const result = await reconcile(kvsArn, desired, inScan);

    const durationMs = Date.now() - start;
    const summary = {
        msg: "reconcile_complete",
        broadcasts_in_scan: inScan.size,
        broadcasts_with_dmas: desired.size,
        kvs_existing: result.existing,
        kvs_puts: result.puts,
        kvs_deletes: result.deletes,
        kvs_batches: result.batches,
        duration_ms: durationMs,
    };
    console.log(JSON.stringify(summary));
    return summary;
};
