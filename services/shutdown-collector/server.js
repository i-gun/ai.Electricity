import { createServer } from 'node:http';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { chromium } from 'playwright';
import { CachedCollector, DtekCollector, validateAddress } from './collector.js';

const port = Number(process.env.PORT || 47831);
const profile = process.env.DTEK_PROFILE || join(process.env.LOCALAPPDATA || homedir(), 'ai.Electricity', 'shutdown-browser');
let context;
async function browserContext() {
  if (!context) {
    context = chromium.launchPersistentContext(profile, {
      channel: process.env.BROWSER_CHANNEL || 'msedge',
      headless: process.env.HEADLESS === 'true',
    }).catch(error => { context = undefined; throw error; });
  }
  return context;
}
const collector = new CachedCollector(async address => {
  const browser = await browserContext();
  return new DtekCollector(browser).collect(address);
});

const server = createServer(async (request, response) => {
  response.setHeader('Content-Type', 'application/json; charset=utf-8');
  response.setHeader('Cache-Control', 'no-store');
  response.setHeader('X-Content-Type-Options', 'nosniff');
  const send = (status, body) => { response.writeHead(status); response.end(JSON.stringify(body)); };
  if (request.headers.origin || ![`127.0.0.1:${port}`, `localhost:${port}`].includes(request.headers.host)) {
    send(403, { error: 'Only local native clients are allowed' }); return;
  }
  if (request.method === 'GET' && request.url === '/health') {
    send(200, { status: 'ready', providers: ['dtek-krem', 'dtek-kem'], browser: context ? 'started' : 'not started' }); return;
  }
  if (request.method !== 'POST' || request.url !== '/shutdowns') {
    send(404, { error: 'Not found' }); return;
  }
  if (request.headers['content-type']?.split(';')[0] !== 'application/json') {
    send(415, { error: 'Expected JSON' }); return;
  }
  let address;
  try {
    let size = 0;
    const chunks = [];
    for await (const chunk of request) {
      size += chunk.length;
      if (size > 2048) { send(413, { error: 'Address too large' }); return; }
      chunks.push(chunk);
    }
    address = validateAddress(JSON.parse(Buffer.concat(chunks).toString('utf8')));
  } catch { send(400, { error: 'A supported region and complete city, street and building are required' }); return; }
  try {
    send(200, await collector.fetch(address));
  } catch {
    send(503, { error: 'DTEK lookup unavailable. Check the collector browser, address, and network, then retry.' });
  }
});
server.requestTimeout = 10000;
server.headersTimeout = 10000;
server.listen(port, '127.0.0.1', () => console.log(`Shutdown collector: http://127.0.0.1:${port}`));

async function stop() {
  server.close();
  if (context) await (await context).close();
}
process.once('SIGINT', stop);
process.once('SIGTERM', stop);