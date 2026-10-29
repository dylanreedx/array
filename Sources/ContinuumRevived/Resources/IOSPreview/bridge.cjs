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
let latest, width=0, height=0, unsubscribe, closing=false, controller, startup;
let pumping, contact;
const pending=[];
const keys=new Set();
const server = http.createServer((request,response) => {
  if (!authorized(request)) { response.writeHead(403); return response.end(); }
  if (closing || request.method!=='GET' || request.url!==`/helper/${config.device}/stream.mjpeg`) { response.writeHead(404); return response.end(); }
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
  await hid.key(phase,usage);
  if(phase==='down')keys.add(usage);else keys.delete(usage);
}
async function releaseInputs() {
  if(contact){const previous=contact;contact=null;await hid.touch('end',previous.x,previous.y,width,height,0);}
  for(const usage of [...keys])await key('up',usage);
}
async function paste(text) {
  if (typeof text!=='string' || Buffer.byteLength(text,'utf8')>60000) throw Error('Paste is too large');
  await new Promise((resolve,reject)=> {
    const child=spawn('/usr/bin/xcrun',['simctl','pbcopy',config.device],{stdio:['pipe','ignore','ignore']});
    child.once('error',reject);child.once('exit',code=>code===0?resolve():reject(Error('Simulator pasteboard failed')));
    child.stdin.on('error',reject);child.stdin.end(text);
  });
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
  } else if (p.tag===8) { await paste(p.value.text);
  } else throw Error('Unsupported input');
}
function pump() {
  if(pumping)return;
  pumping=(async()=>{
    while(pending.length){
      const job=pending.shift();
      try {
        if(job.cleanup){await releaseInputs();if(controller===job.socket)controller=undefined;continue;}
        if(closing||controller!==job.socket||job.socket.readyState!==1)continue;
        await input(job);
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
  socket.on('message',(data,binary)=> {
    if(closing||controller!==socket||socket.readyState!==1||!binary||data.length<2)return;
    let value;
    try { value=JSON.parse(data.subarray(1).toString());if(!value||typeof value!=='object'||Array.isArray(value))throw Error('Invalid input'); }
    catch { socket.send(Buffer.from([0x91]));return; }
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
    latest=Buffer.from(bytes);width=w;height=h;
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
