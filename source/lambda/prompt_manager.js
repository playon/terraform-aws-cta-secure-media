/**
 * Prompt Manager — GET/PUT the Bedrock analysis prompt in SSM Parameter Store
 */

const { SSMClient, GetParameterCommand, PutParameterCommand } = require('@aws-sdk/client-ssm');
const ssm = new SSMClient({});
const PARAM_NAME = process.env.PROMPT_PARAM;

exports.handler = async (event) => {
    const headers = { 'Access-Control-Allow-Origin': '*' };
    try {
        if (event.httpMethod === 'GET') {
            const resp = await ssm.send(new GetParameterCommand({ Name: PARAM_NAME }));
            return { statusCode: 200, headers, body: JSON.stringify({ prompt: resp.Parameter.Value }) };
        }

        if (event.httpMethod === 'PUT') {
            const { prompt } = JSON.parse(event.body);
            if (!prompt) return { statusCode: 400, headers, body: JSON.stringify({ error: 'Missing prompt' }) };
            await ssm.send(new PutParameterCommand({ Name: PARAM_NAME, Value: prompt, Type: 'String', Overwrite: true }));
            return { statusCode: 200, headers, body: JSON.stringify({ success: true }) };
        }

        return { statusCode: 405, headers, body: 'Method not allowed' };
    } catch (err) {
        return { statusCode: 500, headers, body: JSON.stringify({ error: err.message }) };
    }
};
