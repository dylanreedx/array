// Execute the bundled TypeScript with only its SDK/schema dependency stubbed.
import { stripTypeScriptTypes } from 'node:module';
import { readFile, mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import assert from 'node:assert/strict';
const base = resolve('Sources/ContinuumRevivedCore/Resources/PiExtensions');
const dataModule = source => `data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source)).toString('base64')}`;
const bridge = dataModule((await readFile(join(base, 'continuum-workspace-tools.ts'), 'utf8')).replaceAll('import.meta.url', JSON.stringify(pathToFileURL(join(base, 'continuum-workspace-tools.ts')).href)));
let source = await readFile(join(base, 'continuum-spawn-agent.ts'), 'utf8');
source = source.replace('"./continuum-workspace-tools.ts"', JSON.stringify(bridge))
  .replace('import { Type } from "typebox";', 'const Type = new Proxy({}, { get: () => (...args) => ({ args }) });');
const extension = (await import(dataModule(source))).default;
const tools = new Map();
extension({ registerTool: tool => tools.set(tool.name, tool) });
const wait = tools.get('wait_agents');
const root = await mkdtemp(join(tmpdir(), 'array-pi-wait-'));
const prior = process.env.CONTINUUM_ARRAY_MANAGED_AGENT;
process.env.CONTINUUM_ARRAY_MANAGED_AGENT = '1';
try {
  await mkdir(join(root, '.array/spawn-results'), { recursive: true });
  await writeFile(join(root, '.array/spawn-results/helper.json'), JSON.stringify({status:'spawned',agentId:'fixture'}));
  for (const reason of ['user_steer', 'inbox', 'cancelled', 'timeout']) {
    let polls = 0;
    const controller = new AbortController();
    const now = Date.now;
    const ctx = {cwd:root, hasUI:true, ui:{input:async title => {
      const request = JSON.parse(title);
      assert.equal(request.op, 'operation.get');
      if (!request.payload.pendingInputOnly) return JSON.stringify({schema:'array.workspace.v1', requestId:request.requestId,
        status:'ok', result:{childRunning:true}});
      polls++;
      if (polls === 2 && reason === 'cancelled') controller.abort();
      if (polls === 2 && reason === 'timeout') Date.now = () => now()+61000;
      return JSON.stringify({schema:'array.workspace.v1',requestId:request.requestId,status:'ok',
        result:{pendingInput:polls >= 2 && ['inbox','user_steer'].includes(reason) ? reason : null}});
    }}};
    const started = performance.now();
    const result = await Promise.race([
      wait.execute('wait-fixture', {handles:['helper'],timeoutSeconds:600}, controller.signal, undefined, ctx),
      new Promise((_,reject) => {const t=setTimeout(()=>reject(Error('wait did not interrupt within 2s')),2000);t.unref();})
    ]);
    Date.now = now;
    assert(performance.now()-started < 2000);
    assert.equal(result.details.interrupted, reason === 'timeout' ? undefined : reason);
    assert.equal(result.details.timedOut, reason === 'timeout');
    assert.equal(result.details.agents[0].status, 'running');
    console.log(`PASS pi: 600s requested wait returns on ${reason}, preserves running helper`);
  }
  // New authenticated courier reads must preserve wait interruption even
  // when many helper lookups stall. The UI fixture deliberately ignores abort.
  let queuedReason;
  const inputTimer = setTimeout(() => { queuedReason = 'inbox'; }, 50);
  const stalledCtx = {cwd:root,hasUI:true,ui:{input:async title => {
    const request=JSON.parse(title);
    if (request.payload.pendingInputOnly) return JSON.stringify({schema:'array.workspace.v1',requestId:request.requestId,
      status:'ok',result:{pendingInput:queuedReason ?? null}});
    return await new Promise(() => {});
  }}};
  let deadlineTimer;
  try {
    const started=performance.now();
    const result=await Promise.race([
      wait.execute('stalled-many-fixture',{handles:Array.from({length:16},(_,i)=>`stalled-${i}`),timeoutSeconds:60},
        undefined,undefined,stalledCtx),
      new Promise((_,reject)=>{deadlineTimer=setTimeout(()=>reject(Error('stalled Pi wait hid inbox input for more than 2s')),2000);})
    ]);
    assert(performance.now()-started<2000);
    assert.equal(result.details.interrupted,'inbox');
    assert.equal(result.details.timedOut,false);
    assert.equal(result.details.agents.length,16);
    assert(result.details.agents.every(agent=>agent.status==='running'));
    console.log('PASS pi: 16 stalled authenticated lookups cannot hide inbox input beyond 2s');
  } finally {clearTimeout(inputTimer);clearTimeout(deadlineTimer);}
} finally {
  if (prior === undefined) delete process.env.CONTINUUM_ARRAY_MANAGED_AGENT;
  else process.env.CONTINUUM_ARRAY_MANAGED_AGENT = prior;
  await rm(root, {recursive:true,force:true});
}
