import {test} from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {checkHealth,healthPath,shutdown} from '../server/operations.mjs';
test('health checks home and custom endpoints and reject external addresses',async()=>{
 const server=http.createServer((req,res)=>{res.writeHead(req.url==='/health'?503:200);res.end();});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));const port=server.address().port;
 try {assert.equal((await checkHealth(port)).status,'healthy');assert.equal((await checkHealth(port,'/health')).status,'unhealthy');assert.throws(()=>healthPath('https://example.com'));assert.throws(()=>healthPath('//example.com'));assert.equal(healthPath('/ready'),'/ready');}
 finally {await new Promise(r=>server.close(r));}
 assert.equal((await checkHealth(port)).status,'unreachable');
});
test('shutdown verifies listener PID before terminating only the selected child',async()=>{
 const child=spawn(process.execPath,['-e',"require('http').createServer((q,s)=>s.end('ok')).listen(0,'127.0.0.1',function(){console.log(this.address().port)})"],{stdio:['ignore','pipe','ignore']});
 const port=Number((await once(child.stdout,'data'))[0].toString().trim());
 try {await assert.rejects(shutdown({port,pid:process.pid},[]));await assert.rejects(shutdown({port,pid:child.pid},[port]));const ended=once(child,'exit');assert.equal((await shutdown({port,pid:child.pid},[])).signalled,true);assert.equal((await ended)[1],'SIGTERM');}
 finally {if(child.exitCode===null && child.signalCode===null)child.kill();}
});
