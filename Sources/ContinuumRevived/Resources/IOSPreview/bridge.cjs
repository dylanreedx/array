// Array-owned local adapter. Upstream packages retain their own MIT/Apache
// notices in the verified installation directory. No general command endpoint.
const fs = require('node:fs');
const http = require('node:http');
const {spawn} = require('node:child_process');
const config = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (!/^[0-9a-f-]{36}$/i.test(config.device) || typeof config.token !== 'string' || ![1,2,3,4].includes(config.orientation)) throw Error('Invalid preview configuration');
const frameRate=config.frameRate===undefined?30:config.frameRate;
if(![15,30,60].includes(frameRate))throw Error('Invalid preview frame rate');
const native = require(config.addon);
const {WebSocketServer} = require(config.ws);
const capture = new native.SimCapture(config.device, frameRate, 0.8, 1400, 30, 3000000, 0);
const hid = new native.SimHID(config.device);
const viewers = new Set();
const observations = new Set();
let frameSequence=0, geometryGeneration=0, orientation=config.orientation;
let latest, width=0, height=0, unsubscribe, closing=false, controller, startup;
let pumping, contact, lastRequestID=0;
const pending=[];
const keys=new Set();
const server = http.createServer((request,response) => {
  if (!authorized(request)) { response.writeHead(403); return response.end(); }
  if (closing || request.method!=='GET') { response.writeHead(404); return response.end(); }
  if(request.url===`/helper/${config.device}/fresh.jpg`){
    if(observations.size){response.writeHead(429);return response.end();}
    const job={response};
    job.timer=setTimeout(()=>{
      if(observations.delete(job)){response.writeHead(504);response.end();}
    },4500);
    response.once('close',()=>{observations.delete(job);clearTimeout(job.timer);});
    observations.add(job);return;
  }
  if(request.url!==`/helper/${config.device}/stream.mjpeg`) { response.writeHead(404); return response.end(); }
  response.writeHead(200, {'Content-Type':'multipart/x-mixed-replace; boundary=frame','Cache-Control':'no-store'});
  viewers.add(response); if (latest) part(response,latest);
  response.once('close',()=>viewers.delete(response));
});
function authorized(request) {
  return !request.headers.origin && request.headers.authorization===`Bearer ${config.token}`;
}
function part(response,data) {
  if (response.destroyed || response.writableLength>512*1024) return;
  response.write(`--frame\r\nContent-Type: image/jpeg\r\nContent-Length: ${data.length}\r\n\r\n`);
  response.write(data); response.write('\r\n');
}
const sockets = new WebSocketServer({noServer:true,maxPayload:65536});
server.on('upgrade',(request,socket,head)=> {
  if (closing || !authorized(request) || request.url!==`/helper/ws?device=${config.device}`) return socket.destroy();
  sockets.handleUpgrade(request,socket,head,ws=>sockets.emit('connection',ws));
});
async function key(phase,usage) {
  // A failed native promise can still have pressed the key. Track down intent
  // before dispatch; remove it only after a confirmed up, so cleanup retries up.
  if(phase==='down')keys.add(usage);
  await hid.key(phase,usage);
  if(phase==='up')keys.delete(usage);
}
async function releaseInputs() {
  if(contact){const previous=contact;contact=null;await hid.touch('end',previous.x,previous.y,width,height,0);}
  for(const usage of [...keys])await key('up',usage);
}
async function paste(text,canContinue=()=>true) {
  if (typeof text!=='string' || Buffer.byteLength(text,'utf8')>60000) throw Error('Paste is too large');
  await new Promise((resolve,reject)=> {
    const child=spawn('/usr/bin/xcrun',['simctl','pbcopy',config.device],{stdio:['pipe','ignore','ignore']});
    child.once('error',reject);child.once('exit',code=>code===0?resolve():reject(Error('Simulator pasteboard failed')));
    child.stdin.on('error',reject);child.stdin.end(text);
  });
  if(!canContinue())throw Error('Paste controller released');
  const held=new Set(keys);
  // A host-held modifier must neither change plain paste semantics nor be
  // silently released by synthetic Command-V. Restore even on HID failure.
  try {
    for(const usage of [...keys])if((usage>=224&&usage<=231)||usage===25)await key('up',usage);
    await key('down',227);await key('down',25);await key('up',25);await key('up',227);
  } finally {
    for(const usage of [...keys])if(!held.has(usage))await key('up',usage);
    for(const usage of held)if(!keys.has(usage))await key('down',usage);
  }
}
async function input(p) {
  if (p.tag===3) {
    if (!['begin','move','end'].includes(p.value.type) || !Number.isFinite(p.value.x) || !Number.isFinite(p.value.y)) throw Error('Invalid touch');
    const x=Math.max(0,Math.min(1,p.value.x)),y=Math.max(0,Math.min(1,p.value.y));
    await hid.touch(p.value.type,x,y,width,height,0);
    contact=p.value.type==='end'?null:{x,y};
  } else if (p.tag===6) {
    if (!['down','up'].includes(p.value.type) || !Number.isInteger(p.value.usage) || p.value.usage<0 || p.value.usage>255) throw Error('Invalid key');
    await key(p.value.type,p.value.usage);
  } else if (p.tag===4 && p.value.button==='home') { await hid.button('home');
  } else if (p.tag===7 && [1,2,3,4].includes(p.value.orientation)) {
    if (!await hid.orientation(p.value.orientation)) throw Error('Rotation unavailable');
    orientation=p.value.orientation;geometryGeneration++;
  } else if (p.tag===0x21 && ['build_idle','interactive'].includes(p.value.profile) && Number.isSafeInteger(p.value.generation) && p.value.generation>0) {
    const rate=p.value.profile==='build_idle'?1:frameRate;
    await capture.updateStreamSettings(rate,0.8,1400,30,3000000);
    reply(p.socket,0x85,{profile:p.value.profile,frameRate:rate,generation:p.value.generation});
  } else if (p.tag===8) { await paste(p.value.text);
  } else throw Error('Unsupported input');
}
// Internal automation protocol used by the scoped host device API.
// IDs increase for this helper lifetime, giving bounded duplicate protection.
function reply(socket,tag,value){if(socket.readyState===1)socket.send(Buffer.concat([Buffer.from([tag]),Buffer.from(JSON.stringify(value))]));}
const actionKeys={return:40,tab:43,backspace:42,escape:41,left:80,right:79,up:82,down:81};
function validateAction(value){
  if(!Number.isSafeInteger(value.requestID)||value.requestID<=0)throw Error('Invalid request ID');
  if(value.requestID<=lastRequestID){const error=Error('Repeated request ID; original effect may have completed');error.outcome='outcome_unknown';throw error;}
  lastRequestID=value.requestID; // A rejected request cannot later become input.
  if(value.geometryGeneration!==undefined&&value.geometryGeneration!==geometryGeneration)throw Error('Stale observation geometry');
  const point=(x,y)=>Number.isFinite(x)&&Number.isFinite(y)&&x>=0&&x<=1&&y>=0&&y<=1;
  switch(value.kind){
    case 'tap':if(!point(value.x,value.y))throw Error('Invalid tap');break;
    case 'swipe':if(!point(value.x,value.y)||!point(value.endX,value.endY)||!Number.isInteger(value.milliseconds)||value.milliseconds<100||value.milliseconds>1500)throw Error('Invalid swipe');break;
    case 'text':if(typeof value.text!=='string'||!value.text.length||Buffer.byteLength(value.text,'utf8')>16384)throw Error('Invalid text');break;
    case 'key':if(!Object.hasOwn(actionKeys,value.key))throw Error('Unsupported key');break;
    case 'home':break;
    case 'rotate':if(![1,2,3,4].includes(value.orientation))throw Error('Invalid orientation');break;
    default:throw Error('Unsupported action');
  }
}
async function action(job){
  const {socket,value}=job;
  if(width<=0||height<=0||contact||keys.size||(value.geometryGeneration!==undefined&&value.geometryGeneration!==geometryGeneration)){reply(socket,0x91,{requestID:value.requestID,outcome:'rejected',error:'Device not ready or human input held'});return;}
  // From the first native invocation onward a failure can have a partial effect.
  // Never claim a rejected/no-effect result or replay after that boundary.
  try{
    if(value.kind==='tap'||value.kind==='swipe'){
      contact={x:value.x,y:value.y};
      await hid.touch('begin',value.x,value.y,width,height,0);
      if(value.kind==='swipe'){
        const steps=Math.ceil(value.milliseconds/25),generation=geometryGeneration;
        for(let step=1;step<=steps;step++){
          await new Promise(resolve=>setTimeout(resolve,value.milliseconds/steps));
          // Controller loss, takeover and rotation stop the remaining path.
          if(closing||controller!==socket||socket.readyState!==1||geometryGeneration!==generation)throw Error('Swipe interrupted');
          const fraction=step/steps;
          contact={x:value.x+(value.endX-value.x)*fraction,y:value.y+(value.endY-value.y)*fraction};
          await hid.touch('move',contact.x,contact.y,width,height,0);
        }
      }
      await releaseInputs();
    }else if(value.kind==='text'){await paste(value.text,()=>!closing&&controller===socket&&socket.readyState===1);
    }else if(value.kind==='key'){
      await key('down',actionKeys[value.key]);await key('up',actionKeys[value.key]);
    }else if(value.kind==='home'){await hid.button('home');
    }else if(value.kind==='rotate'){
      if(!await hid.orientation(value.orientation))throw Error('Rotation unavailable');
      orientation=value.orientation;geometryGeneration++;
    }
    if(!closing)reply(socket,0x84,{requestID:value.requestID,outcome:'native_sequence_completed'});
  }catch(error){
    try{await releaseInputs();}catch{}
    reply(socket,0x91,{requestID:value.requestID,outcome:'outcome_unknown',error:'Native action interrupted or failed'});
    // Failed native input may still be held. No subsequent job can inherit it.
    void stop();
  }
}
function pump() {
  if(pumping)return;
  pumping=(async()=>{
    while(pending.length){
      const job=pending.shift();
      try {
        if(job.cleanup){await releaseInputs();if(controller===job.socket)controller=undefined;continue;}
        if(closing||controller!==job.socket||job.socket.readyState!==1)continue;
        if(job.tag===0x20)await action(job);else await input(job);
      } catch(error) {
        if(!job.cleanup&&job.socket.readyState===1)job.socket.send(Buffer.concat([Buffer.from([0x91]),Buffer.from(JSON.stringify({error:String(error)}))]));
      }
    }
  })().finally(()=>{pumping=undefined;if(pending.length)pump();});
}
sockets.on('connection',socket=> {
  // ws emits protocol/payload errors on the individual socket. Always consume
  // them: a malformed client must not turn into a process-wide uncaught error.
  socket.on('error',()=>socket.terminate());
  if(closing||controller){socket.close(1008,'Preview already has an input controller');return;}
  controller=socket;
  socket.once('close',()=>{
    if(closing||controller!==socket)return;
    for(let i=pending.length-1;i>=0;i--)if(pending[i].socket===socket)pending.splice(i,1);
    pending.push({socket,cleanup:true});pump();
  });
  socket.send(Buffer.from([0x83]));
  reply(socket,0x85,{profile:'interactive',frameRate,generation:0});
  socket.on('message',(data,binary)=> {
    if(closing||controller!==socket||socket.readyState!==1||!binary||data.length<2)return;
    let value;
    try { value=JSON.parse(data.subarray(1).toString());if(!value||typeof value!=='object'||Array.isArray(value))throw Error('Invalid input'); }
    catch { socket.send(Buffer.from([0x91]));return; }
    if(data[0]===0x20){
      try{validateAction(value);}catch(error){reply(socket,0x91,{requestID:value.requestID,outcome:error.outcome||'rejected',error:String(error)});return;}
    }
    const job={socket,tag:data[0],value};
    const previous=pending[pending.length-1];
    // Only consecutive pending moves coalesce. Begin/end/key ordering stays
    // intact, while a blocked native call cannot accumulate old drag points.
    if(job.tag===3&&value.type==='move'&&previous?.socket===socket&&previous.tag===3&&previous.value.type==='move')pending[pending.length-1]=job;
    else {
      if(pending.length>=128){socket.close(1013,'Input fell behind');return;}
      pending.push(job);
    }
    pump();
  });
});
async function stop() {
  if (closing) return; closing=true;
  // Arm BEFORE waiting for native promises: the owner-death watchdog must also
  // exit when a simulator HID call never returns, without a living parent kill.
  setTimeout(()=>process.exit(0),1500).unref();
  pending.length=0;
  for(const job of observations){clearTimeout(job.timer);job.response.destroy();}observations.clear();
  for(const r of viewers)r.destroy();for(const s of sockets.clients)s.terminate();
  try {
    if(pumping)await pumping;
    await releaseInputs();
    await startup;
    if(unsubscribe)await unsubscribe();await capture.stop();
  } catch(error) { console.error('Preview cleanup failed:',String(error)); }
  server.close(()=>process.exit(0));
}
process.on('SIGTERM',()=>void stop());process.on('SIGINT',()=>void stop());
const ownerPID=process.ppid;
setInterval(()=>{if(process.ppid!==ownerPID)void stop();},1000).unref();
startup=(async()=> {
  unsubscribe=await capture.subscribe(0,(bytes,w,h)=> {
    if(closing)return;
    latest=Buffer.from(bytes);
    if(width!==w||height!==h)geometryGeneration++;
    width=w;height=h;frameSequence++;
    // This is helper emission time, never represented as native capture time.
    const emittedAt=Date.now();
    for(const job of observations){
      clearTimeout(job.timer);
      if(!latest.length||latest.length>4*1024*1024){job.response.writeHead(503);job.response.end();continue;}
      job.response.writeHead(200,{'Content-Type':'image/jpeg','Content-Length':String(latest.length),'Cache-Control':'no-store',
        'X-Array-Frame-Sequence':String(frameSequence),'X-Array-Emission-Time-Ms':String(emittedAt),
        'X-Array-Orientation':String(orientation),'X-Array-Geometry-Generation':String(geometryGeneration)});
      job.response.end(latest);
    }
    observations.clear();
    for(const r of viewers)part(r,latest);
  });
  if(closing)return;
  await capture.start();if(closing)return;
  const keyboard=await hid.setScreen(0);if(closing)return;
  // Apply orientation before admitting input, including already-rotated devices.
  if(!await hid.orientation(config.orientation))throw Error('Simulator orientation unavailable');
  if(closing)return;
  server.listen(0,'127.0.0.1',()=> {
    if(closing){server.close();return;}
    const ready=JSON.stringify({origin:`http://127.0.0.1:${server.address().port}`,keyboard});
    fs.writeFileSync(config.readyFile+'.tmp',ready,{mode:0o600});
    fs.renameSync(config.readyFile+'.tmp',config.readyFile);
    console.log(ready);
  });
})().catch(error=>{if(!closing){console.error(error);process.exit(1);}});
