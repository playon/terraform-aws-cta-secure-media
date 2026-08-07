/**
 * Read-only client for unity-api's /v2/broadcasts/dmas endpoint.
 *
 * Slim endpoint returning {key, dma_list} per broadcast in the scan
 * window. dma_list is the effective value (Broadcast#dma_list resolves
 * broadcast override → publisher fallback); absent/empty means no
 * restriction.
 *
 * exclude_pixellot=true filters out Pixellot-created broadcasts on the
 * server side — by convention they don't carry per-broadcast DMA
 * overrides, and dropping them cuts scan set by an order of magnitude.
 *
 * Read endpoint is anonymous — no credential threaded through.
 *
 * Scan window must be bounded on both sides — the endpoint returns 400
 * on single-bound requests. NFHS Network schedules months of games in
 * advance so an unbounded side would timeout.
 */

const DEFAULT_PAGE_SIZE = 1000;

async function fetchPage(baseUrl, page, perPage, startTimeGteIso, startTimeLteIso) {
    const url = new URL(`${baseUrl}/v2/broadcasts/dmas`);
    url.searchParams.set("page", String(page));
    url.searchParams.set("per_page", String(perPage));
    url.searchParams.set("exclude_pixellot", "true");
    if (startTimeGteIso) {
        url.searchParams.set("start_time_gte", startTimeGteIso);
    }
    if (startTimeLteIso) {
        url.searchParams.set("start_time_lte", startTimeLteIso);
    }
    const res = await fetch(url.toString());
    if (!res.ok) {
        throw new Error(`unity-api ${res.status} on ${url}`);
    }
    return res.json();
}

/**
 * Walk /v2/broadcasts/dmas within the scan window and yield every
 * broadcast seen (regardless of dma_list). Callers decide whether to
 * consider each broadcast for KVS write based on its dma_list.
 *
 * Yields: { key, dma_list } — dma_list may be null/empty.
 */
async function* iterateBroadcasts(baseUrl, startTimeGteIso, startTimeLteIso, perPage = DEFAULT_PAGE_SIZE) {
    let page = 1;
    while (true) {
        const body = await fetchPage(baseUrl, page, perPage, startTimeGteIso, startTimeLteIso);
        const broadcasts = Array.isArray(body) ? body : (body.broadcasts || body.data || []);
        if (broadcasts.length === 0) return;
        for (const b of broadcasts) {
            yield { key: b.key, dma_list: b.dma_list };
        }
        if (broadcasts.length < perPage) return;
        page += 1;
    }
}

module.exports = { iterateBroadcasts, fetchPage };
