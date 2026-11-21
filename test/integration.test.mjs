import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import net from 'node:net';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {WebSocket,WebSocketServer} from 'ws';
import {Client} from '@modelcontextprotocol/sdk/client/index.js';
import {StdioClientTransport} from '@modelcontextprotocol/sdk/client/stdio.js';
import {Registry,slug,discover} from '../server/core.mjs';
const listen = s=>new Promise(resolve=>s.listen(0,'127.0.0.1',()=>resolve(s.address().port)));
const sleep = ms=>new Promise(r=>setTimeout(r,ms));
test('targeted discovery shares pending scans, excludes other ports and refreshes after close',async()=>{
 const first=net.createServer(),second=net.createServer();
 const port=await listen(first),otherPort=await listen(second);
 try {
  const pending=discover(port);
  assert.equal(discover(port),pending);
  const fullScan=discover();assert.equal(discover(),fullScan);await fullScan;
  const listeners=await pending;
  assert(listeners.length>0);
  assert(listeners.every(p=>p.port===port && p.pid===process.pid && p.projectPath===process.cwd()));
  assert(!listeners.some(p=>p.port===otherPort));
  await new Promise(r=>first.close(r));
  const refreshed=discover(port);
  assert.notEqual(refreshed,pending);
  assert.deepEqual(await refreshed,[]);
 } finally {
  if(first.listening)await new Promise(r=>first.close(r));
  await new Promise(r=>second.close(r));
 }
});
test('registry validates, groups, serializes, persists and skips occupied ports',async()=>{
 const dir=await fs.mkdtemp(path.join(os.tmpdir(),'port-reg-'));
 const busy=net.createServer();let collision=false;
 try {await new Promise((resolve,reject)=>{busy.once('error',reject);busy.listen(4100,'127.0.0.1',resolve)});collision=true;}catch{}
 try {
 const r=new Registry(dir);await r.init();
 const apps=await Promise.all(Array.from({length:8},(_,i)=>r.request({name:`payment_${i}`,projectPath:process.cwd()})));
 assert.equal(new Set(apps.map(a=>a.port)).size,8);assert(apps.every(a=>a.port>=4101&&a.port<4120));
 assert.equal(apps[0].hostname,'payment-0');
 assert.equal((await r.request({name:'payment_0',projectPath:process.cwd()})).id,apps[0].id);
 await assert.rejects(r.request({name:'payment_0',projectPath:os.tmpdir()}),/another folder/);
 await assert.rejects(r.request({name:'bad.host',projectPath:process.cwd()}));
 await assert.rejects(r.request({name:'valid',projectPath:'relative'}));
 assert.throws(()=>slug('../etc'));assert.throws(()=>slug('x'.repeat(64)));
 const next=await r.request({name:'other-api',projectPath:process.cwd()});assert(next.port>=4120);
 const held=net.createServer();const heldPort=await listen(held);
 try { await assert.rejects(r.request({name:'held-app',projectPath:process.cwd(),port:heldPort}),/in use/); }
 finally { await new Promise(r=>held.close(r)); }
 await assert.rejects(r.request({name:'range-app',projectPath:process.cwd(),port:80}),/between 1024 and 65535/);
 const nameOnly=await r.request({name:'name-only-app'});assert.equal(nameOnly.projectPath,null);
 assert.equal((await r.request({name:'name-only-app',projectPath:process.cwd()})).projectPath,process.cwd());
 const pinProbe=net.createServer();const pinnedPort=await listen(pinProbe);await new Promise(r=>pinProbe.close(r));
 const pinned=await r.request({name:'pinned-app',projectPath:process.cwd(),port:pinnedPort});assert.equal(pinned.port,pinnedPort);
 await assert.rejects(r.request({name:'pin-conflict',projectPath:process.cwd(),port:pinnedPort}),/already registered/);
 const loaded=new Registry(dir);await loaded.init();assert.equal(loaded.state.apps.length,11);
 await loaded.release(apps[0].id);await assert.rejects(loaded.release(apps[0].id));
 }finally{if(collision)await new Promise(r=>busy.close(r));await fs.rm(dir,{recursive:true,force:true});}
});
test('daemon, HTTP/WebSocket proxy, identity conflicts and real MCP handshake',async()=>{
 const dir=await fs.mkdtemp(path.join(os.tmpdir(),'port-e2e-'));
 const probe=net.createServer();const controlPort=await listen(probe);await new Promise(r=>probe.close(r));
 const env={...process.env,PORT_DATA_DIR:dir,PORT_CONTROL_PORT:String(controlPort),PORT_PROXY_PORT:'0'};
 let daemon,client,upstream,wsServer; let logs='';
 async function start(){daemon=spawn(process.execPath,['server/daemon.mjs'],{env,stdio:['ignore','ignore','pipe']});daemon.stderr.on('data',c=>logs+=c);for(let i=0;i<100;i++){try{return JSON.parse(await fs.readFile(path.join(dir,'connection.json'),'utf8'));}catch{await sleep(50);}}throw new Error('Not ready '+logs);}
 let connection=await start();
 const token=(await fs.readFile(path.join(dir,'token'),'utf8')).trim();
 async function api(endpoint,body,headers={}) {const res=await fetch(`http://127.0.0.1:${controlPort}/v1/${endpoint}`,{method:body?'POST':'GET',headers:{Authorization:`Bearer ${token}`,...headers},body:body?JSON.stringify(body):undefined});return {code:res.status,data:await res.json()};}
 function proxy(host,pathname='/hello'){return new Promise((resolve,reject)=>{http.get({host:'127.0.0.1',port:connection.proxyPort,path:pathname,headers:{host}},res=>{let body='';res.on('data',c=>body+=c);res.on('end',()=>resolve({code:res.statusCode,body}));}).on('error',reject);});}
 try {
 assert.equal((await api('status',undefined,{Origin:'http://evil.test'})).code,403);
 assert.equal((await api('status',undefined,{Authorization:'Bearer wrong'})).code,403);
 const a=(await api('request',{name:'test_api',projectPath:process.cwd()})).data;
 assert.equal((await proxy(a.hostname)).code,404);
 assert.equal((await api('accept',{id:a.id})).code,200);
 assert.equal((await proxy(a.hostname)).code,502);
 upstream=http.createServer((req,res)=>{res.setHeader('x-test','yes');res.end('hello '+req.url);});
 let upstreamConnections=0;upstream.on('connection',()=>upstreamConnections++);
 wsServer=new WebSocketServer({server:upstream});wsServer.on('connection',ws=>ws.on('message',data=>ws.send(data)));
 await new Promise(resolve=>upstream.listen(a.port,'127.0.0.1',resolve));
 assert.deepEqual(await proxy(a.hostname,'/hello?q=1'),{code:200,body:'hello /hello?q=1'});
 for(let i=0;i<6;i++)assert.equal((await proxy(a.hostname,`/module-${i}.js`)).code,200);
 assert.equal(upstreamConnections,1,'sequential module requests reuse the verified upstream socket');
 const burst=await Promise.all(Array.from({length:24},(_,i)=>proxy(a.hostname,`/parallel-${i}.js`)));
 assert(burst.every(r=>r.code===200));
 assert(upstreamConnections<=16,'concurrent module loads have a bounded connection pool');
 assert.equal((await proxy('unregistered.localhost')).code,404);
 const ws=new WebSocket(`ws://127.0.0.1:${connection.proxyPort}/socket`,{headers:{host:a.hostname}});
 await once(ws,'open');ws.send('roundtrip');assert.equal((await once(ws,'message'))[0].toString(),'roundtrip');ws.close();await once(ws,'close');
 const status=(await api('status')).data;assert.equal(status.apps[0].status,'running');assert.equal(status.apps[0].processes[0].projectPath,process.cwd());
 const duplicate=spawn(process.execPath,['server/daemon.mjs'],{env,stdio:'ignore'});assert.equal((await once(duplicate,'exit'))[0],1);
 assert.equal((await api('status')).code,200);
 client=new Client({name:'port-test',version:'1.0.0'});
 await client.connect(new StdioClientTransport({command:process.execPath,args:[path.resolve('server/mcp.mjs')],env}));
 assert.equal((await client.listTools()).tools.length,12);
 const result=await client.callTool({name:'request_port',arguments:{name:'test-ui',projectPath:process.cwd()}});
 const b=JSON.parse(result.content[0].text);assert(b.port!==a.port && Math.abs(b.port-a.port)<20);
 assert(!(await client.callTool({name:'accept_port',arguments:{id:b.id}})).isError);
 const offlineBurst=await Promise.all(Array.from({length:24},()=>proxy(b.hostname)));
 assert(offlineBurst.every(r=>r.code===502),'failed identity checks release queued requests');
 assert((await client.callTool({name:'request_port',arguments:{name:'../../bad',projectPath:process.cwd()}})).isError);
 await client.close();client=null;
 daemon.kill();await once(daemon,'exit');connection=await start();assert.equal((await api('status')).data.apps.length,2);
 const c=(await api('request',{name:'conflict-api',projectPath:os.tmpdir()})).data;
 const alien=http.createServer();await new Promise(r=>alien.listen(c.port,'127.0.0.1',r));
 try{assert.equal((await api('accept',{id:c.id})).code,400);assert.equal((await api('status')).data.apps.find(x=>x.id===c.id).status,'conflict');}finally{await new Promise(r=>alien.close(r));}
 // An accepted route must reject a different project's later takeover, too.
 await new Promise(r=>upstream.close(r));upstream=null;
 const takeover=spawn(process.execPath,['-e',`require('http').createServer((q,s)=>s.end('alien')).listen(${a.port},'127.0.0.1',()=>console.log('ready'))`],{cwd:dir,stdio:['ignore','pipe','pipe']});
 try {
  await once(takeover.stdout,'data');
  const rejected=await proxy(a.hostname);
  assert.equal(rejected.code,502);
  assert.match(rejected.body,/Port belongs to another process/);
 } finally {const ended=once(takeover,'exit');takeover.kill();await ended;}
 assert.equal((await api('release',{id:a.id})).code,200);assert.equal((await proxy(a.hostname)).code,404);
 }finally{
 if(client)await client.close();if(wsServer)wsServer.close();if(upstream)await new Promise(r=>upstream.close(r));if(daemon?.exitCode===null){daemon.kill();await once(daemon,'exit');}await fs.rm(dir,{recursive:true,force:true});
 }
});
