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
    end(){this.ended=true;}
    destroy(){this.destroyed=true;this.emit('close');}
  }
  const native={
    SimCapture:class{
      constructor(...args){captureArgs=args;}
      async subscribe(screen,callback){frame=callback;return async()=>calls.push(['unsubscribe']);}
      async start(){calls.push(['startCapture']);if(startGate)await startGate.promise;}
      async stop(){calls.push(['stopCapture']);}
    },
    SimHID:class{
      async setScreen(){return true;}
      async orientation(value){calls.push(['orientation',value]);return true;}
      async key(phase,usage){calls.push(['key',phase,usage,[...held]]);if(phase==='down')held.add(usage);else held.delete(usage);}
      async touch(phase,x,y){calls.push(['touch',phase,x,y]);if(phase==='begin'&&options.touchGate)await options.touchGate.promise;}
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
    setInterval:()=>({unref(){}}),setTimeout:(callback,ms)=>{timers.push({callback,ms});return {unref(){}};}
  },{filename:'production-bridge.cjs'});
  return {
    calls,held,writes,exits,timers,process:fakeProcess,
    get server(){return server;},get captureArgs(){return captureArgs;},get wss(){return wss;},
    frame:(bytes=Buffer.from([1,2,3]))=>frame(bytes,402,874),
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
  console.log('iOS preview bridge checks passed: authentication, route restriction, frame backpressure, frame-rate validation, controller ownership, modifier-safe Unicode paste, malformed/oversized socket errors, drag coalescing, disconnect input release, late-input fencing and finite startup/shutdown.');
})().catch(error=>{console.error(error);process.exitCode=1;});
