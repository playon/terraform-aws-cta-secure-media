// Mock AWS SDK clients before requiring handlers
const mockSend = jest.fn();
jest.mock('@aws-sdk/client-secrets-manager', () => ({
  SecretsManagerClient: jest.fn(() => ({ send: mockSend })),
  GetSecretValueCommand: jest.fn(p => ({ _type: 'GetSecret', ...p })),
}));
jest.mock('@aws-sdk/client-cloudfront-keyvaluestore', () => ({
  CloudFrontKeyValueStoreClient: jest.fn(() => ({ send: mockSend })),
  PutKeyCommand: jest.fn(p => ({ _type: 'PutKey', ...p })),
  ListKeysCommand: jest.fn(p => ({ _type: 'ListKeys', ...p })),
  DeleteKeyCommand: jest.fn(p => ({ _type: 'DeleteKey', ...p })),
  DescribeKeyValueStoreCommand: jest.fn(p => ({ _type: 'Describe', ...p })),
}));
jest.mock('@aws-sdk/signature-v4a', () => ({}));
jest.mock('@aws-sdk/client-ssm', () => ({
  SSMClient: jest.fn(() => ({ send: mockSend })),
  GetParameterCommand: jest.fn(p => ({ _type: 'GetParam', ...p })),
  PutParameterCommand: jest.fn(p => ({ _type: 'PutParam', ...p })),
}));

beforeEach(() => {
  mockSend.mockReset();
  process.env.SECRET_NAME = 'test-secret';
  process.env.KVS_ARN = 'arn:aws:cloudfront::123:key-value-store/test';
  process.env.TTL_HOURS = '24';
  process.env.PROMPT_PARAM = '/test/prompt';
});

// --- Token Generator ---
describe('cta_token_generator', () => {
  const { handler } = require('../cta_token_generator');

  beforeEach(() => {
    mockSend.mockResolvedValue({ SecretString: JSON.stringify({ signingKey: 'test-key-abc123' }) });
  });

  test('generates token with valid input', async () => {
    const event = { body: JSON.stringify({ policy: { paths: ['/video/'], ttl: '1h' }, mediaUrl: 'https://cdn.example.com/video/test.m3u8' }) };
    const res = await handler(event);
    const body = JSON.parse(res.body);
    expect(res.statusCode).toBe(200);
    expect(body.token).toBeDefined();
    expect(body.signedUrl).toContain(body.token);
    expect(body.expiresAt).toBeGreaterThan(Math.floor(Date.now() / 1000));
  });

  test('returns path-based signed URL by default', async () => {
    const event = { body: JSON.stringify({ policy: { paths: ['/video/'] }, mediaUrl: 'https://cdn.example.com/video/test.m3u8' }) };
    const res = await handler(event);
    const body = JSON.parse(res.body);
    expect(body.signedUrl).toMatch(/^https:\/\/cdn\.example\.com\/[A-Za-z0-9_-]+\/video\/test\.m3u8$/);
  });

  test('returns query-based signed URL when placement=query', async () => {
    const event = { body: JSON.stringify({ policy: { placement: 'query' }, mediaUrl: 'https://cdn.example.com/video/test.m3u8' }) };
    const res = await handler(event);
    const body = JSON.parse(res.body);
    expect(body.signedUrl).toContain('?CAT=');
  });

  test('includes session ID in token', async () => {
    const event = { body: JSON.stringify({ policy: { sessionId: 'sess-123' }, mediaUrl: 'https://cdn.example.com/v.m3u8' }) };
    const res = await handler(event);
    expect(res.statusCode).toBe(200);
  });

  test('returns 500 for missing policy', async () => {
    const event = { body: JSON.stringify({ mediaUrl: 'https://cdn.example.com/v.m3u8' }) };
    const res = await handler(event);
    expect(res.statusCode).toBe(500);
    expect(JSON.parse(res.body).error).toContain('Missing required');
  });

  test('returns 500 for invalid mediaUrl', async () => {
    const event = { body: JSON.stringify({ policy: {}, mediaUrl: 'not-a-url' }) };
    const res = await handler(event);
    expect(res.statusCode).toBe(500);
    expect(JSON.parse(res.body).error).toContain('valid HTTP');
  });

  test('includes CORS header', async () => {
    const event = { body: JSON.stringify({ policy: {}, mediaUrl: 'https://cdn.example.com/v.m3u8' }) };
    const res = await handler(event);
    expect(res.headers['Access-Control-Allow-Origin']).toBe('*');
  });
});

// --- Token Revocation ---
describe('cta_revocation', () => {
  const { handler } = require('../cta_revocation');

  beforeEach(() => {
    mockSend.mockResolvedValue({ ETag: 'etag-123' });
  });

  test('revokes a token', async () => {
    const event = { body: JSON.stringify({ tokenId: 'session-abc', reason: 'abuse' }) };
    const res = await handler(event);
    const body = JSON.parse(res.body);
    expect(res.statusCode).toBe(200);
    expect(body.success).toBe(true);
    expect(body.tokenId).toBe('session-abc');
    expect(body.reason).toBe('abuse');
  });

  test('defaults reason to manual', async () => {
    const event = { body: JSON.stringify({ tokenId: 'session-abc' }) };
    const res = await handler(event);
    expect(JSON.parse(res.body).reason).toBe('manual');
  });

  test('returns 400 for missing tokenId', async () => {
    const event = { body: JSON.stringify({}) };
    const res = await handler(event);
    expect(res.statusCode).toBe(400);
    expect(JSON.parse(res.body).error).toContain('Missing tokenId');
  });
});

// --- List Revoked ---
describe('list_revoked', () => {
  const { handler } = require('../list_revoked');

  test('returns revoked sessions sorted by time', async () => {
    mockSend.mockResolvedValue({
      Items: [
        { Key: 'revoked:sess-1', Value: JSON.stringify({ reason: 'manual', revokedAt: 1000 }) },
        { Key: 'revoked:sess-2', Value: JSON.stringify({ reason: 'auto', revokedAt: 2000 }) },
        { Key: 'key:default', Value: 'signing-key' },
      ]
    });
    const res = await handler();
    const body = JSON.parse(res.body);
    expect(res.statusCode).toBe(200);
    expect(body.count).toBe(2);
    expect(body.revoked[0].sessionId).toBe('sess-2'); // most recent first
    expect(body.revoked[1].sessionId).toBe('sess-1');
  });

  test('filters out non-revoked keys', async () => {
    mockSend.mockResolvedValue({ Items: [{ Key: 'key:default', Value: 'abc' }] });
    const res = await handler();
    expect(JSON.parse(res.body).count).toBe(0);
  });

  test('handles empty KVS', async () => {
    mockSend.mockResolvedValue({ Items: [] });
    const res = await handler();
    expect(JSON.parse(res.body).count).toBe(0);
  });
});

// --- Prompt Manager ---
describe('prompt_manager', () => {
  const { handler } = require('../prompt_manager');

  test('GET returns the prompt', async () => {
    mockSend.mockResolvedValue({ Parameter: { Value: 'Analyze sessions...' } });
    const res = await handler({ httpMethod: 'GET' });
    expect(res.statusCode).toBe(200);
    expect(JSON.parse(res.body).prompt).toBe('Analyze sessions...');
  });

  test('PUT updates the prompt', async () => {
    mockSend.mockResolvedValue({});
    const res = await handler({ httpMethod: 'PUT', body: JSON.stringify({ prompt: 'New prompt' }) });
    expect(res.statusCode).toBe(200);
    expect(JSON.parse(res.body).success).toBe(true);
  });

  test('PUT returns 400 for missing prompt', async () => {
    const res = await handler({ httpMethod: 'PUT', body: JSON.stringify({}) });
    expect(res.statusCode).toBe(400);
  });

  test('returns 405 for unsupported method', async () => {
    const res = await handler({ httpMethod: 'DELETE' });
    expect(res.statusCode).toBe(405);
  });
});
