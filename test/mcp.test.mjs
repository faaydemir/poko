import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import {Client} from '@modelcontextprotocol/sdk/client/index.js';
import {StdioClientTransport} from '@modelcontextprotocol/sdk/client/stdio.js';

test('MCP forwards every UI operation and editor parameter, including draft starts and removal',async()=>{
 const dir=await fs.mkdtemp(path.join(os.tmpdir(),'poko-mcp-'));
 const received=[];
 const api=http.createServer(async(req,res)=>{
  assert.equal(req.headers.authorization,'Bearer test-only-token');
  let raw='';for await(const chunk of req)raw+=chunk;
  received.push({url:req.url,method:req.method,body:raw?JSON.parse(raw):null});
  res.setHeader('Content-Type','application/json');res.end(JSON.stringify(req.url==='/v1/status'?{ok:true,apps:[{name:'demo',port:4100,processes:[{pid:7,port:4100}]}],discovered:[{pid:9,port:5000}]}:{ok:true}));
 });
 const client=new Client({name:'poko-parity-test',version:'1.0.0'});
 try {
  await new Promise(r=>api.listen(0,'127.0.0.1',r));
  await fs.writeFile(path.join(dir,'connection.json'),JSON.stringify({controlPort:api.address().port}));
  await fs.writeFile(path.join(dir,'token'),'test-only-token');
  await client.connect(new StdioClientTransport({command:process.execPath,args:[process.env.POKO_TEST_BRIDGE || path.resolve('server/mcp.mjs')],env:{...process.env,PORT_DATA_DIR:dir}}));
  const tools=(await client.listTools()).tools;
  const settings={url:'http://demo',healthUrl:'/ready',iconUrl:'',startScript:'npm run dev',projectPath:'/Projects/demo'};
  const cases=[
   ['request_port','request',{name:'demo',projectPath:'/Projects/demo',group:'demo'}],
   ['request_port','request',{name:'demo',projectPath:'/Projects/demo',port:4100}],
   ['request_port','request',{name:'name-only'}],
   ['accept_port','accept',{id:'demo'}],
   ['list_apps','status',{}],['inspect_ports','status',{}],
   ['map_app','import',{name:'demo',port:4100,pid:4242,group:'demo',...settings}],
   ['configure_app','configure',{id:'demo',...settings}],
   ['start_app','start',{id:'demo',startScript:'echo draft',projectPath:'/Projects/draft'}],
   ['start_app','start',{id:'demo'}],
   ['set_health_endpoint','health',{id:'demo',healthPath:'/health'}],
   ['set_health_endpoint','health',{port:4100,healthPath:'/'}],
   ['shutdown_app','shutdown',{pid:4242,port:4100}],
   ['get_app_logs','logs',{id:'demo',lines:20}],
   ['release_port','release',{id:'demo'}]
  ];
  assert.deepEqual(new Set(tools.map(t=>t.name)),new Set([...cases.map(c=>c[0]),'get_port_info']));
  for(const [name,endpoint,args] of cases) {
   const result=await client.callTool({name,arguments:args});assert(!result.isError,JSON.stringify(result));
   const readOnly=endpoint==='status';
   assert.deepEqual(received.at(-1),{url:'/v1/'+endpoint,method:readOnly?'GET':'POST',body:readOnly?null:args});
  }
  const byPort=JSON.parse((await client.callTool({name:'get_port_info',arguments:{port:4100}})).content[0].text);
  assert.equal(byPort.apps[0].name,'demo');assert.equal(byPort.listeners[0].pid,7);assert.equal(byPort.free,false);
  const other=JSON.parse((await client.callTool({name:'get_port_info',arguments:{port:5000}})).content[0].text);
  assert.equal(other.apps.length,0);assert.equal(other.listeners[0].pid,9);
  assert.equal(JSON.parse((await client.callTool({name:'get_port_info',arguments:{port:6000}})).content[0].text).free,true);
  assert((await client.callTool({name:'get_port_info',arguments:{}})).isError);
  for(const name of ['release_port','shutdown_app'])assert.equal(tools.find(t=>t.name===name).annotations.destructiveHint,true);
  const count=received.length;
  assert((await client.callTool({name:'map_app',arguments:{name:'demo',port:'bad',pid:1}})).isError);
  assert.equal(received.length,count);
 }finally{await client.close();await new Promise(r=>api.close(r));await fs.rm(dir,{recursive:true,force:true});}
});
