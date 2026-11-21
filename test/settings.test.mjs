import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {Registry} from '../server/core.mjs';
import {settingsFor,configure,startApp} from '../server/settings.mjs';
test('settings validate app URLs, health endpoints and persist scripts',async()=>{
 const app={id:'fixture',hostname:'sample',port:49123};
 assert.equal(settingsFor(app,{url:'http://sample/home'}).appUrl,'http://sample/home');
 assert.equal(settingsFor(app,{healthUrl:'http://sample/health?ready=1'}).healthPath,'/health?ready=1');
 assert.throws(()=>settingsFor(app,{healthUrl:'http://external.example/health'}));
 assert.throws(()=>settingsFor(app,{url:'http://sample:47832'}));
 assert.throws(()=>settingsFor(app,{url:'http://sample.localhost'}));
 assert.equal(settingsFor(app,{iconUrl:''}).iconUrl,null);
 const dir=await fs.mkdtemp(path.join(os.tmpdir(),'port-settings-'));
 try {
  const r=new Registry(dir);await r.init();const a=await r.request({name:'settings-test',projectPath:process.cwd()});
  await configure(r,{id:a.id,url:'http://settings-test/home',healthUrl:'/health',startScript:'npm run dev'});
  const loaded=new Registry(dir);await loaded.init();assert.equal(loaded.get(a.id).startScript,'npm run dev');assert.equal(loaded.get(a.id).healthPath,'/health');
 }finally{await fs.rm(dir,{recursive:true,force:true});}
});
test('start script receives PORT and project cwd; repeated starts do not duplicate processes',async()=>{
 const dir=await fs.mkdtemp(path.join(os.tmpdir(),'port-start-'));let pid;
 try {
  const r=new Registry(dir);await r.init();const a=await r.request({name:'start-test',projectPath:process.cwd()});
  const code="require('http').createServer((q,s)=>s.end(process.cwd())).listen(Number(process.env.PORT),'127.0.0.1')";
  const quote=v=>"'"+v.replaceAll("'","'\\''")+"'";
  await configure(r,{id:a.id,startScript:`exec ${quote(process.execPath)} -e ${quote(code)}`});
  const result=await startApp(r,a.id);pid=result.pid;
  for(let i=0;i<50;i++){try{const response=await fetch(`http://127.0.0.1:${a.port}`,{signal:AbortSignal.timeout(1000)});assert.equal(await response.text(),process.cwd());break;}catch(e){if(i===49)throw e;await new Promise(r=>setTimeout(r,50));}}
  await assert.rejects(startApp(r,a.id),/already in use/);
 }finally{if(pid){try{process.kill(-pid,'SIGTERM');}catch{}}await fs.rm(dir,{recursive:true,force:true});}
});

test('draft scripts run with the draft folder and PORT without changing saved settings',async()=>{
 const dir=await fs.mkdtemp(path.join(os.tmpdir(),'port-draft-'));let pid;
 try {
  const registry=new Registry(path.join(dir,'data'));await registry.init();
  const app=await registry.request({name:'draft-test',projectPath:process.cwd()});
  const code="require('fs').writeFileSync('result.json',JSON.stringify({cwd:process.cwd(),port:process.env.PORT}))";
  const quote=v=>"'"+v.replaceAll("'","'\\''")+"'";
  const draft={startScript:`exec ${quote(process.execPath)} -e ${quote(code)}`,projectPath:dir};
  await assert.rejects(startApp(registry,app.id,{...draft,startScript:'bad\0script'}),/Invalid start script/);
  await assert.rejects(startApp(registry,app.id,{...draft,projectPath:'relative'}));
  const result=await startApp(registry,app.id,draft);pid=result.pid;
  let output;
  for(let i=0;i<50;i++){try{output=JSON.parse(await fs.readFile(path.join(dir,'result.json'),'utf8'));break;}catch(e){if(i===49)throw e;await new Promise(r=>setTimeout(r,50));}}
  assert.deepEqual(output,{cwd:await fs.realpath(dir),port:String(app.port)});
  assert.equal(registry.get(app.id).startScript,undefined);assert.equal(registry.get(app.id).projectPath,process.cwd());
  const loaded=new Registry(registry.dir);await loaded.init();assert.equal(loaded.get(app.id).startScript,undefined);
 } finally {if(pid){try{process.kill(-pid,'SIGTERM');}catch{}}await fs.rm(dir,{recursive:true,force:true});}
});

test('import applies all editor settings atomically and rejects invalid settings',async()=>{
 const {createServer}=await import('node:http');
 const {importApp}=await import('../server/settings.mjs');
 const dir=await fs.mkdtemp(path.join(os.tmpdir(),'port-import-settings-'));
 const listener=createServer((req,res)=>res.end('ok'));
 try {
  await new Promise(resolve=>listener.listen(0,'127.0.0.1',resolve));
  const registry=new Registry(dir);await registry.init();
  const input={name:'import-settings',pid:process.pid,port:listener.address().port,url:'http://import-settings',healthUrl:'/ready',iconUrl:'',startScript:'npm run dev',projectPath:process.cwd()};
  await assert.rejects(importApp(registry,{...input,healthUrl:'http://external.example'}));
  assert.equal(registry.state.apps.length,0);
  const app=await importApp(registry,input);
  assert.equal(app.healthPath,'/ready');assert.equal(app.startScript,'npm run dev');assert.equal(app.accepted,true);
  assert.equal(app.port,listener.address().port);
  const loaded=new Registry(dir);await loaded.init();assert.equal(loaded.get(app.id).healthPath,'/ready');
  await assert.rejects(startApp(registry,app.id,{startScript:'echo draft'}),/already in use/);
 } finally {await new Promise(resolve=>listener.close(resolve));await fs.rm(dir,{recursive:true,force:true});}
});
