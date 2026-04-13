const https = require('https');
const fs = require('fs');
const path = require('path');

// Load system prompts and product data at cold start
const productData = fs.readFileSync(path.join(__dirname, '..', 'products.json'), 'utf8');
const customerPrompt = fs.readFileSync(path.join(__dirname, '..', 'system-prompt.txt'), 'utf8')
  + '\n\n<product_data>\n' + productData + '\n</product_data>';
const internalPrompt = fs.readFileSync(path.join(__dirname, '..', 'system-prompt-internal.txt'), 'utf8')
  + '\n\n<product_data>\n' + productData + '\n</product_data>';

const PROMPTS = { customer: customerPrompt, internal: internalPrompt };

function callAnthropic(apiKey, systemPrompt, messages) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({
      model: 'claude-sonnet-4-20250514',
      max_tokens: 2048,
      system: systemPrompt,
      messages: messages
    });

    const req = https.request({
      hostname: 'api.anthropic.com',
      path: '/v1/messages',
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
        'Content-Length': Buffer.byteLength(body)
      }
    }, (res) => {
      let data = '';
      res.on('data', chunk => { data += chunk; });
      res.on('end', () => {
        if (res.statusCode === 200) {
          resolve(JSON.parse(data));
        } else {
          reject(new Error(`API ${res.statusCode}: ${data}`));
        }
      });
    });

    req.on('error', reject);
    req.setTimeout(60000, () => { req.destroy(); reject(new Error('Timeout')); });
    req.write(body);
    req.end();
  });
}

module.exports = async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') return res.status(204).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey) return res.status(500).json({ error: 'API key not configured' });

  try {
    const { messages = [], mode = 'customer' } = req.body;
    const systemPrompt = PROMPTS[mode] || PROMPTS.customer;

    const result = await callAnthropic(apiKey, systemPrompt, messages);
    const text = result.content?.find(c => c.type === 'text')?.text || '';

    return res.status(200).json({ reply: text });
  } catch (err) {
    console.error('Error:', err.message);
    return res.status(502).json({ error: err.message });
  }
};
