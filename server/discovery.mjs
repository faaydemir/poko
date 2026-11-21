import http from 'node:http';
import path from 'node:path';
const cache = new Map();
function probe(port, host) {
  return new Promise(resolve => {
    const request = http.request({host, port, method:'HEAD', path:'/', agent:false}, response => {
      response.resume(); resolve(true); request.destroy();
    });
    const timer=setTimeout(()=>{request.destroy();resolve(false);},600);
    request.on('close',()=>clearTimeout(timer));
    request.on('error',()=>resolve(false)); request.end();
  });
}
export async function describeListeners(listeners) {
  const keys=new Set(listeners.map(x=>`${x.pid}:${x.port}`));
  for(const key of cache.keys())if(!keys.has(key))cache.delete(key);
  let cursor=0;const results=new Array(listeners.length);
  await Promise.all(Array.from({length:Math.min(8,listeners.length)},async()=>{
    while(cursor<listeners.length) {
      const i=cursor++, listener=listeners[i], key=`${listener.pid}:${listener.port}`;
      let hit=cache.get(key);
      if(!hit || Date.now()-hit.at>15000) {
        hit={at:Date.now(),isWeb:await probe(listener.port,'127.0.0.1') || await probe(listener.port,'::1')};
        cache.set(key,hit);
      }
      const displayName=(listener.projectPath ? path.basename(listener.projectPath) : null) || listener.command;
      const suggestedName=displayName.toLowerCase().replace(/[^a-z0-9]+/g,'-').replace(/^-|-$/g,'').slice(0,48).replace(/-$/,'') || 'app';
      results[i]={...listener,displayName,suggestedName,isWeb:hit.isWeb,url:`http://localhost:${listener.port}`};
    }
  }));
  return results.sort((a,b)=>Number(b.isWeb)-Number(a.isWeb)||a.port-b.port);
}
