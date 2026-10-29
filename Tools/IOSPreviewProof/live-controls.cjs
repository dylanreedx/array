// Real UIKit state readback for a rotate-and-restore cycle on the owned device.
const fs = require('node:fs');
const path = require('node:path');
const [origin, device, statePath, output, wsPackage] = process.argv.slice(2);
const { WebSocket } = require(path.resolve(wsPackage));
const read = () => JSON.parse(fs.readFileSync(statePath, 'utf8'));
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const socket = new WebSocket(origin.replace('http:', 'ws:') + '/helper/ws?device=' + device);
const timeout = setTimeout(() => { socket.terminate(); process.exit(2); }, 15000);
socket.once('message', async data => {
  try {
    if (data[0] !== 0x83) throw Error('input not admitted');
    const initial = read();
    function orientation(value) {
      socket.send(Buffer.concat([Buffer.from([7]), Buffer.from(JSON.stringify({orientation:value}))]));
    }
    orientation(3);
    for (let i = 0; i < 50 && read().width < read().height; i++) await delay(100);
    const landscape = read();
    orientation(1);
    for (let i = 0; i < 50 && read().width > read().height; i++) await delay(100);
    const restored = read();
    const pass = landscape.width > landscape.height && restored.width < restored.height;
    fs.writeFileSync(path.join(output, 'orientation-report.json'), JSON.stringify({device, initial, landscape, restored, pass}, null, 2));
    if (!pass) throw Error('real app did not rotate and restore');
    console.log('PASS: real UIKit app rotates to landscape and returns to portrait');
    socket.close();
  } catch (error) {
    console.error(error); socket.terminate(); process.exitCode = 1;
  } finally { clearTimeout(timeout); }
});
