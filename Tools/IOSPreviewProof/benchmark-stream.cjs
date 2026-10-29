#!/usr/bin/env node
// Production bridge transport benchmark with a deterministic native stand-in.
// This measures transport/input queue costs, NOT CoreSimulator capture/encoding.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const {fork} = require('node:child_process');
const {performance} = require('node:perf_hooks');
const {createHash}=require('node:crypto');
const argv = process.argv.slice(2);
function option(name, fallback) { const i=argv.indexOf(name); return i<0?fallback:argv[i+1]; }
const wsPath = option('--ws-package', path.resolve('qa-runs/ios-preview-live/dependencies/node_modules/ws'));
const seconds = Number(option('--seconds', '6'));
const bytes = Number(option('--frame-bytes', '120000'));
const output = option('--out');
const bridgePath = option('--bridge', path.resolve('Sources/ContinuumRevived/Resources/IOSPreview/bridge.cjs'));
if (!Number.isFinite(seconds) || seconds<2 || seconds>60 || !Number.isInteger(bytes) || bytes<32 || bytes>4000000) throw Error('Invalid benchmark arguments');
const {WebSocket} = require(path.resolve(wsPath));
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'array-ios-bridge-benchmark-'));
const device='00000000-0000-4000-8000-000000000001';
const token='isolated-benchmark-'+process.pid;
const readyFile=path.join(temporary,'ready.json');
const now=()=>Number(process.hrtime.bigint())/1e6;
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const quantile=(values,p)=> { const sorted=[...values].sort((a,b)=>a-b); return sorted[Math.min(sorted.length-1,Math.floor(p*sorted.length))] ?? null; };
let child, stream, socket;
(async()=> {
  fs.writeFileSync(path.join(temporary,'native.cjs'), `
    let callback, timer, sequence=0;
    process.on('message',message=> {if(message.benchmarkSample)process.send({benchmarkSample:message.benchmarkSample,at:Number(process.hrtime.bigint())/1e6,cpu:process.cpuUsage(),memory:process.memoryUsage()});});
    class SimCapture {
      constructor(device,fps) { this.fps=fps; if(process.send)process.send({captureFPS:fps}); }
      async subscribe(screen, cb) { callback=cb; return async()=>clearInterval(timer); }
      async start() { timer=setInterval(()=>{const data=Buffer.alloc(${bytes});data.writeDoubleBE(Number(process.hrtime.bigint())/1e6,0);data.writeUInt32BE(++sequence,8);callback(data,644,1400);},1000/this.fps); }
      async stop() {clearInterval(timer);}
    }
    class SimHID {
      async setScreen(){return true;} async orientation(){return true;}
      async touch(type,x,y){if(process.send)process.send({touchAt:Number(process.hrtime.bigint())/1e6,type,x,y});}
      async key(){} async button(){}
    }
    module.exports={SimCapture,SimHID};
  `);
  const config={device,token,orientation:1,addon:path.join(temporary,'native.cjs'),ws:path.resolve(wsPath),readyFile};
  fs.writeFileSync(path.join(temporary,'config.json'),JSON.stringify(config));
  let captureFPS;
  const samples=new Map();
  const touchLatencies=[],touchSent=[];
  child=fork(bridgePath,[path.join(temporary,'config.json')],{silent:true});
  let errors=''; child.stderr.on('data',d=>errors+=d);
  child.on('message',m=> {
    if(m.captureFPS)captureFPS=m.captureFPS;
    if(m.benchmarkSample) {samples.get(m.benchmarkSample)?.(m);samples.delete(m.benchmarkSample);}
    if(m.touchAt) { const sent=touchSent.shift(); if(sent)touchLatencies.push(m.touchAt-sent); }
  });
  const readyDeadline=performance.now()+5000;
  while(!fs.existsSync(readyFile)) { if(child.exitCode!==null)throw Error(errors);if(performance.now()>readyDeadline)throw Error('Bridge readiness timed out');await sleep(10); }
  const {origin}=JSON.parse(fs.readFileSync(readyFile));
  let sampleID=0;
  function sample() {const id=++sampleID;return new Promise(resolve=>{samples.set(id,resolve);child.send({benchmarkSample:id});});}
  const startSample=await sample();
  let buffer=Buffer.alloc(0), pendingLength=null;
  const frameTimes=[],frameAges=[],sequences=[];
  const request = http.get(origin+`/helper/${device}/stream.mjpeg`,{headers:{authorization:`Bearer ${token}`}},response=> {
    stream=response;
    response.on('data',data=> {
      buffer=Buffer.concat([buffer,data]);
      while(true) {
        if(pendingLength===null) {
          const end=buffer.indexOf('\r\n\r\n'); if(end<0)break;
          const match=buffer.subarray(0,end).toString().match(/Content-Length: (\d+)/i);
          if(!match)throw Error('Malformed production stream');
          pendingLength=Number(match[1]);buffer=buffer.subarray(end+4);
        }
        if(buffer.length<pendingLength)break;
        const frame=buffer.subarray(0,pendingLength);buffer=buffer.subarray(pendingLength);pendingLength=null;
        frameTimes.push(now());frameAges.push(now()-frame.readDoubleBE(0));sequences.push(frame.readUInt32BE(8));
      }
    });
  });
  socket=new WebSocket(origin.replace('http:','ws:')+`/helper/ws?device=${device}`,{headers:{authorization:`Bearer ${token}`}});
  await new Promise((resolve,reject)=>{socket.once('open',resolve);socket.once('error',reject);});
  for(let i=0;i<40;i++) {
    touchSent.push(now());socket.send(Buffer.concat([Buffer.from([3]),Buffer.from(JSON.stringify({type:i===0?'begin':i===39?'end':'move',x:0.5,y:0.5}))]));
    await sleep(5);
  }
  await sleep(seconds*1000);
  const steadySample=await sample();
  // Intentionally stall application reads. This reveals whether queued frames
  // accumulate despite the bridge's writableLength guard. OS TCP buffers can
  // retain bytes even when the JavaScript write queue is empty.
  const beforeStall=frameTimes.length;
  stream.pause(); await sleep(1500); const resumedAt=now(); stream.resume(); await sleep(500);
  const stallAges=frameAges.slice(beforeStall);
  const intervals=frameTimes.slice(1,beforeStall).map((time,i)=>time-frameTimes[i]);
  const result={
    benchmark:'production bridge, synthetic native capture/HID',captureFPS,frameBytes:bytes,seconds,
    bridgeSHA256:createHash('sha256').update(fs.readFileSync(bridgePath)).digest('hex'),
    syntheticBridgeResourceUse:{cpuPercent:100*((steadySample.cpu.user-startSample.cpu.user)+(steadySample.cpu.system-startSample.cpu.system))/1000/(steadySample.at-startSample.at),rssBytes:steadySample.memory.rss,externalBytes:steadySample.memory.external},
    framesBeforeStall:beforeStall, observedFPS:intervals.length?1000/(intervals.reduce((a,b)=>a+b,0)/intervals.length):null,
    frameTransportAgeMs:{p50:quantile(frameAges.slice(0,beforeStall),.5),p95:quantile(frameAges.slice(0,beforeStall),.95),max:Math.max(...frameAges.slice(0,beforeStall))},
    inputDispatchMs:{count:touchLatencies.length,p50:quantile(touchLatencies,.5),p95:quantile(touchLatencies,.95),max:Math.max(...touchLatencies)},
    readerStall:{durationMs:1500,framesInFirst500msAfterResume:stallAges.length,oldestFrameAgeMs:Math.max(...stallAges),firstFrameArrivalAfterResumeMs:frameTimes[beforeStall]-resumedAt},
    bufferedParserBytes:buffer.length,
    limitations:['No real simulator capture or JPEG encode/decode measured','No AppKit main-thread presentation or human-input routing measured','Synthetic JPEG payload is binary timing data, intentionally not an image']
  };
  if(output) {fs.mkdirSync(path.dirname(path.resolve(output)),{recursive:true});fs.writeFileSync(output,JSON.stringify(result,null,2)+'\n');}
  console.log(JSON.stringify(result,null,2));
  request.destroy();
})().catch(error=>{console.error(error);process.exitCode=1;}).finally(async()=> {
  socket?.terminate();stream?.destroy();
  if(child&&child.exitCode===null) {child.kill('SIGTERM');await Promise.race([new Promise(resolve=>child.once('exit',resolve)),sleep(1500)]);if(child.exitCode===null)child.kill('SIGKILL');}
  fs.rmSync(temporary,{recursive:true,force:true});
});
