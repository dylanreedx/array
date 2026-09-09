import {build} from 'esbuild';
import {mkdir,copyFile,writeFile} from 'node:fs/promises';
const out = new URL('../../Sources/ContinuumRevived/Resources/TaskEditor/', import.meta.url);
await mkdir(out, {recursive:true});
await build({entryPoints:[new URL('src/editor.js',import.meta.url).pathname],bundle:true,format:'iife',platform:'browser',target:'safari17',minify:true,legalComments:'external',outfile:new URL('editor.js',out).pathname});
for (const name of ['index.html','editor.css']) await copyFile(new URL('src/'+name,import.meta.url),new URL(name,out));
await writeFile(new URL('ASSET_VERSION',out),'1\n');
