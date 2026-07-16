/**
 * CTA Real-Time Auto-Revocation — Kinesis Stream Processor
 *
 * Receives CloudFront real-time log records from Kinesis Data Streams,
 * aggregates session activity, detects anomalies via Bedrock Nova Pro,
 * and revokes suspicious sessions in CloudFront KeyValueStore.
 *
 * Pipeline: CloudFront Real-Time Logs → Kinesis → This Lambda → Bedrock → KVS
 */

const { BedrockRuntimeClient, InvokeModelCommand } = require('@aws-sdk/client-bedrock-runtime');
const { CloudFrontKeyValueStoreClient, PutKeyCommand, DescribeKeyValueStoreCommand } = require('@aws-sdk/client-cloudfront-keyvaluestore');
const { SSMClient, GetParameterCommand } = require('@aws-sdk/client-ssm');
require('@aws-sdk/signature-v4a');

const bedrock = new BedrockRuntimeClient({ region: process.env.BEDROCK_REGION || 'us-east-1' });
const kvsClient = new CloudFrontKeyValueStoreClient({});
const ssm = new SSMClient({});
const KVS_ARN = process.env.KVS_ARN;
const MODEL_ID = process.env.BEDROCK_MODEL || 'amazon.nova-lite-v1:0';
const PROMPT_PARAM = process.env.PROMPT_PARAM;

let cachedPrompt = null;
let promptCacheTime = 0;
const PROMPT_CACHE_TTL = 60000; // 1 minute

const DEFAULT_PROMPT = `You are a video streaming security analyst. Analyze these CTA-5007-B token session metrics from CloudFront real-time logs and identify sessions that should be revoked due to unauthorized sharing or abuse.

Each session represents a unique CTA token being used to access protected video content through CloudFront.

## Indicators of Token Sharing / Abuse
- Multiple distinct IP addresses using the same token (strongest signal)
- Requests from multiple countries with the same token
- Multiple different User-Agent strings (different devices/browsers)
- Abnormally high request rates (automated scraping)
- High error rates combined with high request volume (brute force)

## Indicators of Legitimate Use
- Single IP, single country, single User-Agent = normal viewer
- Moderate request rates (1-5 requests/sec is normal for adaptive streaming)
- IP changes within the same country could be mobile network handoff (less suspicious)

## Instructions
Respond with ONLY a JSON array of session keys that should be revoked. If no sessions should be revoked, respond with an empty array [].
Be conservative — only revoke sessions with strong evidence of sharing or abuse. A single IP change within the same country is NOT sufficient for revocation.`;

async function getPrompt() {
    if (!PROMPT_PARAM) return DEFAULT_PROMPT;
    if (cachedPrompt && Date.now() - promptCacheTime < PROMPT_CACHE_TTL) return cachedPrompt;
    try {
        const resp = await ssm.send(new GetParameterCommand({ Name: PROMPT_PARAM }));
        cachedPrompt = resp.Parameter.Value;
        promptCacheTime = Date.now();
        return cachedPrompt;
    } catch {
        return DEFAULT_PROMPT;
    }
}

// Thresholds for pre-filtering before sending to Bedrock
const THRESHOLDS = {
    MIN_REQUESTS_TO_ANALYZE: 10,     // Minimum requests per session to consider
    MAX_UNIQUE_IPS_PER_SESSION: 3,   // Flag if session used from more IPs
    HIGH_REQUEST_RATE: 50,           // Requests per minute threshold
    ERROR_RATE_THRESHOLD: 0.3,       // 30% error rate
};

/**
 * Parse a CloudFront real-time log record (tab-separated fields).
 * Field order matches the real-time log config in the CDK stack.
 */
function parseLogRecord(record) {
    const fields = record.split('\t');
    return {
        timestamp: fields[0],
        clientIp: fields[1],
        status: parseInt(fields[2]) || 0,
        uri: fields[3],
        method: fields[4],
        host: fields[5],
        userAgent: fields[6],
        bytesOut: parseInt(fields[7]) || 0,
        timeTaken: parseFloat(fields[8]) || 0,
        country: fields[9],
    };
}

/**
 * Extract the CTA session ID from the URI path.
 * The token is the first path segment (>50 chars), and the CTI claim
 * is embedded in the CBOR payload. Since we can't decode CBOR here,
 * we use the token itself as the session fingerprint.
 */
function extractSessionKey(uri) {
    const segments = uri.split('/');
    if (segments[1] && segments[1].length > 50) {
        // Use first 32 chars of token as session key (unique enough, avoids huge keys)
        return segments[1].substring(0, 32);
    }
    return null;
}

/**
 * Aggregate log records by session, computing per-session metrics.
 */
function aggregateSessions(records) {
    const sessions = {};

    for (const rec of records) {
        const parsed = parseLogRecord(rec);
        const sessionKey = extractSessionKey(parsed.uri);
        if (!sessionKey) continue;

        if (!sessions[sessionKey]) {
            sessions[sessionKey] = {
                sessionKey,
                firstSeen: parsed.timestamp,
                lastSeen: parsed.timestamp,
                requestCount: 0,
                uniqueIps: new Set(),
                countries: new Set(),
                statusCodes: {},
                totalBytes: 0,
                paths: new Set(),
                userAgents: new Set(),
            };
        }

        const s = sessions[sessionKey];
        s.requestCount++;
        s.lastSeen = parsed.timestamp;
        s.uniqueIps.add(parsed.clientIp);
        s.countries.add(parsed.country);
        s.statusCodes[parsed.status] = (s.statusCodes[parsed.status] || 0) + 1;
        s.totalBytes += parsed.bytesOut;
        s.paths.add(parsed.uri.split('?')[0]);
        s.userAgents.add(parsed.userAgent);
    }

    // Convert Sets to arrays for JSON serialization
    return Object.values(sessions).map(s => ({
        ...s,
        uniqueIps: [...s.uniqueIps],
        countries: [...s.countries],
        paths: [...s.paths].slice(0, 10), // Limit for prompt size
        userAgents: [...s.userAgents],
        errorRate: ((s.statusCodes[401] || 0) + (s.statusCodes[403] || 0)) / s.requestCount,
    }));
}

/**
 * Pre-filter sessions that show obvious anomalies before sending to Bedrock.
 * Returns sessions worth analyzing (reduces Bedrock calls and cost).
 */
function filterSuspiciousSessions(sessions) {
    return sessions.filter(s =>
        s.requestCount >= THRESHOLDS.MIN_REQUESTS_TO_ANALYZE && (
            s.uniqueIps.length > THRESHOLDS.MAX_UNIQUE_IPS_PER_SESSION ||
            s.userAgents.length > 2 ||
            s.countries.length > 1 ||
            s.errorRate > THRESHOLDS.ERROR_RATE_THRESHOLD ||
            s.requestCount > THRESHOLDS.HIGH_REQUEST_RATE
        )
    );
}

/**
 * Send suspicious sessions to Bedrock Nova Pro for analysis.
 * Returns an array of session keys that should be revoked.
 */
async function analyzeWithBedrock(sessions) {
    if (sessions.length === 0) return [];

    const basePrompt = await getPrompt();
    const prompt = `${basePrompt}

## Session Data
${JSON.stringify(sessions, null, 2)}

Example response: ["abc123def456", "xyz789ghi012"]`;

    const command = new InvokeModelCommand({
        modelId: MODEL_ID,
        contentType: 'application/json',
        accept: 'application/json',
        body: JSON.stringify({
            messages: [{ role: 'user', content: [{ text: prompt }] }],
            inferenceConfig: { maxTokens: 1024, temperature: 0 },
        }),
    });

    const response = await bedrock.send(command);
    const body = JSON.parse(new TextDecoder().decode(response.body));
    const text = body.output?.message?.content?.[0]?.text || '[]';

    // Extract JSON array from response (handle markdown code blocks)
    const match = text.match(/\[[\s\S]*?\]/);
    if (!match) return [];

    try {
        return JSON.parse(match[0]);
    } catch {
        return [];
    }
}

/**
 * Write revocations to CloudFront KeyValueStore.
 */
async function revokeSession(sessionKey) {
    const etag = (await kvsClient.send(new DescribeKeyValueStoreCommand({ KvsARN: KVS_ARN }))).ETag;
    await kvsClient.send(new PutKeyCommand({
        KvsARN: KVS_ARN,
        Key: `revoked:${sessionKey}`,
        Value: JSON.stringify({ reason: 'auto:bedrock', revokedAt: Math.floor(Date.now() / 1000) }),
        IfMatch: etag,
    }));
}

exports.handler = async (event) => {
    // Decode Kinesis records
    const records = event.Records
        .map(r => Buffer.from(r.kinesis.data, 'base64').toString('utf-8'))
        .filter(r => r.trim().length > 0);

    if (records.length === 0) return { processed: 0 };

    // Aggregate by session
    const sessions = aggregateSessions(records);

    // Pre-filter for suspicious patterns
    const suspicious = filterSuspiciousSessions(sessions);

    if (suspicious.length === 0) {
        return { processed: records.length, sessions: sessions.length, suspicious: 0, revoked: 0 };
    }

    // Analyze with Bedrock Nova Pro
    const toRevoke = await analyzeWithBedrock(suspicious);

    // Revoke flagged sessions
    let revokedCount = 0;
    for (const sessionKey of toRevoke) {
        try {
            await revokeSession(sessionKey);
            revokedCount++;
            console.log(`Revoked session: ${sessionKey}`);
        } catch (err) {
            console.error(`Failed to revoke ${sessionKey}: ${err.message}`);
        }
    }

    return {
        processed: records.length,
        sessions: sessions.length,
        suspicious: suspicious.length,
        analyzed: suspicious.length,
        revoked: revokedCount,
    };
};
