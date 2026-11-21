import {test} from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import net from 'node:net';
import {describeListeners} from '../server/discovery.mjs';
test('web discovery identifies HTTP apps and preserves other TCP listeners', async()=>{
 const web=http.createServer((req,res)=>{res.writeHead(404);res.end();});
 const tcp=net.createServer(socket=>socket.destroy());
 const listen=s=>new Promise(r=>s.listen(0,'127.0.0.1',()=>r(s.address().port)));
 const webPort=await listen(web),tcpPort=await listen(tcp);
 try {
  const apps=await describeListeners([{pid:process.pid,command:'node',port:tcpPort,projectPath:null},{pid:process.pid,command:'node',port:webPort,projectPath:'/projects/payment-ui'}]);
  assert.equal(apps[0].port,webPort);assert.equal(apps[0].isWeb,true);assert.equal(apps[0].displayName,'payment-ui');
  assert.equal(apps[1].isWeb,false);assert.equal(apps[0].url,`http://localhost:${webPort}`);
 } finally {await Promise.all([web,tcp].map(s=>new Promise(r=>s.close(r))));}
});
