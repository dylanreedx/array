import test from 'node:test';
import assert from 'node:assert/strict';
import {JSDOM} from 'jsdom';
const dom = new JSDOM('<html><body></body></html>', {url:'https://local.invalid'});
for (const key of ['window','document','navigator','HTMLElement','Node','MutationObserver','getComputedStyle']) Object.defineProperty(globalThis,key,{value:dom.window[key],configurable:true});
const {Editor} = await import('@tiptap/core');
const {extensions} = await import('../src/document.js');
function roundtrip(body) { const editor=new Editor({extensions:extensions(),content:body,contentType:'markdown'}); const output=editor.getMarkdown(); editor.destroy(); return output; }
test('task formatting, checklist, image and literal unsupported source survive editing',()=>{
 const source='# Heading\n\n**bold** and *italic*\n\n- [ ] todo\n- [x] done\n\n![Screenshot](array-task-image://00000000-0000-0000-0000-000000000001)\n\n<table><tr><td>raw</td></tr></table>\n\n| A | B |\n| --- | --- |\n| 1 | 2 |';
 const output=roundtrip(source);
 for(const text of ['# Heading','**bold**','*italic*','[ ] todo','[x] done','array-task-image://00000000-0000-0000-0000-000000000001','<table><tr><td>raw</td></tr></table>','| A | B |']) assert.ok(output.includes(text),output);
 assert.equal(roundtrip(output), output);
});
