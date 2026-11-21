import http from 'node:http';
import net from 'node:net';
import fs from 'node:fs/promises';
import path from 'node:path';
import {randomBytes, timingSafeEqual} from 'node:crypto';
import {dataDir, atomic, discover, Registry} from './core.mjs';
import {enrichHealth, healthPath, shutdown} from './operations.mjs';
import {configure,importApp,startApp} from './settings.mjs';
import {describeListeners} from './discovery.mjs';
const controlPort=Number(process.env.PORT_CONTROL_PORT||47831);
const wantedProxy=Number(process.env.PORT_PROXY_PORT||47832);
if(!Number.isInteger(wantedProxy) || (wantedProxy!==0 && (wantedProxy<1024 || wantedProxy>65535))) throw new Error('Proxy port must be 1024–65535 (or 0 for automatic selection)');
const registry=new Registry(dataDir,[controlPort,wantedProxy]);
await registry.init();
let token, proxyPort=null, proxyError=null;
let owner=false;
const upstreamAgents=new Map();
function dropAgent(id) {upstreamAgents.get(id)?.agent.destroy();upstreamAgents.delete(id);}
const send=(res,status,obj)=>{res.writeHead(status,{'Content-Type':'application/json','Cache-Control':'no-store'});res.end(JSON.stringify(obj));};
const control=http.createServer(async(req,res)=>{
  const auth=Buffer.from(req.headers.authorization||''); const expected=Buffer.from(`Bearer ${token}`);
  if(req.headers.origin || ![`127.0.0.1:${controlPort}`,`localhost:${controlPort}`].includes(req.headers.host) || auth.length!==expected.length || !timingSafeEqual(auth,expected)) return send(res,403,{error:'Forbidden'});
  try {
    if(req.method==='GET'&&req.url==='/v1/status') {
      const status=await registry.list(proxyPort);
      status.discovered=await describeListeners(status.discovered);
      await enrichHealth(status,registry);
      let domains={ready:false,domains:[]};
      try {domains=JSON.parse(await fs.readFile(`/var/run/dev.port.domains-${process.getuid()}.json`,'utf8'));if(Date.now()/1000-domains.updatedAt>5)domains.ready=false;}catch{}
      status.domainRoutingReady=domains.ready && proxyPort===47832;
      status.domainRoutingError=domains.error||null;
      for(const app of status.apps)app.domainReady=status.domainRoutingReady && domains.domains.includes(app.hostname);
      return send(res,200,{...status,proxyPort,proxyError,serverPid:process.pid});
    }
    if(req.method!=='POST') return send(res,404,{error:'Not found'});
    let body=''; for await(const chunk of req) {body+=chunk;if(body.length>16384) {send(res,413,{error:'Request too large'});return;}}
    const input=JSON.parse(body||'{}'); let result;
    switch(req.url) {
      case '/v1/configure': result=await configure(registry,input);dropAgent(input.id);break;
      case '/v1/start': result=await startApp(registry,input.id,input);break;
      case '/v1/request': result=await registry.request(input);break;
      case '/v1/accept': result=await registry.accept(input.id);break;
      case '/v1/release': result=await registry.release(input.id);dropAgent(input.id);break;
      case '/v1/import': result=await importApp(registry,input);break;
      case '/v1/health': result=await registry.mutate(async()=>{
        const endpoint=healthPath(input.healthPath);
        if(input.id){const app=registry.get(input.id);app.healthPath=endpoint;return app;}
        const port=Number(input.port);
        if(!Number.isInteger(port)||port<1024||port>65535)throw new Error('Invalid port');
        registry.state.healthPaths ||= {};registry.state.healthPaths[String(port)]=endpoint;return {port,healthPath:endpoint};
      });break;
      case '/v1/logs': {
        const app=registry.get(input.id);
        const text=await fs.readFile(path.join(registry.dir,'logs',app.id+'.log'),'utf8').catch(()=>'');
        result={id:app.id,log:text.split('\n').slice(-(Number.isInteger(input.lines)?Math.min(input.lines,500):100)).join('\n')};break;
      }
      case '/v1/shutdown': result=await shutdown(input,registry.excluded);break;
      default: return send(res,404,{error:'Not found'});
    }
    send(res,200,{...result,...(result.port?{url:result.appUrl||(result.hostname?`http://${result.hostname}`:null),instructions:`Set PORT=${result.port}; accept_port before starting the service, then bind to 127.0.0.1:${result.port}. Allow hostname ${result.hostname} in your dev server if required.`}:{})});
  }catch(e){send(res,400,{error:e.message});}
});
control.requestTimeout=10000;
function listen(server,port,host='127.0.0.1') { return new Promise((resolve,reject)=>{server.once('error',reject);server.listen(port,host,()=>{server.removeListener('error',reject);resolve();});}); }
try { await listen(control,controlPort); owner=true; }
catch(e) { console.error(`Poko Server control port ${controlPort}: ${e.message}. Another instance may be running.`);process.exit(1); }
try { token=(await fs.readFile(path.join(dataDir,'token'),'utf8')).trim(); }
catch(e) {if(e.code!=='ENOENT') throw e;token=randomBytes(32).toString('hex');await fs.writeFile(path.join(dataDir,'token'),token,{mode:0o600});}
await fs.chmod(path.join(dataDir,'token'),0o600);
function route(req) {
  const hostname=(req.headers.host||'').toLowerCase().split(':')[0];
  return registry.state.apps.find(a=>a.accepted&&a.hostname===hostname);
}
async function verifyTarget(app) {
  const processes=await discover(app.port);
  if(app.projectPath && processes.some(p=>!p.projectPath)) throw new Error('Cannot verify service project folder; retry the request');
  if(processes.some(p=>app.projectPath ? p.projectPath!==app.projectPath : app.importedPid ? p.pid!==app.importedPid : false)) throw new Error('Port belongs to another process');
  if(!processes.length) throw new Error('Service is offline');
}
async function connect(app) {
  await verifyTarget(app);
  for(const host of ['127.0.0.1','::1']) {
    try { return await new Promise((resolve,reject)=>{
      const s=net.connect({host,port:app.port});
      s.setNoDelay(true);
      s.setTimeout(2000,()=>s.destroy(new Error('Upstream timeout')));
      s.once('error',reject);s.once('connect',()=>{s.removeListener('error',reject);s.setTimeout(0);resolve(s);});
    }); }catch(e){if(host==='::1') throw e;}
  }
}
function agentFor(app) {
  const signature=JSON.stringify([app.port,app.projectPath,app.importedPid]);
  let entry=upstreamAgents.get(app.id);
  if(entry?.signature!==signature) {
    dropAgent(app.id);
    const target={...app};
    const agent=new http.Agent({keepAlive:true,maxSockets:16,maxFreeSockets:8,timeout:5000});
    agent.createConnection=(_options,callback)=>{connect(target).then(socket=>callback(null,socket),callback);};
    // Node's Agent does not count sockets while an asynchronous identity check
    // is pending. Bound active requests too, so a burst cannot bypass maxSockets.
    let active=0;const waiting=[];
    const acquire=async()=>{
      if(active<16)active++;else await new Promise(resolve=>waiting.push(resolve));
      let released=false;
      return ()=>{if(released)return;released=true;const next=waiting.shift();if(next)next();else active--;};
    };
    entry={signature,agent,acquire};upstreamAgents.set(app.id,entry);
  }
  return entry;
}
const proxy=http.createServer(async(req,res)=>{
  const app=route(req);if(!app)return send(res,404,{error:'No route for this hostname. Request and accept a port in Poko.'});
  let release=()=>{};
  try {
    const headers={...req.headers,'x-forwarded-host':req.headers.host,'x-forwarded-proto':'http','x-forwarded-for':req.socket.remoteAddress};
    delete headers['proxy-authorization']; delete headers['proxy-connection'];
    headers.connection='keep-alive';
    const entry=agentFor(app);release=await entry.acquire();
    if(req.aborted || res.destroyed){release();return;}
    if(route(req)!==app || agentFor(app)!==entry)throw new Error('Mapping changed; retry the request');
    const upstream=http.request({host:'127.0.0.1',port:app.port,method:req.method,path:req.url,headers,agent:entry.agent},response=>{
      response.on('end',release);response.on('close',release);
      res.writeHead(response.statusCode,response.headers);response.pipe(res);
    });
    upstream.on('error',error=>{release();if(!res.headersSent)send(res,502,{error:error.message});else res.destroy();});
    res.on('close',()=>{release();if(!res.writableFinished)upstream.destroy();});req.on('aborted',()=>upstream.destroy());req.pipe(upstream);
  }catch(e){release();send(res,502,{error:e.message});}
});
proxy.on('upgrade',async(req,client,head)=>{
  const app=route(req);
  if(!app){client.end('HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n');return;}
  client.on('error',()=>{});
  try{
    const upstream=await connect(app);
    upstream.on('error',()=>client.destroy());client.on('close',()=>upstream.destroy());upstream.on('close',()=>client.destroy());
    const headers=Object.entries(req.headers).filter(([k])=>k!=='proxy-authorization').map(([k,v])=>`${k}: ${v}`).join('\r\n');
    upstream.write(`${req.method} ${req.url} HTTP/${req.httpVersion}\r\n${headers}\r\n\r\n`);
    if(head.length)upstream.write(head);client.pipe(upstream).pipe(client);
  }catch{client.end('HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n');}
});
try {await listen(proxy,wantedProxy);proxyPort=proxy.address().port;}
catch(e){
  proxyError=`Port ${wantedProxy}: ${e.code}`;
  try{await listen(proxy,47832);proxyPort=47832;}
  catch {try{await listen(proxy,0);proxyPort=proxy.address().port;}catch(e){proxyError+=`; fallback: ${e.message}`;}}
}
registry.excluded.push(proxyPort);
await atomic(path.join(dataDir,'connection.json'),{controlPort,pid:process.pid,proxyPort});
console.error(`Poko Server ready: control 127.0.0.1:${controlPort}, proxy ${proxyPort}`);
for(const signal of ['SIGTERM','SIGINT']) process.on(signal,async()=>{if(owner)await fs.rm(path.join(dataDir,'connection.json'),{force:true});for(const id of upstreamAgents.keys())dropAgent(id);control.close();proxy.close();process.exit(0);});
