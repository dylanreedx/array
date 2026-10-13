import fs from 'node:fs';
import path from 'node:path';
import Module from 'node:module';
process.env.NODE_PATH = '/Users/dylan/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules';
Module._initPaths();
const require = Module.createRequire(import.meta.url);
const { chromium } = require('playwright');
const sharp = require('sharp');

// Social campaign artwork from verified DesignTokens.swift colors and captured
// app pixels. This renderer writes reviewable HTML/CSS sources beside each PNG.
const root = path.resolve(import.meta.dirname, '..');
const outRoot = path.join(root, 'brand/out');
const screenshotPath = path.join(root, '.plans/68-launch-film/hero-loop-r3/stills/hero-loop-loop-bar5.3-f270.png');
const captured = await sharp(fs.readFileSync(screenshotPath)).extract({left:60,top:225,width:1335,height:530}).png().toBuffer();
const screenshotData = `data:image/png;base64,${captured.toString('base64')}`;
const directions = [
  { id:'01-infinite', name:'Infinite field', copies:8, surface:'#0B0D10', panel:'#14171C', chrome:'#1C212A', ink:'#F2F4F8', muted:'#AFB6C2', accent:'#4CD6B4', accent2:'#5FA8FF', line:'#2E343E', mode:'dark', number:'01', deck:'A workspace with no edges.', stamp:'INFINITE FIELD', caption:'Keep every agent in view.' },
  { id:'02-work-in-view', name:'Work in view', copies:4, surface:'#E9EBEF', panel:'#F5F6F9', chrome:'#F1F3F6', ink:'#14171C', muted:'#54585F', accent:'#1257C7', accent2:'#096B57', line:'#DDE0E6', mode:'light', number:'02', deck:'Every moving part, in one place.', stamp:'WORK IN VIEW', caption:'More work. Less hidden state.' },
  { id:'03-less-hidden', name:'Less hidden', copies:6, surface:'#101318', panel:'#1A1F28', chrome:'#232935', ink:'#F2F4F8', muted:'#AFB6C2', accent:'#FFB347', accent2:'#C08CFF', line:'#2E343E', mode:'dark', number:'03', deck:'More work. Less hidden state.', stamp:'LESS HIDDEN', caption:'One native workspace.' }
];

const sizes = [
  ['og',1200,630], ['linkedin-landscape',1200,627],
  ['linkedin-portrait',1080,1350], ['x',1600,900]
];

function esc(v) { return String(v).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;'); }
function mark(color, side=180, copies=8) {
  const bars = Array.from({length:copies},(_,i)=>{
    const gap = 20 + i*17, width = Math.max(3.5, 9-i*.72), opacity = Math.max(.12, .85-i*.095);
    return `<path d="M ${260-gap} 166 L ${310-gap} 46" stroke="${color}" stroke-width="${width}" opacity="${opacity}" stroke-linecap="round"/>`;
  }).join('');
  return `<svg viewBox="0 0 300 230" width="${side}" height="${side*230/300}" aria-label="Array infinite mark"><g fill="none" stroke-linejoin="round" stroke-linecap="round">${bars}<path d="M152 166 205 40 258 166 M174 117 H236" stroke="${color}" stroke-width="12"/></g></svg>`;
}
function style(d, w, h) {
  return `
    *{box-sizing:border-box} html,body{margin:0;width:${w}px;height:${h}px;overflow:hidden}
    body{font-family:system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:${d.surface};color:${d.ink};}
    .art{position:relative;width:${w}px;height:${h}px;overflow:hidden;background:${d.surface};}
    .grain{position:absolute;inset:0;opacity:.1;pointer-events:none;background-image:url("data:image/svg+xml,%3Csvg viewBox='0 0 180 180' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='.74' numOctaves='2' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)' opacity='.2'/%3E%3C/svg%3E");mix-blend-mode:soft-light}
    .edge{position:absolute;left:0;top:0;width:11px;height:100%;background:${d.accent};opacity:.9}
    .top{position:absolute;left:66px;right:66px;top:46px;display:flex;align-items:center;justify-content:space-between;font-size:18px;font-weight:650;letter-spacing:-.02em}
    .brand{display:flex;align-items:center;gap:14px}.brand svg{width:46px;height:36px}.word{font-size:26px;font-weight:680;letter-spacing:-.045em}
    .pill{color:${d.muted};font-size:13px;letter-spacing:.14em;text-transform:uppercase}
    .hero{position:absolute;left:70px;top:142px;width:${w*.40}px;z-index:2}
    .kicker{color:${d.accent};font:600 13px/1.2 ui-monospace,"SF Mono",monospace;letter-spacing:.13em;text-transform:uppercase}
    h1{margin:19px 0 16px;font-size:${w>1300?57:47}px;line-height:.98;letter-spacing:-.055em;font-weight:650;max-width:560px}
    .deck{font-size:19px;line-height:1.35;color:${d.muted};max-width:440px;letter-spacing:-.015em}
    .capture{position:absolute;right:54px;top:152px;width:${w*.51}px;height:${h*.42}px;border-radius:18px;background:${d.panel};padding:10px;border:1px solid ${d.line};box-shadow:0 28px 80px #0003;overflow:hidden;}
    .capture img{width:100%;height:100%;object-fit:contain;object-position:center;border-radius:10px;display:block}
    .caption{position:absolute;left:70px;bottom:42px;display:flex;align-items:center;gap:12px;color:${d.muted};font-size:14px}.dot{width:7px;height:7px;border-radius:50%;background:${d.accent}}
    .foot{position:absolute;right:68px;bottom:40px;color:${d.muted};font:12px ui-monospace,"SF Mono",monospace;letter-spacing:.08em}
    .trail{position:absolute;right:-60px;bottom:-120px;color:${d.accent};opacity:.12;transform:scale(3.5);transform-origin:bottom right;pointer-events:none}
    .vertical .hero{top:170px;width:850px}.vertical h1{font-size:84px;max-width:850px}.vertical .deck{font-size:25px;max-width:720px}
    .vertical .capture{left:66px;right:66px;top:510px;width:auto;height:610px}.vertical .caption{bottom:54px}.vertical .foot{bottom:52px}
    .wide .hero{top:155px}.wide h1{font-size:52px}
    .editorial .top{left:70px;right:70px;top:30px}.editorial .pill{display:none}.editorial .brand svg{width:34px;height:26px}.editorial .word{font-size:21px}
    .editorial-title{position:absolute;left:70px;right:70px;top:100px;text-align:center;z-index:2}.editorial-title .kicker{font-size:12px}.editorial-title h1{font-size:66px;line-height:.98;letter-spacing:-.06em;margin:12px 0 9px}.editorial-title p{margin:0;color:${d.muted};font-size:16px}
    .editorial .capture{left:50%;right:auto;top:230px;transform:translateX(-50%);width:92%;height:350px;z-index:2}
    .editorial .caption{left:50%;transform:translateX(-50%);bottom:20px;white-space:nowrap}.editorial .foot{display:none}.editorial .trail{right:-115px;bottom:-145px;opacity:.08;transform:scale(3.1)}
    .editorial.vertical .top{top:44px}.editorial.vertical .editorial-title{top:150px;left:54px;right:54px}.editorial.vertical .editorial-title h1{font-size:88px}.editorial.vertical .editorial-title p{font-size:22px;max-width:760px;margin:0 auto}.editorial.vertical .capture{top:650px;width:90%;height:570px}.editorial.vertical .caption{bottom:54px}.editorial.vertical .foot{display:block;right:54px;bottom:52px}
    .kinetic-trail{position:absolute;z-index:1;right:-115px;top:15px;width:58%;height:115%;transform:rotate(8deg);opacity:.24;pointer-events:none}
    .kinetic .top{left:66px;right:66px;top:42px}.kinetic .pill{color:${d.accent};font-weight:700}
    .kinetic-title{position:absolute;z-index:2;left:68px;top:174px;width:37%;}.kinetic-title .kicker{font-size:14px}.kinetic-title h1{font-size:92px;line-height:.83;letter-spacing:-.075em;margin:17px 0 12px}.kinetic-title h2{font-size:58px;line-height:.92;letter-spacing:-.06em;color:${d.accent};margin:0}.kinetic .capture{z-index:2;right:58px;top:214px;width:54%;height:300px;border:2px solid ${d.accent};padding:7px;border-radius:4px;box-shadow:16px 16px 0 ${d.accent}30}.kinetic .capture img{border-radius:0}
    .kinetic .caption{z-index:3}.kinetic .foot{z-index:3}
    .kinetic.vertical .top{top:44px}.kinetic.vertical .kinetic-title{top:175px;left:58px;width:900px}.kinetic.vertical .kinetic-title h1{font-size:132px;display:inline-block;margin-right:20px}.kinetic.vertical .kinetic-title h2{display:inline-block;font-size:80px;max-width:400px;vertical-align:top;margin-top:10px}.kinetic.vertical .capture{top:660px;left:58px;right:58px;width:auto;height:460px}.kinetic.vertical .kinetic-trail{width:62%;height:76%;right:-80px;top:320px;opacity:.22}.kinetic.vertical .caption{bottom:54px}.kinetic.vertical .foot{right:58px;bottom:52px}
    .mockup .top{top:54px;left:120px;right:120px}.mockup .mock-title{position:absolute;left:125px;top:150px;font-size:36px;font-weight:640;letter-spacing:-.05em}.mockup .capture{left:50%;right:auto;top:235px;transform:translateX(-50%);width:84%;height:560px}.mockup .capture img{object-fit:contain}.mockup .caption{left:125px;bottom:54px}.mockup .foot{right:125px;bottom:52px}
  `;
}
function shell(d, w, h, inner, klass='', backdrop='') {
 return `<!doctype html><html><head><meta charset="utf-8"><style>${style(d,w,h)}</style></head><body><main class="art ${klass}"><div class="edge"></div><div class="grain"></div><div class="trail">${mark(d.accent,170,d.copies)}</div>${backdrop}<header class="top"><div class="brand">${mark(d.accent,46,d.copies)}<span class="word">array</span></div><span class="pill">${esc(d.stamp)}</span></header>${inner}<div class="caption"><i class="dot"></i><span>${esc(d.caption)}</span></div><div class="foot">ARRAY · MACOS WORKSPACE</div></main></body></html>`;
}
function comp(d,w,h) {
 const vertical = h>w;
 const capture = `<figure class="capture"><img src="${screenshotData}" alt="Captured Array workspace"></figure>`;
 const base = `${vertical?'vertical':''} ${w>h?'wide':''}`;
 if (d.id==='02-work-in-view') {
   const inner=`<section class="editorial-title"><div class="kicker">A NATIVE WORKSPACE FOR PARALLEL WORK</div><h1>Keep every agent in view.</h1><p>Launch agents and tools from anywhere.</p></section>${capture}`;
   return shell(d,w,h,inner,`${base} editorial`);
 }
 if (d.id==='03-less-hidden') {
   const inner=`<section class="kinetic-title"><div class="kicker">03 / LESS HIDDEN</div><h1>More<br>work.</h1><h2>Less hidden<br>state.</h2></section>${capture}`;
   const slashSvg=`<svg viewBox="0 0 900 1200" preserveAspectRatio="xMidYMid slice" aria-hidden="true">${Array.from({length:14},(_,i)=>`<path d="M ${760-i*48} 1240 L ${1080-i*48} -40" stroke="${d.accent}" stroke-width="34" stroke-linecap="square" opacity="${Math.max(.12,.78-i*.047)}"/>`).join('')}</svg>`;
   return shell(d,w,h,inner,`${base} kinetic`,`<div class="kinetic-trail">${slashSvg}</div>`);
 }
 const title = vertical ? 'Keep every<br>agent in view.' : 'Keep every<br>agent in view.';
 const inner = `<section class="hero"><div class="kicker">01 / INFINITE FIELD</div><h1>${title}</h1><div class="deck">${esc(d.deck)}</div></section>${capture}`;
 return shell(d,w,h,inner,`${base}`);
}
function appMockup(d,w=1600,h=900) {
 const inner=`<div class="mock-title">A captured Array workspace</div><figure class="capture"><img src="${screenshotData}" alt="Real captured Array workspace"></figure>`;
 return shell(d,w,h,inner,'mockup');
}
function flow(d,w,h) {
 const vertical=h>w;
 const isLight=d.mode==='light';
 const panel = isLight?'#FFFFFF':d.panel;
 const muted=d.muted;
 const nodes = `<div class="flowhead"><span>01</span><strong>Project zone</strong><small>One focused workspace</small></div><div class="agents"><div class="agent"><b>◎</b><span>Agent</span><small>Working</small></div><div class="agent"><b>⌘</b><span>Agent</span><small>Ready</small></div><div class="agent"><b>⌁</b><span>Tools</span><small>In view</small></div></div><div class="connector"><i></i><span>work stays visible</span><i></i></div><div class="approval"><div class="approvaltop"><span>02 / YOUR REVIEW</span><span class="status">● NEEDS A DECISION</span></div><strong>Review the change</strong><p>A clear approval point, with the work around it.</p><div class="actions"><span>Review</span><span class="approve">Approve</span></div></div>`;
 const css = `<style>
 .flow-title{position:absolute;left:70px;top:112px;width:${vertical?'850px':'970px'};display:flex;align-items:flex-end;justify-content:space-between;gap:28px}.flow-title h1{font-size:${vertical?'74px':'43px'};line-height:1;max-width:${vertical?'800px':'500px'};margin:10px 0 0}.flow-title .deck{font-size:${vertical?'23px':'15px'};max-width:${vertical?'700px':'390px'};margin-bottom:3px}
 .diagram{position:absolute;left:${vertical?62:70}px;top:${vertical?505:280}px;width:${vertical?w-124:w-140}px;height:${vertical?730:300}px;border:1px solid ${d.line};border-radius:22px;background:${panel};padding:24px;display:flex;flex-direction:${vertical?'column':'row'};align-items:center;justify-content:space-between;gap:14px;box-shadow:0 26px 60px #0002}
 .flowhead{display:flex;flex-direction:column;gap:8px;min-width:120px}.flowhead span,.approvaltop{font:600 12px ui-monospace,"SF Mono",monospace;letter-spacing:.1em;color:${d.accent}}.flowhead strong{font-size:22px;letter-spacing:-.04em}.flowhead small,.agent small{font-size:12px;color:${muted}}
 .agents{display:flex;gap:10px}.agent{width:${vertical?'190px':'118px'};height:118px;border-radius:14px;background:${d.surface};border:1px solid ${d.line};display:flex;flex-direction:column;align-items:flex-start;justify-content:center;padding:14px;gap:5px}.agent b{font-size:23px;color:${d.accent2}}.agent span{font-weight:620;font-size:15px}
 .connector{display:flex;align-items:center;gap:8px;color:${muted};font:10px ui-monospace,"SF Mono",monospace;white-space:nowrap}.connector i{display:block;width:12px;height:1px;background:${d.accent}}
 .approval{align-self:stretch;min-width:${vertical?'100%':'250px'};border-radius:16px;padding:18px;background:${d.surface};border:1px solid ${d.line};display:flex;flex-direction:column;justify-content:center;gap:11px}.approvaltop{display:flex;justify-content:space-between;font-size:10px}.status{color:${d.mode==='light'?'#845000':'#FFB347'}}.approval strong{font-size:23px;letter-spacing:-.04em}.approval p{color:${muted};font-size:13px;line-height:1.4;margin:0}.actions{display:flex;gap:10px;margin-top:6px}.actions span{padding:10px 14px;border:1px solid ${d.line};border-radius:8px;color:${muted};font-size:12px}.actions .approve{background:${d.accent};border-color:${d.accent};color:${d.mode==='light'?'#FFFFFF':'#0B0D10'};font-weight:650}
 </style>`;
 const inner=`${css}<section class="flow-title"><div><div class="kicker">ZONE → AGENT → APPROVAL</div><h1>${vertical?'Work has a place.<br>Decisions have a path.':'Zone to agent. Agent to approval.'}</h1></div><div class="deck">A project zone keeps parallel work together. Review stays visible when an agent needs you.</div></section><div class="diagram">${nodes}</div>`;
 return shell(d,w,h,inner,`${vertical?'vertical':''} ${w>h?'wide':''}`);
}

await fs.promises.mkdir(outRoot,{recursive:true});
const browser=await chromium.launch({headless:true});
for (const d of directions) {
 const dir=path.join(outRoot,d.id); await fs.promises.mkdir(dir,{recursive:true});
 const logoSvg=`<svg xmlns="http://www.w3.org/2000/svg" width="300" height="230" viewBox="0 0 300 230">${mark(d.accent,300,d.copies)}</svg>`;
 await fs.promises.writeFile(path.join(dir,'mark.svg'),logoSvg);
 await fs.promises.writeFile(path.join(dir,'lockup.svg'),`<svg xmlns="http://www.w3.org/2000/svg" width="440" height="104" viewBox="0 0 440 104">${mark(d.accent,110,d.copies)}<text x="132" y="70" font-family="system-ui,-apple-system,sans-serif" font-size="66" font-weight="650" letter-spacing="-4" fill="${d.ink}">array</text></svg>`);
 for (const [base,w,h] of sizes) {
   const page=await browser.newPage({viewport:{width:w,height:h},deviceScaleFactor:2});
   const html=comp(d,w,h);
   await fs.promises.writeFile(path.join(dir,`${base}.html`),html);
   await page.setContent(html,{waitUntil:'load'}); await page.evaluate(()=>document.fonts.ready);
   const raw=await page.screenshot({type:'png'});
   await sharp(raw).resize(w,h,{kernel:'lanczos3'}).png().toFile(path.join(dir,`${base}.png`));
   await page.close();
 }
 const mockW=1600,mockH=900,mockPage=await browser.newPage({viewport:{width:mockW,height:mockH},deviceScaleFactor:2});
 const mockHtml=appMockup(d,mockW,mockH);
 await fs.promises.writeFile(path.join(dir,'app-mockup.html'),mockHtml);
 await mockPage.setContent(mockHtml,{waitUntil:'load'}); await mockPage.evaluate(()=>document.fonts.ready);
 await sharp(await mockPage.screenshot({type:'png'})).resize(mockW,mockH,{kernel:'lanczos3'}).png().toFile(path.join(dir,'app-mockup.png'));
 await mockPage.close();
 const fw=1200,fh=630,page=await browser.newPage({viewport:{width:fw,height:fh},deviceScaleFactor:2});
 const html=flow(d,fw,fh); await fs.promises.writeFile(path.join(dir,'flow-zone-agent-approval.html'),html);
 await page.setContent(html,{waitUntil:'load'}); await page.evaluate(()=>document.fonts.ready);
 await sharp(await page.screenshot({type:'png'})).resize(fw,fh,{kernel:'lanczos3'}).png().toFile(path.join(dir,'flow-zone-agent-approval.png'));
 await page.close();
}
await browser.close();
const cards=directions.map(d=>`<article style="--bg:${d.surface};--ink:${d.ink};--muted:${d.muted};--accent:${d.accent};--line:${d.line}"><header><img class="mark" src="out/${d.id}/mark.svg"><div><h2>${esc(d.name)}</h2><p>${esc(d.deck)}</p></div><span>${d.copies} trail copies</span></header><figure class="hero"><img src="out/${d.id}/og.png" alt="${esc(d.name)} open graph composition"></figure><div class="grid"><figure><figcaption>App mockup · real capture</figcaption><img src="out/${d.id}/app-mockup.png" alt="Captured app mockup"></figure><figure><figcaption>Zone → agent → approval</figcaption><img src="out/${d.id}/flow-zone-agent-approval.png" alt="Workflow illustration"></figure><figure><figcaption>LinkedIn portrait</figcaption><img src="out/${d.id}/linkedin-portrait.png" alt="Portrait social composition"></figure></div><div class="chips"><img src="out/${d.id}/linkedin-landscape.png" alt="LinkedIn landscape"><img src="out/${d.id}/x.png" alt="X social composition"><img src="out/${d.id}/lockup.svg" alt="Array lockup"></div></article>`).join('');
const index=`<!doctype html><html><head><meta charset="utf-8"><title>Array brand directions</title><style>*{box-sizing:border-box}body{margin:0;background:#0b0d10;color:#f2f4f8;font:15px/1.45 system-ui,-apple-system,sans-serif}main{max-width:1440px;margin:auto;padding:48px 32px}h1{font-size:44px;letter-spacing:-.055em;margin:0 0 8px}main>p{color:#afb6c2;margin:0 0 38px}.cards{display:grid;gap:28px}article{background:var(--bg);color:var(--ink);border:1px solid var(--line);border-radius:18px;padding:24px}article header{display:flex;align-items:center;gap:18px;margin-bottom:20px}article header .mark{width:96px;height:74px;object-fit:contain}h2{margin:0;font-size:25px;letter-spacing:-.04em}article p{color:var(--muted);margin:2px 0 0}article header>span{margin-left:auto;color:var(--accent);font:12px ui-monospace,monospace}.hero{margin:0 auto 18px;max-width:1100px}.hero img{width:100%;display:block;border-radius:10px}.grid{display:grid;grid-template-columns:1fr 1fr .52fr;gap:16px;align-items:start}.grid figure{margin:0}.grid figcaption{color:var(--muted);font-size:12px;margin:0 0 7px}.grid img{width:100%;display:block;border-radius:8px}.chips{display:flex;gap:12px;align-items:center;margin-top:16px;flex-wrap:wrap}.chips img{width:32%;border-radius:8px}.chips img:last-child{width:190px;max-height:58px;object-fit:contain}@media(max-width:760px){main{padding:20px 12px}.grid{grid-template-columns:1fr}.chips img{width:100%}article{padding:14px}}</style></head><body><main><h1>Array · brand directions</h1><p>Three layout systems built from the infinite-array mark, verified app colors, and one real captured workspace.</p><section class="cards">${cards}</section></main></body></html>`;
await fs.promises.writeFile(path.join(root,'brand/index.html'),index);
console.log(`Rendered ${directions.length} direction folders from ${screenshotPath}`);
