// A narrow, loopback-only adapter around the exact pinned native addon.
// No shell/exec route. Every operation is bound to one explicitly owned UDID.
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const [addonPath, device, output, wsPackage] = process.argv.slice(2);
if (!addonPath || !/^[0-9a-f-]{36}$/i.test(device || '') || !output || !wsPackage) {
  throw Error('usage: node live-backend.cjs ADDON UDID OUTPUT WS_PACKAGE');
}
const native = require(path.resolve(addonPath));
const { WebSocketServer } = require(path.resolve(wsPackage));
const capture = new native.SimCapture(device, 15, 0.8, 1400, 30, 3000000, 0);
const hid = new native.SimHID(device);
const viewers = new Set();
let latest, width = 0, height = 0, frames = 0, keyboard = false;
let inputQueue = Promise.resolve();
const events = [];
const errors = [];
function writePart(response, data) {
  if (response.destroyed || response.writableLength > 1024 * 1024) return;
  response.write(`--frame\r\nContent-Type: image/jpeg\r\nContent-Length: ${data.length}\r\n\r\n`);
  response.write(data);
  response.write('\r\n');
}
function stats() { return {device, width, height, frames, keyboard, events, errors, viewers: viewers.size}; }
function json(response, status, value) {
  response.writeHead(status, {'Content-Type': 'application/json'});
  response.end(JSON.stringify(value));
}
const server = http.createServer((request, response) => {
  const url = new URL(request.url, 'http://127.0.0.1');
  if (request.method !== 'GET') return json(response, 405, {error:'method'});
  if (url.pathname === '/stats') return json(response, 200, stats());
  if (url.pathname !== `/helper/${device}/stream.mjpeg`) return json(response, 404, {error:'route'});
  response.writeHead(200, {'Content-Type':'multipart/x-mixed-replace; boundary=frame', 'Cache-Control':'no-store'});
  viewers.add(response);
  if (latest) writePart(response, latest);
  response.on('close', () => viewers.delete(response));
});
const sockets = new WebSocketServer({noServer:true, maxPayload:4096});
server.on('upgrade', (request, socket, head) => {
  const url = new URL(request.url, 'http://127.0.0.1');
  if (url.pathname !== '/helper/ws' || url.searchParams.get('device') !== device) return socket.destroy();
  sockets.handleUpgrade(request, socket, head, ws => sockets.emit('connection', ws));
});
sockets.on('connection', socket => {
  socket.send(Buffer.from([0x83]));
  socket.on('message', (data, binary) => {
    if (!binary || data.length < 2) return;
    inputQueue = inputQueue.then(async () => {
      const payload = JSON.parse(data.subarray(1).toString());
      events.push({tag:data[0], ...payload});
      if (data[0] === 3) {
        if (!['begin','move','end'].includes(payload.type) || !Number.isFinite(payload.x) || !Number.isFinite(payload.y)) throw Error('invalid touch');
        await hid.touch(payload.type, payload.x, payload.y, width, height, 0);
      } else if (data[0] === 6) {
        if (!['down','up'].includes(payload.type) || !Number.isInteger(payload.usage)) throw Error('invalid key');
        await hid.key(payload.type, payload.usage);
      } else if (data[0] === 7) {
        await hid.orientation(payload.orientation);
      } else { throw Error('unsupported input tag'); }
    }).catch(error => errors.push(String(error)));
  });
});
let unsubscribe;
let closing = false;
async function stop() {
  if (closing) return;
  closing = true;
  fs.writeFileSync(path.join(output,'backend-stats.json'), JSON.stringify(stats(), null, 2));
  for (const response of viewers) response.destroy();
  for (const socket of sockets.clients) socket.terminate();
  if (unsubscribe) await unsubscribe();
  await capture.stop();
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 1000).unref();
}
for (const signal of ['SIGTERM','SIGINT']) process.on(signal, () => void stop());
(async () => {
  unsubscribe = await capture.subscribe(0, (data, w, h) => {
    latest = Buffer.from(data); width = w; height = h; frames++;
    for (const response of viewers) writePart(response, latest);
    if (frames === 1) fs.writeFileSync(path.join(output,'first-live.jpg'), latest);
  });
  await capture.start();
  // Xcode 26 single-screen devices can capture successfully without exposing
  // active-display metadata. Zero selects the sole profile panel in this API.
  keyboard = await hid.setScreen(0);
  server.listen(0, '127.0.0.1', () => {
    const origin = `http://127.0.0.1:${server.address().port}`;
    fs.writeFileSync(path.join(output,'live-origin.txt'), origin);
    console.log(JSON.stringify({origin, device, keyboard}));
  });
})().catch(error => { console.error(error); process.exit(1); });
