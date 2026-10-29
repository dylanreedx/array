#!/usr/bin/env node
// Executes the production bridge with deterministic built-in-only stand-ins.
// No Xcode, third-party packages, simulator, socket port or user state required.
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const {EventEmitter}=require('node:events');
const source=fs.readFileSync(process.argv[2]||path.join(__dirname,'../../Sources/ContinuumRevived/Resources/IOSPreview/bridge.cjs'),'utf8');
const device='11111111-1111-1111-1111-111111111111';
async function settle(test=()=>true){for(let i=0;i<80;i++){await new Promise(resolve=>setImmediate(resolve));if(test())return;}assert.fail('bridge operation did not settle');}
function deferred(){let resolve;return {promise:new Promise(r=>resolve=r),resolve:v=>resolve(v)};}
function harness(options={}){
  const calls=[],held=new Set(),writes=[],exits=[],timers=[];
  let server,wss,frame,captureArgs;
  const startGate=options.startGate;
  const fakeProcess=new EventEmitter();fakeProcess.argv=['node','bridge','config'];fakeProcess.ppid=42;fakeProcess.exit=code=>exits.push(code);
  class Server extends EventEmitter{
    listening=false;
    listen(port,host,callback){this.listening=true;calls.push(['listen',host]);callback();}
    address(){return {port:12345};}
    close(callback){this.listening=false;calls.push(['closeServer']);callback?.();}
  }
  class WSS extends EventEmitter{
    clients=new Set();
    constructor(config){super();this.options=config;wss=this;}
    handleUpgrade(request,socket,head,callback){callback(socket);}
  }
  class Socket extends EventEmitter{
    readyState=1;sent=[];
    send(data){this.sent.push(data);}
    close(code){if(this.readyState===3)return;this.closeCode=code;this.readyState=3;this.emit('close');}
    terminate(){this.close(1006);}
    destroy(){this.terminate();}
  }
  class Response extends EventEmitter{
    writableLength=0;destroyed=false;body=[];
    writeHead(status,headers){this.status=status;this.headers=headers;}
    write(data){this.body.push(data);return true;}
    end(data){if(data)this.body.push(data);this.ended=true;}
    destroy(){this.destroyed=true;this.emit('close');}
  }
  const native={
    SimCapture:class{
      constructor(...args){captureArgs=args;}
      async subscribe(screen,callback){frame=callback;return async()=>calls.push(['unsubscribe']);}
      async updateStreamSettings(...args){calls.push(['streamSettings',...args]);}
      async start(){calls.push(['startCapture']);if(startGate)await startGate.promise;}
      async stop(){calls.push(['stopCapture']);}
    },
    SimHID:class{
      async setScreen(){return true;}
      async orientation(value){calls.push(['orientation',value]);return true;}
      async key(phase,usage){calls.push(['key',phase,usage,[...held]]);if(phase==='down')held.add(usage);else held.delete(usage);if(phase==='down'&&options.failKeyDown)throw Error('native key down failed after effect');}
      async touch(phase,x,y){calls.push(['touch',phase,x,y]);if(phase==='end'&&options.endGate)await options.endGate.promise;if(phase==='end'&&options.failEnd)throw Error('native end failed');if(phase==='begin'&&options.touchGate)await options.touchGate.promise;}
      async button(value){calls.push(['button',value]);}
    }
  };
  const config={device,token:'test-token',orientation:1,addon:'test-native',ws:'test-ws',readyFile:'ready',...options.config};
  const dependencies={
    'node:fs':{readFileSync:()=>JSON.stringify(config),writeFileSync:(...args)=>writes.push(args),renameSync:(...args)=>writes.push(args)},
    'node:http':{createServer:handler=>{server=new Server();server.handler=handler;return server;}},
    'node:child_process':{spawn:(executable,args)=>{
      calls.push(['spawn',executable,args]);const child=new EventEmitter();child.stdin=new EventEmitter();
      child.stdin.end=text=>{calls.push(['clipboard',text]);queueMicrotask(()=>child.emit('exit',0));};return child;
    }},'test-native':native,'test-ws':{WebSocketServer:WSS}
  };
  vm.runInNewContext(source,{
    require:name=>{assert(name in dependencies,`unexpected dependency ${name}`);return dependencies[name];},
    process:fakeProcess,Buffer,console:{log(){},error(){}},
    setInterval:()=>({unref(){}}),setTimeout:(callback,ms)=>{const timer={callback,ms,cancelled:false,unref(){}};timers.push(timer);return timer;},clearTimeout:timer=>{timer.cancelled=true;}
  },{filename:'production-bridge.cjs'});
  return {
    calls,held,writes,exits,timers,process:fakeProcess,
    get server(){return server;},get captureArgs(){return captureArgs;},get wss(){return wss;},
    frame:(bytes=Buffer.from([1,2,3]),w=402,h=874)=>frame(bytes,w,h),
    connect(){const socket=new Socket();wss.clients.add(socket);socket.once('close',()=>wss.clients.delete(socket));wss.emit('connection',socket);return socket;},
    send(socket,tag,value){socket.emit('message',Buffer.concat([Buffer.from([tag]),Buffer.from(JSON.stringify(value))]),true);},
    request(headers={},url=`/helper/${device}/stream.mjpeg`,method='GET'){const response=new Response();server.handler({headers,url,method},response);return response;}
  };
}
(async()=>{
  if(process.argv.includes('--paste-only')){
    const legacy=harness();await settle(()=>legacy.server.listening);const client=legacy.connect();
    legacy.send(client,6,{type:'down',usage:227});await settle(()=>legacy.held.has(227));
    legacy.send(client,8,{text:'café 🧪'});await settle();
    legacy.send(client,6,{type:'down',usage:6});await settle(()=>legacy.held.has(6));
    const shortcut=legacy.calls.find(x=>x[0]==='key'&&x[1]==='down'&&x[2]===6);
    assert(shortcut[3].includes(227),'paste must preserve physically held Command for subsequent shortcuts');
    console.log('iOS preview held-Command paste check passed');return;
  }
  // Fresh observations wait for a native callback AFTER the HTTP request.
  const fresh=harness();await settle(()=>fresh.server.listening);fresh.frame(Buffer.from('old'));
  const auth={authorization:'Bearer test-token'},freshURL=`/helper/${device}/fresh.jpg`;
  assert.equal(fresh.request({},freshURL).status,403);
  const observation=fresh.request(auth,freshURL);
  assert(!observation.ended,'cached stream pixels cannot satisfy a fresh observation');
  assert.equal(fresh.request(auth,freshURL).status,429,'one pending observation bounds memory');
  fresh.frame(Buffer.from('new'));
  assert.equal(observation.status,200);assert.equal(observation.headers['Content-Type'],'image/jpeg');
  assert.equal(Buffer.concat(observation.body).toString(),'new');
  assert.equal(observation.headers['X-Array-Frame-Sequence'],'2');
  assert(Number(observation.headers['X-Array-Emission-Time-Ms'])>0);
  assert.equal(observation.headers['X-Array-Orientation'],'1');
  const abandonedFrame=fresh.request(auth,freshURL);abandonedFrame.destroy();
  const afterAbort=fresh.request(auth,freshURL);assert.notEqual(afterAbort.status,429,'cancelled reader must release snapshot demand');
  const timeout=fresh.timers.find(x=>x.ms===4500&&!x.cancelled);assert(timeout);timeout.callback();
  assert.equal(afterAbort.status,504,'missing native callback must have a finite deadline');
  const oversizedFrame=fresh.request(auth,freshURL);fresh.frame(Buffer.alloc(4*1024*1024+1));
  assert.equal(oversizedFrame.status,503,'oversized fresh image must not be returned');
  const pendingStop=fresh.request(auth,freshURL);fresh.process.emit('SIGTERM');
  assert(pendingStop.destroyed,'helper shutdown must close pending image readers');
  // Atomic agent tap: acknowledge only after the native end settles, never
  // replay duplicate/out-of-order IDs, and reject bad points before any HID.
  const tapGate=deferred(),endGate=deferred(),atomic=harness({touchGate:tapGate,endGate});
  await settle(()=>atomic.server.listening);atomic.frame();const agent=atomic.connect();
  atomic.send(agent,0x20,{requestID:1,kind:'tap',x:.25,y:.75});
  await settle(()=>atomic.calls.some(x=>x[0]==='touch'));
  assert(!agent.sent.some(x=>x[0]===0x84),'begin alone must never acknowledge a complete tap');
  tapGate.resolve();await settle(()=>atomic.calls.filter(x=>x[0]==='touch').length===2);
  assert(!agent.sent.some(x=>x[0]===0x84),'native end must settle before acknowledgement');
  endGate.resolve();await settle(()=>agent.sent.some(x=>x[0]===0x84));
  assert.deepEqual(JSON.parse(agent.sent.find(x=>x[0]===0x84).subarray(1)),{requestID:1,outcome:'native_sequence_completed'});
  assert.deepEqual(atomic.calls.filter(x=>x[0]==='touch').map(x=>x.slice(1)),[['begin',.25,.75],['end',.25,.75]]);
  atomic.send(agent,0x20,{requestID:1,kind:'tap',x:.25,y:.75});await settle();
  assert.equal(atomic.calls.filter(x=>x[0]==='touch').length,2,'duplicate IDs must cause zero additional HID');
  assert.equal(JSON.parse(agent.sent.at(-1).subarray(1)).outcome,'outcome_unknown','a duplicate cannot claim the original had no effect');
  for(const payload of [{requestID:2,kind:'tap',x:-.1,y:.5},{requestID:3,kind:'tap',x:.5,y:2},{requestID:4,kind:'shell',x:.5,y:.5},{requestID:5,kind:'tap',x:.5,y:.5,geometryGeneration:999}]){
    atomic.send(agent,0x20,payload);await settle();assert.equal(JSON.parse(agent.sent.at(-1).subarray(1)).outcome,'rejected');
  }
  assert.equal(atomic.calls.filter(x=>x[0]==='touch').length,2,'invalid actions must cause zero HID');
  atomic.send(agent,6,{type:'down',usage:225});await settle(()=>atomic.held.has(225));
  atomic.send(agent,0x20,{requestID:6,kind:'tap',x:.5,y:.5});await settle();
  assert.equal(JSON.parse(agent.sent.at(-1).subarray(1)).outcome,'rejected','human-held input blocks atomic automation');
  assert.equal(atomic.calls.filter(x=>x[0]==='touch').length,2);
  const queuedGate=deferred(),queued=harness({touchGate:queuedGate});await settle(()=>queued.server.listening);queued.frame();const leaving=queued.connect();
  queued.send(leaving,3,{type:'begin',x:0,y:0});
  queued.send(leaving,0x20,{requestID:1,kind:'tap',x:.7,y:.8});leaving.close(1000);queuedGate.resolve();
  await settle(()=>queued.calls.filter(x=>x[0]==='touch').length===2);
  assert.deepEqual(queued.calls.filter(x=>x[0]==='touch').map(x=>x[1]),['begin','end'],'closed controller discards queued automation and releases human contact');
  const geometryGate=deferred(),geometry=harness({touchGate:geometryGate});await settle(()=>geometry.server.listening);geometry.frame();const resizing=geometry.connect();
  geometry.send(resizing,3,{type:'begin',x:0,y:0});geometry.send(resizing,3,{type:'end',x:0,y:0});
  geometry.send(resizing,0x20,{requestID:1,kind:'tap',x:.5,y:.5,geometryGeneration:1});
  geometry.frame(Buffer.from('resized'),874,402);geometryGate.resolve();await settle();
  assert.equal(geometry.calls.filter(x=>x[0]==='touch').length,2,'geometry must be validated at execution after queued work, not just admission');
  assert.equal(JSON.parse(resizing.sent.at(-1).subarray(1)).outcome,'rejected');
  const noFrame=harness();await settle(()=>noFrame.server.listening);const early=noFrame.connect();
  noFrame.send(early,0x20,{requestID:1,kind:'tap',x:.5,y:.5});await settle();
  assert(!noFrame.calls.some(x=>x[0]==='touch'),'no native dimensions means no action');
  const failure=harness({failEnd:true});await settle(()=>failure.server.listening);failure.frame();const bad=failure.connect();
  failure.send(bad,0x20,{requestID:1,kind:'tap',x:.5,y:.5});await settle();
  assert.equal(JSON.parse(bad.sent.at(-1).subarray(1)).outcome,'outcome_unknown','partial native effect must never be reported as no effect');
  assert(!bad.sent.some(x=>x[0]===0x84));
  // Extended native vocabulary is intentionally not in the public catalog yet.
  const extended=harness();await settle(()=>extended.server.listening);extended.frame();const extendedClient=extended.connect();
  let requestID=0;
  for(const value of [{kind:'text',text:'café 🧪 漢字'},{kind:'key',key:'backspace'},{kind:'home'},{kind:'rotate',orientation:3}]){
    extended.send(extendedClient,0x20,{requestID:++requestID,...value});await settle(()=>extendedClient.sent.filter(x=>x[0]===0x84).length===requestID);
  }
  assert(extended.calls.some(x=>x[0]==='clipboard'&&x[1]==='café 🧪 漢字'));
  assert(extended.calls.some(x=>x[0]==='button'&&x[1]==='home'));
  assert.deepEqual(extended.calls.filter(x=>x[0]==='key'&&x[2]===42).map(x=>x[1]),['down','up']);
  assert.equal(extended.held.size,0);
  extended.send(extendedClient,0x21,{profile:'build_idle',generation:1});await settle(()=>extended.calls.some(x=>x[0]==='streamSettings'&&x[1]===1));
  assert.equal(JSON.parse(extendedClient.sent.at(-1).subarray(1)).frameRate,1,'hidden build profile must acknowledge native encoder rate');
  extended.send(extendedClient,0x21,{profile:'interactive',generation:2});await settle(()=>extended.calls.some(x=>x[0]==='streamSettings'&&x[1]===30));
  assert.equal(JSON.parse(extendedClient.sent.at(-1).subarray(1)).frameRate,30,'visible/end-build profile restores configured interactive rate');
  const beforeInvalid=extended.calls.length;
  for(const value of [{kind:'text',text:'x'.repeat(16385)},{kind:'key',key:'__proto__'},{kind:'rotate',orientation:0},{kind:'swipe',x:0,y:0,endX:1,endY:1,milliseconds:1501}]){
    extended.send(extendedClient,0x20,{requestID:++requestID,...value});await settle();
    assert.equal(JSON.parse(extendedClient.sent.at(-1).subarray(1)).outcome,'rejected');
  }
  assert.equal(extended.calls.length,beforeInvalid,'invalid extended actions cause no native input');
  const partialKey=harness({failKeyDown:true});await settle(()=>partialKey.server.listening);partialKey.frame();const partialKeyClient=partialKey.connect();
  partialKey.send(partialKeyClient,0x20,{requestID:1,kind:'key',key:'backspace'});await settle();
  assert.equal(partialKey.held.size,0,'ambiguous native key down must attempt key up before helper termination');
  assert.equal(JSON.parse(partialKeyClient.sent.find(x=>x[0]===0x91).subarray(1)).outcome,'outcome_unknown');
  const swipe=harness();await settle(()=>swipe.server.listening);swipe.frame();const swipeClient=swipe.connect();
  swipe.send(swipeClient,0x20,{requestID:1,kind:'swipe',x:.1,y:.2,endX:.9,endY:.8,milliseconds:100});
  for(let step=0;step<4;step++){
    await settle(()=>swipe.timers.some(x=>x.ms===25&&!x.cancelled&&!x.fired));
    const timer=swipe.timers.find(x=>x.ms===25&&!x.cancelled&&!x.fired);timer.fired=true;timer.callback();
  }
  await settle(()=>swipeClient.sent.some(x=>x[0]===0x84));
  const path=swipe.calls.filter(x=>x[0]==='touch');
  assert.deepEqual(path.map(x=>x[1]),['begin','move','move','move','move','end']);
  assert(Math.abs(path.at(-1)[2]-.9)<1e-10&&Math.abs(path.at(-1)[3]-.8)<1e-10);
  const cancelled=harness();await settle(()=>cancelled.server.listening);cancelled.frame();const cancelledClient=cancelled.connect();
  cancelled.send(cancelledClient,0x20,{requestID:1,kind:'swipe',x:.1,y:.2,endX:.9,endY:.8,milliseconds:100});
  await settle(()=>cancelled.timers.some(x=>x.ms===25));cancelledClient.close(1000);
  cancelled.timers.find(x=>x.ms===25).callback();await settle(()=>cancelled.calls.some(x=>x[0]==='touch'&&x[1]==='end'));
  assert.deepEqual(cancelled.calls.filter(x=>x[0]==='touch').map(x=>x[1]),['begin','end'],'cancelled swipe releases contact without continuing the path');
  assert(!cancelledClient.sent.some(x=>x[0]===0x84),'cancelled gesture must not claim complete');
  console.log('PASS: internal bounded swipe/text/key/Home/rotation; validation, native completion and mid-swipe controller-loss release');
  const h=harness();await settle(()=>h.server.listening);
  assert.equal(h.captureArgs[1],30,'default capture rate is the measured balanced profile');
  for(const fps of [15,30,60]){const x=harness({config:{frameRate:fps}});await settle(()=>x.server.listening);assert.equal(x.captureArgs[1],fps);}
  assert.throws(()=>harness({config:{frameRate:120}}),/Invalid preview frame rate/);
  assert.equal(h.request().status,403);
  assert.equal(h.request({authorization:'Bearer wrong'}).status,403);
  assert.equal(h.request({authorization:'Bearer test-token',origin:'http://localhost'}).status,403);
  assert.equal(h.request({authorization:'Bearer test-token'},'/shell').status,404);
  const response=h.request({authorization:'Bearer test-token'});h.frame();assert.equal(response.status,200);assert.equal(response.body.length,3);
  response.writableLength=512*1024+1;h.frame();assert.equal(response.body.length,3,'backpressured viewers must drop frames');
  const socket=h.connect();assert.equal(socket.sent[0][0],0x83);
  const extra=h.connect();assert.equal(extra.closeCode,1008,'one helper has one input controller');
  h.send(socket,6,{type:'down',usage:227});await settle(()=>h.held.has(227));
  h.send(socket,8,{text:'café 🧪'});await settle(()=>h.calls.some(x=>x[0]==='clipboard'));await settle();
  h.send(socket,6,{type:'down',usage:6});await settle(()=>h.held.has(6));
  const commandC=h.calls.find(x=>x[0]==='key'&&x[1]==='down'&&x[2]===6);
  assert(commandC[3].includes(227),'paste must preserve physically held Command for subsequent shortcuts');
  h.send(socket,6,{type:'up',usage:227});h.send(socket,6,{type:'up',usage:6});h.send(socket,6,{type:'down',usage:225});await settle(()=>h.held.has(225));
  const before=h.calls.length;h.send(socket,8,{text:'plain text'});await settle();
  const pasteV=h.calls.slice(before).find(x=>x[0]==='key'&&x[1]==='down'&&x[2]===25);
  assert.deepEqual(pasteV[3],[227],'held Shift/Control/Option must not change paste semantics');
  assert(h.held.has(225),'paste restores original Shift');
  socket.close(1000);await settle(()=>h.held.size===0);
  const malformed=h.connect();malformed.emit('message',Buffer.from([6,123]),true);assert.equal(malformed.sent.at(-1)[0],0x91);
  // ws emits this event on oversized/bad protocol packets. The real 70KB probe
  // previously crashed Node; this exercises the same production event seam.
  assert.doesNotThrow(()=>malformed.emit('error',new RangeError('Max payload size exceeded')));
  assert.equal(malformed.readyState,3);await settle();assert.equal(h.request().status,403,'helper remains available after client protocol error');
  const gate=deferred(),moves=harness({touchGate:gate});await settle(()=>moves.server.listening);moves.frame();const drag=moves.connect();
  moves.send(drag,3,{type:'begin',x:0,y:0});
  for(let i=1;i<=100;i++)moves.send(drag,3,{type:'move',x:i/100,y:i/100});
  moves.send(drag,3,{type:'end',x:1,y:1});
  gate.resolve();await settle(()=>moves.calls.filter(x=>x[0]==='touch').length===3);
  assert.deepEqual(moves.calls.filter(x=>x[0]==='touch').map(x=>x.slice(1)),[['begin',0,0],['move',1,1],['end',1,1]],'coalesce only pending moves, preserving begin/latest/end');
  const closeGate=deferred(),closed=harness({touchGate:closeGate});await settle(()=>closed.server.listening);closed.frame();const abandoned=closed.connect();
  closed.send(abandoned,3,{type:'begin',x:.2,y:.3});closed.send(abandoned,6,{type:'down',usage:4});abandoned.close(1000);closeGate.resolve();
  await settle(()=>closed.calls.some(x=>x[0]==='touch'&&x[1]==='end'));
  assert(!closed.calls.some(x=>x[0]==='key'&&x[1]==='down'),'queued input from a closed client must be discarded');
  const startupGate=deferred(),stopping=harness({startGate:startupGate});await settle(()=>stopping.calls.some(x=>x[0]==='startCapture'));
  stopping.process.emit('SIGTERM');startupGate.resolve();await settle(()=>stopping.exits.length>0);
  assert(!stopping.calls.some(x=>x[0]==='listen'),'shutdown during startup must not publish a late listener');assert.equal(stopping.writes.length,0);
  const never=deferred(),hung=harness({touchGate:never});await settle(()=>hung.server.listening);const stuck=hung.connect();hung.send(stuck,3,{type:'begin',x:0,y:0});hung.process.emit('SIGTERM');
  const deadline=hung.timers.find(t=>t.ms<=1500);assert(deadline,'shutdown deadline must be armed before waiting on a stuck native call');deadline.callback();assert.deepEqual(hung.exits,[0]);
  console.log('iOS preview bridge checks passed: correlated atomic tap, deferred native end, duplicate rejection, invalid action/no-frame/held-input rejection, partial-effect uncertainty, authentication, route restriction, frame backpressure, frame-rate validation, controller ownership, modifier-safe Unicode paste, malformed/oversized socket errors, drag coalescing, disconnect input release, late-input fencing and finite startup/shutdown.');
})().catch(error=>{console.error(error);process.exitCode=1;});
