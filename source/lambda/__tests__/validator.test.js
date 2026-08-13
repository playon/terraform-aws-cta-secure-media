// Tests for the CTA validator CloudFront Function.
//
// The validator ships as a Terraform .js.tftpl template that's rendered
// at `terraform apply` time and uploaded as a CloudFront Function. To
// test it in Node we (a) render the template with fixture values, (b)
// stub the `cloudfront` ES-module import, and (c) load the resulting
// JS in a `vm` context so top-level state (compiled RegExp array, etc.)
// initializes per test.
//
// Coverage: legacy-client UA allowlist, token_enforcement_mode dispatch,
// DMA blackout gate, and the CATGEOISO3166 (claim 316) country check.

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const TEMPLATE_PATH = path.join(__dirname, '..', 'cta_token_validator.js.tftpl');

function render(overrides) {
  const defaults = {
    token_enforcement_mode: 'enforce',
    dma_enforcement_mode: 'off',
    legacy_client_allowlist_json: '[]',
    broadcast_uri_prefix_json: JSON.stringify('/broadcast/'),
  };
  const values = Object.assign({}, defaults, overrides || {});
  let src = fs.readFileSync(TEMPLATE_PATH, 'utf8');
  for (const key of Object.keys(values)) {
    // ${var} → literal value (raw substitution matches templatefile()).
    src = src.split('${' + key + '}').join(values[key]);
  }
  return src;
}

// Load the rendered validator into a fresh vm context and return its
// handler. The `cf` import is replaced with a stub because CloudFront
// Functions ESM syntax isn't available in Node's CommonJS jest runner.
function loadValidator(rendered, kvsMap, opts) {
  const validateToken = (opts && opts.validateToken) || (() => { throw new Error('cwt_stub_called'); });
  const logs = [];
  const kvs = {
    get: async (key) => {
      if (!(key in kvsMap)) throw new Error('KeyNotFound');
      return kvsMap[key];
    },
  };
  const cfMock = {
    kvs: () => kvs,
    cwt: { validateToken },
  };

  // Strip the ESM `import cf from 'cloudfront'` — inject `var cf` before eval.
  const stripped = rendered.replace(/^import cf from 'cloudfront';?/m, '');
  const wrapped = `
    var cf = __cfMock;
    var Buffer = { from: (s) => s };
    ${stripped}
    module.exports = { handler };
  `;

  const module = { exports: {} };
  const context = vm.createContext({
    __cfMock: cfMock,
    module,
    console: { log: (...args) => logs.push(args.join(' ')) },
    Math,
    Date,
    RegExp,
    String,
    Error,
    setTimeout,
    clearTimeout,
  });
  vm.runInContext(wrapped, context);
  return { handler: module.exports.handler, logs };
}

function makeRequest({ uri = '/broadcast/abc/720p30/live.m3u8', userAgent = 'Mozilla/5.0', method = 'GET', pathToken, metroCode, country } = {}) {
  const headers = {};
  if (userAgent !== null) {
    headers['user-agent'] = { value: userAgent };
  }
  if (metroCode !== undefined) {
    headers['cloudfront-viewer-metro-code'] = { value: String(metroCode) };
  }
  if (country !== undefined) {
    headers['cloudfront-viewer-country'] = { value: country };
  }
  const finalUri = pathToken ? `/${pathToken}${uri}` : uri;
  return {
    request: {
      uri: finalUri,
      method,
      headers,
      querystring: {},
    },
    viewer: { ip: '127.0.0.1' },
  };
}

describe('CTA validator — UA allowlist', () => {
  test('empty allowlist forwards through to token validation (missing_token → 401 in enforce)', async () => {
    const { handler } = loadValidator(render({}), { 'key:default': 'test-signing-key' });
    const res = await handler(makeRequest());
    expect(res.statusCode).toBe(401);
    expect(res.body).toBe('missing_token');
  });

  test('allowlisted UA bypasses token validation and forwards request', async () => {
    const { handler } = loadValidator(
      render({ legacy_client_allowlist_json: '["^Roku/DVP-", "^ExampleApp/"]' }),
      {}
    );
    const rokuRes = await handler(makeRequest({ userAgent: 'Roku/DVP-15.2 (15.2.4.3450-H2)' }));
    expect(rokuRes.statusCode).toBeUndefined();
    expect(rokuRes.uri).toBe('/broadcast/abc/720p30/live.m3u8');

    const legacyAndroid = await handler(makeRequest({ userAgent: 'ExampleApp/1.11.7 (Linux;Android 9) AndroidXMedia3/1.7.1' }));
    expect(legacyAndroid.statusCode).toBeUndefined();
  });

  test('non-allowlisted UA still enforces token check', async () => {
    const { handler } = loadValidator(
      render({ legacy_client_allowlist_json: '["^Roku/DVP-"]' }),
      { 'key:default': 'test-signing-key' }
    );
    const res = await handler(makeRequest({ userAgent: 'Mozilla/5.0 (Windows NT 10.0)' }));
    expect(res.statusCode).toBe(401);
    expect(res.body).toBe('missing_token');
  });

  test('missing User-Agent header is not an allowlist match', async () => {
    const { handler } = loadValidator(
      render({ legacy_client_allowlist_json: '["^.*"]' }),  // matches everything
      { 'key:default': 'test-signing-key' }
    );
    const res = await handler(makeRequest({ userAgent: null }));
    expect(res.statusCode).toBe(401);
    expect(res.body).toBe('missing_token');
  });

  test('regex escaping: pattern with . as literal does not match arbitrary chars', async () => {
    const { handler } = loadValidator(
      render({ legacy_client_allowlist_json: '["^com\\\\.example\\\\.videoapp/"]' }),
      {}
    );
    const good = await handler(makeRequest({ userAgent: 'com.example.videoapp/3.6.4' }));
    expect(good.statusCode).toBeUndefined();

    const bad = await handler(makeRequest({ userAgent: 'comXexampleXvideoapp/3.6.4' }));
    expect(bad.statusCode).toBe(401);
  });
});

describe('CTA validator — token_enforcement_mode', () => {
  test('mode=log forwards request even when token is missing', async () => {
    const { handler } = loadValidator(render({ token_enforcement_mode: 'log' }), {});
    const res = await handler(makeRequest());
    expect(res.statusCode).toBeUndefined();
    expect(res.uri).toBe('/broadcast/abc/720p30/live.m3u8');
  });

  test('mode=off short-circuits before allowlist even runs', async () => {
    // Use an allowlist that DOES match the UA — if off bypasses first
    // we should NOT see the allowlist_bypass log line. If the code ever
    // reordered so the allowlist ran before the off short-circuit,
    // this test would emit the log line and fail.
    const { handler, logs } = loadValidator(
      render({
        token_enforcement_mode: 'off',
        legacy_client_allowlist_json: '["^match-anything"]',
      }),
      {}
    );
    const res = await handler(makeRequest({ userAgent: 'match-anything/1.0' }));
    expect(res.statusCode).toBeUndefined();
    expect(res.uri).toBe('/broadcast/abc/720p30/live.m3u8');
    expect(logs.some(l => l.includes('allowlist_bypass'))).toBe(false);
  });

  test('mode=log strips path token before forwarding when validation fails', async () => {
    // Regression: log mode was forwarding /<token>/broadcast/... to
    // origin on bad path tokens, causing 404s. Token must be stripped
    // BEFORE validation so failure-forwarding is safe.
    const { handler } = loadValidator(
      render({ token_enforcement_mode: 'log' }),
      { 'key:default': 'signing-key' },
      { validateToken: () => { throw new Error('bad_signature'); } }
    );
    const req = makeRequest({ pathToken: 'x'.repeat(60), uri: '/broadcast/abc/720p30/live.m3u8' });
    const res = await handler(req);
    expect(res.statusCode).toBeUndefined();
    // Path token stripped even though validation threw.
    expect(res.uri).toBe('/broadcast/abc/720p30/live.m3u8');
  });

  test('mode=log strips ?CAT= query before forwarding when validation fails', async () => {
    const { handler } = loadValidator(
      render({ token_enforcement_mode: 'log' }),
      { 'key:default': 'signing-key' },
      { validateToken: () => { throw new Error('bad_signature'); } }
    );
    const evt = makeRequest();
    evt.request.querystring.CAT = { value: 'bad-token-value' };
    const res = await handler(evt);
    expect(res.statusCode).toBeUndefined();
    expect(res.request === undefined || !('CAT' in (res.querystring || {}))).toBe(true);
    // The mutated request object is what's forwarded — check its querystring.
    expect(res.querystring.CAT).toBeUndefined();
  });

  test('mode=enforce rejects with 401 on missing_token (default)', async () => {
    const { handler } = loadValidator(render({}), { 'key:default': 'test-signing-key' });
    const res = await handler(makeRequest());
    expect(res.statusCode).toBe(401);
    expect(res.headers['cache-control'].value).toBe('no-store, max-age=0');
  });

  test('rejects include access-control-allow-origin: * so browser JS can read them', async () => {
    const { handler } = loadValidator(render({}), { 'key:default': 'test-signing-key' });
    const res = await handler(makeRequest());
    expect(res.statusCode).toBe(401);
    expect(res.headers['access-control-allow-origin'].value).toBe('*');
  });

});

describe('CTA validator — DMA blackout gate', () => {
  test('enforce + matching metro → 451 blackout_dma', async () => {
    const { handler } = loadValidator(
      render({ dma_enforcement_mode: 'enforce', token_enforcement_mode: 'off' }),
      { 'blackout:abc': '602,524' }
    );
    const res = await handler(makeRequest({ uri: '/broadcast/abc/720p30/live.m3u8', metroCode: 602 }));
    expect(res.statusCode).toBe(451);
    expect(res.body).toBe('blackout_dma');
    expect(res.headers['cache-control'].value).toBe('no-store, max-age=0');
    expect(res.headers['access-control-allow-origin'].value).toBe('*');
  });

  test('enforce + non-matching metro → forwards', async () => {
    const { handler } = loadValidator(
      render({ dma_enforcement_mode: 'enforce', token_enforcement_mode: 'off' }),
      { 'blackout:abc': '602,524' }
    );
    const res = await handler(makeRequest({ uri: '/broadcast/abc/720p30/live.m3u8', metroCode: 501 }));
    expect(res.statusCode).toBeUndefined();
  });

  test('enforce + no KVS entry for broadcast → forwards (no blocklist = no block)', async () => {
    const { handler } = loadValidator(
      render({ dma_enforcement_mode: 'enforce', token_enforcement_mode: 'off' }),
      {}
    );
    const res = await handler(makeRequest({ uri: '/broadcast/never-seen/720p30/live.m3u8', metroCode: 602 }));
    expect(res.statusCode).toBeUndefined();
  });

  test('log mode + matching metro → forwards, emits log line', async () => {
    const { handler, logs } = loadValidator(
      render({ dma_enforcement_mode: 'log', token_enforcement_mode: 'off' }),
      { 'blackout:abc': '602' }
    );
    const res = await handler(makeRequest({ uri: '/broadcast/abc/720p30/live.m3u8', metroCode: 602 }));
    expect(res.statusCode).toBeUndefined();
    expect(logs.some(l => l.includes('blackout_dma broadcast=abc') && l.includes('metro=602'))).toBe(true);
  });

  test('off mode → check skipped entirely, no KVS lookup', async () => {
    // KVS stub that would throw if hit — proves we skipped the read.
    const kvsMap = {};
    Object.defineProperty(kvsMap, 'blackout:abc', {
      get() { throw new Error('KVS should not be consulted when dma is off'); },
    });
    const { handler } = loadValidator(
      render({ dma_enforcement_mode: 'off', token_enforcement_mode: 'off' }),
      kvsMap
    );
    const res = await handler(makeRequest({ uri: '/broadcast/abc/720p30/live.m3u8', metroCode: 602 }));
    expect(res.statusCode).toBeUndefined();
  });

  test('missing metro-code header emits a log line and fails open', async () => {
    // Consumers must attach a cache policy that forwards the metro
    // header; without one, "safe" 0-blocked readings in log mode are
    // meaningless. The log line makes the miss auditable.
    const { handler, logs } = loadValidator(
      render({ dma_enforcement_mode: 'log', token_enforcement_mode: 'off' }),
      { 'blackout:abc': '602' }
    );
    const res = await handler(makeRequest({ uri: '/broadcast/abc/720p30/live.m3u8' })); // no metroCode
    expect(res.statusCode).toBeUndefined();
    expect(logs.some(l => l.includes('blackout_dma_missing_metro'))).toBe(true);
  });

  test('DMA runs before token bypass — off token + enforce DMA still blocks', async () => {
    const { handler } = loadValidator(
      render({ dma_enforcement_mode: 'enforce', token_enforcement_mode: 'off' }),
      { 'blackout:abc': '602' }
    );
    const res = await handler(makeRequest({ uri: '/broadcast/abc/720p30/live.m3u8', metroCode: 602 }));
    expect(res.statusCode).toBe(451);
  });

  test('custom broadcast_uri_prefix routes DMA lookup at the right key', async () => {
    const { handler } = loadValidator(
      render({
        dma_enforcement_mode: 'enforce',
        token_enforcement_mode: 'off',
        broadcast_uri_prefix_json: JSON.stringify('/live/'),
      }),
      { 'blackout:xyz': '602' }
    );
    const res = await handler(makeRequest({ uri: '/live/xyz/720p30/live.m3u8', metroCode: 602 }));
    expect(res.statusCode).toBe(451);
  });
});

describe('CTA validator — CATGEOISO3166 (claim 316)', () => {
  function encodeToken(payload) {
    // Stub token: pass the payload straight to validateToken via a
    // custom stub. The token string itself is opaque — we care about
    // what payload validateClaims sees.
    return 'stub-token-value';
  }

  test('token with country claim + matching country → forwards', async () => {
    const { handler } = loadValidator(
      render({ token_enforcement_mode: 'enforce' }),
      { 'key:default': 'signing-key' },
      { validateToken: () => ({ payload: { 316: ['us', 'ca'] } }) }
    );
    const req = makeRequest({
      pathToken: 'x'.repeat(60),
      uri: '/broadcast/abc/720p30/live.m3u8',
      country: 'US',
    });
    const res = await handler(req);
    expect(res.statusCode).toBeUndefined();
  });

  test('token with country claim + non-matching country → 401 geo_restricted', async () => {
    const { handler } = loadValidator(
      render({ token_enforcement_mode: 'enforce' }),
      { 'key:default': 'signing-key' },
      { validateToken: () => ({ payload: { 316: ['us'] } }) }
    );
    const req = makeRequest({
      pathToken: 'x'.repeat(60),
      uri: '/broadcast/abc/720p30/live.m3u8',
      country: 'CA',
    });
    const res = await handler(req);
    expect(res.statusCode).toBe(401);
    expect(res.body).toBe('geo_restricted');
  });

  test('token with country claim + missing viewer country header → 401 geo_restricted', async () => {
    const { handler } = loadValidator(
      render({ token_enforcement_mode: 'enforce' }),
      { 'key:default': 'signing-key' },
      { validateToken: () => ({ payload: { 316: ['us'] } }) }
    );
    const req = makeRequest({
      pathToken: 'x'.repeat(60),
      uri: '/broadcast/abc/720p30/live.m3u8',
    });
    // No cloudfront-viewer-country header set.
    const res = await handler(req);
    expect(res.statusCode).toBe(401);
    expect(res.body).toBe('geo_restricted');
  });

  test('token without country claim → country header ignored', async () => {
    const { handler } = loadValidator(
      render({ token_enforcement_mode: 'enforce' }),
      { 'key:default': 'signing-key' },
      { validateToken: () => ({ payload: {} }) }
    );
    const req = makeRequest({
      pathToken: 'x'.repeat(60),
      uri: '/broadcast/abc/720p30/live.m3u8',
      country: 'CN',
    });
    const res = await handler(req);
    expect(res.statusCode).toBeUndefined();
  });

  test('country claim is case-insensitive (header uppercase, claim lowercase)', async () => {
    const { handler } = loadValidator(
      render({ token_enforcement_mode: 'enforce' }),
      { 'key:default': 'signing-key' },
      { validateToken: () => ({ payload: { 316: ['US'] } }) } // uppercase in claim
    );
    const req = makeRequest({
      pathToken: 'x'.repeat(60),
      uri: '/broadcast/abc/720p30/live.m3u8',
      country: 'us', // lowercase in header (defensively normalized)
    });
    const res = await handler(req);
    expect(res.statusCode).toBeUndefined();
  });
});
