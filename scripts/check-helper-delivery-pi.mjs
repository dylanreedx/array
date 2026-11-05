// One channel per recipient: the bundled pi extension offers no wait_agents,
// hosted by Array or not. Executes the real TypeScript with its SDK stubbed.
import { stripTypeScriptTypes } from 'node:module';
import { readFile } from 'node:fs/promises';
import assert from 'node:assert/strict';
const extensionPath = new URL('../Sources/ContinuumRevivedCore/Resources/PiExtensions/continuum-spawn-agent.ts', import.meta.url);
let source = await readFile(extensionPath, 'utf8');
source = source.replace('import { Type } from "typebox";', 'const Type = new Proxy({}, { get: () => (...args) => ({ args }) });');
const { default: install } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source)).toString('base64')}`);
// Only this fixture process's own environment is toggled; no provider or
// crash witness runs here, and the inherited value is restored.
const prior = process.env.CONTINUUM_ARRAY_MANAGED_AGENT;
try {
  for (const hosted of [true, false]) {
    if (hosted) process.env.CONTINUUM_ARRAY_MANAGED_AGENT = '1'; else delete process.env.CONTINUUM_ARRAY_MANAGED_AGENT;
    const tools = new Map();
    install({ registerTool: tool => tools.set(tool.name, tool) });
    assert.deepEqual([...tools.keys()], ['spawn_agent'], `registered ${[...tools.keys()]}`);
    const spawn = tools.get('spawn_agent');
    const text = [spawn.description, ...spawn.promptGuidelines].join('\n');
    assert(!text.includes('wait_agents'), text);
    assert(text.includes('Array delivers'), text);
    const reply = await spawn.execute('handle-1', { prompt: 'x' });
    assert(reply.content[0].text.includes('Array delivers the result'), reply.content[0].text);
    console.log(`PASS pi (${hosted ? 'Array-run' : 'unhosted'}): spawn_agent only, no wait_agents, says results are delivered`);
  }
} finally {
  if (prior === undefined) delete process.env.CONTINUUM_ARRAY_MANAGED_AGENT; else process.env.CONTINUUM_ARRAY_MANAGED_AGENT = prior;
}
