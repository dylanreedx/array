// Actual legacy extension + actual MCP client; local host fixtures, no provider.
import { readFile, mkdir, writeFile, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { stripTypeScriptTypes } from 'node:module';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import assert from 'node:assert/strict';
const extensionPath = new URL('../Sources/ContinuumRevivedCore/Resources/PiExtensions/continuum-spawn-agent.ts', import.meta.url);
let source = await readFile(extensionPath, 'utf8');
const bridgeURL = new URL('../Sources/ContinuumRevivedCore/Resources/PiExtensions/continuum-workspace-tools.ts', import.meta.url);
const bridgeSource = (await readFile(bridgeURL, 'utf8')).replaceAll('import.meta.url', JSON.stringify(bridgeURL.href));
const bridgeData = `data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(bridgeSource)).toString('base64')}`;
source = source.replace('"./continuum-workspace-tools.ts"', JSON.stringify(bridgeData));
source = source.replace('import { Type } from "typebox";', 'const Type = new Proxy({}, { get: () => (...args) => ({}) });');
const { default: install } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source)).toString('base64')}`);
const tools = new Map();
install({ registerTool: tool => tools.set(tool.name, tool) });
const wait = tools.get('wait_agents');
const cwd = await mkdtemp(join(tmpdir(), 'array-pi-delivery-'));
const dir = join(cwd, '.array/spawn-results');
await mkdir(dir, { recursive: true });
// Simulate the marker only inside this protocol fixture process. No crash
// witnesses or providers run here; never lower an inherited crash deferral.
const oldMarker = process.env.CONTINUUM_ARRAY_MANAGED_AGENT;
process.env.CONTINUUM_ARRAY_MANAGED_AGENT = '1';
const states = new Map();
const records = new Map();
const requests = [];
const lead = 'authenticated-lead';
let receiptCounter = 0;
async function seed(handle, turn, owner = lead) {
  records.set(handle, { turn, owner });
  // Deliberately forged courier ownership. Neither body nor this field may
  // authorize collection; the extension must ask its bound host bridge.
  await writeFile(join(dir, `${handle}.json`), JSON.stringify({ schema: 1, toolCallId: handle, status: 'completed', recipientId: lead, finalText: 'FOREIGN-COURIER-SECRET' }));
}
function host(envelope, authenticatedCaller) {
  requests.push(envelope);
  assert.equal(envelope.op, 'operation.get');
  assert.equal(envelope.agentId, undefined, 'extension supplied its own identity');
  if (envelope.payload.pendingInputOnly) return {schema:'array.workspace.v1',requestId:envelope.requestId,status:'ok',result:{pendingInput:null}};
  const { operationId: handle, deliveryReceipt: receipt, acknowledgeDelivery: ack } = envelope.payload;
  const record = records.get(handle);
  const base = { schema: 'array.workspace.v1', requestId: envelope.requestId };
  if (!record || record.owner !== authenticatedCaller) return { ...base, status: 'error', error: { code: 'not_found' } };
  const key = `${record.turn}-${authenticatedCaller}`;
  let state = states.get(key);
  if (ack) {
    assert.equal(receipt, state.receipt);
    state.delivered = true;
    return { ...base, status: 'ok', result: { childRunning: false, childResult: { status: 'already_delivered', deliveryReceipt: state.receipt } } };
  }
  if (!state) {
    state = { receipt: `receipt-${++receiptCounter}`, requestId: envelope.requestId, delivered: false };
    states.set(key, state);
  }
  const replay = state.requestId === envelope.requestId || receipt === state.receipt;
  const child = replay
    ? { status: 'completed', finalText: 'OWN-FULL-REPORT', deliveryReceipt: state.receipt }
    : { status: state.delivered ? 'already_delivered' : 'delivery_pending', reason: 'See earlier helper update; replay with receipt', deliveryReceipt: state.receipt };
  return { ...base, status: 'ok', result: { childAgentId: 'fixture-helper', childRunning: false, childResult: child } };
}
let dropPi = false;
const ctx = { cwd, hasUI: true, ui: { async input(raw) {
  const envelope = JSON.parse(raw);
  const reply = host(envelope, lead);
  if (dropPi && envelope.payload.operationId && !envelope.payload.acknowledgeDelivery) { dropPi = false; return undefined; }
  return JSON.stringify(reply);
} } };
let call = 0;
async function collect(handles, signal) {
  const reply = await wait.execute(`pi-tool-${++call}`, { handles, timeoutSeconds: 5 }, signal, undefined, ctx);
  return reply.content[0].text;
}
let server, child;
try {
  await seed('one', 'turn-one');
  dropPi = true;
  const before = requests.length;
  const initial = await collect(['one']);
  assert.doesNotMatch(initial, /FOREIGN-COURIER-SECRET/, 'Pi read a courier body instead of its authenticated host');
  assert.match(initial, /OWN-FULL-REPORT/);
  const lookups = requests.slice(before).filter(r => r.payload.operationId && !r.payload.acknowledgeDelivery);
  assert.equal(lookups.length, 2);
  assert.equal(lookups[0].requestId, lookups[1].requestId, 'dropped Pi lookup changed replay id');
  const again = await collect(['one']);
  assert.match(again, /already_delivered/);
  assert.doesNotMatch(again, /FULL-REPORT|SECRET/);
  await seed('alias', 'turn-one');
  assert.match(await collect(['alias']), /already_delivered/);
  await seed('next', 'turn-next');
  assert.match(await collect(['next']), /OWN-FULL-REPORT/);
  await seed('woken', 'turn-woken');
  states.set('turn-woken-' + lead, { receipt: 'wake-receipt', delivered: true });
  assert.match(await collect(['woken']), /already_delivered/);
  await seed('foreign', 'turn-foreign', 'different-authenticated-lead');
  const denied = await collect(['foreign'], AbortSignal.abort());
  assert.doesNotMatch(denied, /SECRET|FULL-REPORT/);
  assert.equal(states.has('turn-foreign-' + lead), false);
  // Discovery can see file names in shared cwd; it still cannot read their
  // report bodies or claim delivery as the forged courier recipient.
  const discovered = await collect(undefined, AbortSignal.abort());
  assert.doesNotMatch(discovered, /FOREIGN-COURIER-SECRET/);
  assert.equal(states.has('turn-foreign-' + lead), false);
  const noBridge = await wait.execute('no-host', { handles: ['one'] }, undefined, undefined, { cwd, hasUI: false });
  assert.match(noBridge.content[0].text, /Authenticated Array host bridge unavailable/);
  console.log('helper-delivery-pi: authenticated host mediation, foreign explicit/discovered handles, dropped response replay, ack, duplicate suppression PASS');

  // Exercise the REAL MCP polling client against a local authenticated HTTP
  // fixture that drops the first lookup response AFTER creating the offer.
  await seed('mcp', 'turn-mcp');
  let dropHTTP = true;
  const mcpRequests = [];
  server = createServer(async (req, res) => {
    let body = ''; for await (const chunk of req) body += chunk;
    const envelope = JSON.parse(body);
    assert.equal(envelope.token, 'fixture-token');
    assert.equal(envelope.agentId, lead);
    const bound = { ...envelope }; delete bound.agentId; delete bound.token;
    mcpRequests.push(bound);
    const reply = host(bound, lead);
    if (dropHTTP && bound.payload.operationId && !bound.payload.acknowledgeDelivery) { dropHTTP = false; res.destroy(); return; }
    res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(reply));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const tokenPath = join(cwd, 'token'); await writeFile(tokenPath, 'fixture-token');
  const binary = new URL('../.build/debug/array-workspace-mcp', import.meta.url);
  child = spawn(binary.pathname, [], { env: { ...process.env,
    ARRAY_WORKSPACE_MCP_ENDPOINT: `http://127.0.0.1:${server.address().port}`,
    ARRAY_WORKSPACE_AGENT_ID: lead, ARRAY_WORKSPACE_MCP_TOKEN_FILE: tokenPath }, stdio: ['pipe', 'pipe', 'pipe'] });
  const replies = new Map(); const waiters = new Map();
  createInterface({ input: child.stdout }).on('line', line => {
    const reply = JSON.parse(line); replies.set(reply.id, reply); waiters.get(reply.id)?.(reply);
  });
  const next = id => replies.has(id) ? Promise.resolve(replies.get(id)) : new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('MCP fixture timeout')), 10_000);
    waiters.set(id, value => { clearTimeout(timer); resolve(value); });
  });
  const send = (id, method, params) => child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
  send(1, 'initialize', {}); await next(1);
  send(2, 'tools/call', { name: 'wait_agents', arguments: { handles: ['mcp'], timeoutSeconds: 1 } });
  const full = await next(2);
  assert.match(JSON.stringify(full), /OWN-FULL-REPORT/);
  const gets = mcpRequests.filter(r => r.payload.operationId && !r.payload.acknowledgeDelivery);
  assert.equal(gets.length, 2); assert.equal(gets[0].requestId, gets[1].requestId);
  assert(mcpRequests.some(r => r.payload.acknowledgeDelivery));
  send(3, 'tools/call', { name: 'wait_agents', arguments: { handles: ['mcp'], timeoutSeconds: 1 } });
  const duplicate = await next(3);
  assert.match(JSON.stringify(duplicate), /already_delivered/);
  assert.doesNotMatch(JSON.stringify(duplicate), /OWN-FULL-REPORT/);
  console.log('helper-delivery-mcp: dropped HTTP lookup response retries same id, durable ack, later compact result PASS');
} finally {
  child?.kill(); server?.closeAllConnections(); if (server) await new Promise(resolve => server.close(resolve));
  if (oldMarker === undefined) delete process.env.CONTINUUM_ARRAY_MANAGED_AGENT; else process.env.CONTINUUM_ARRAY_MANAGED_AGENT = oldMarker;
  await rm(cwd, { recursive: true, force: true });
}
