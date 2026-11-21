import http from 'node:http';
import {discover} from './core.mjs';
export function healthPath(value='/') {
 if(typeof value!=='string'||!value.startsWith('/')||value.startsWith('//')||/[\r\n#]/.test(value)||value.length>1024)throw new Error('Health endpoint must be a local path such as / or /health');
 return value;
}
export function checkHealth(port, endpoint='/', hostname='localhost') {
 return (async()=>{
  const checkedAt=new Date().toISOString();
  for(const host of ['127.0.0.1','::1']) {
   const result=await new Promise(done=>{
    const request=http.request({host,port,path:endpoint,method:'GET',headers:{Host:hostname},agent:false},response=>{
     const statusCode=response.statusCode;response.destroy();done({status:statusCode>=200&&statusCode<400?'healthy':'unhealthy',statusCode});
    });
    const timer=setTimeout(()=>{request.destroy();done(null);},1000);
    request.on('close',()=>clearTimeout(timer));request.on('error',()=>done(null));request.end();
   });
   if(result)return {...result,path:endpoint,checkedAt};
  }
  return {status:'unreachable',statusCode:null,path:endpoint,checkedAt};
 })();
}
export async function enrichHealth(status,registry) {
 const entries=[...status.apps,...status.discovered];let cursor=0;
 await Promise.all(Array.from({length:8},async()=>{
  while(cursor<entries.length){const app=entries[cursor++];app.healthPath=app.healthPath||registry.state.healthPaths?.[String(app.port)]||'/';app.directUrl=`http://localhost:${app.port}`;
   app.health=app.status==='conflict'?{status:'conflict',path:app.healthPath}:await checkHealth(app.port,app.healthPath,app.hostname||'localhost');
  }
 }));return status;
}
export async function shutdown(input,excluded) {
 const port=Number(input.port),pid=Number(input.pid);
 if(!Number.isInteger(port)||!Number.isInteger(pid)||pid<=1||pid===process.pid||pid===process.ppid||excluded.includes(port))throw new Error('Cannot stop this process');
 const current=(await discover()).find(x=>x.port===port&&x.pid===pid);
 if(!current)throw new Error('Listener changed or stopped. Refresh before trying again.');
 process.kill(pid,'SIGTERM');return {signalled:true,pid,port,signal:'SIGTERM'};
}
