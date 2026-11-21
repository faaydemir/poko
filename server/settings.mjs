import fs from 'node:fs/promises';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {discover,folder,slug} from './core.mjs';
import {healthPath} from './operations.mjs';
const launches=new Map();
export function settingsFor(app,input) {
 const next={...app};
 if(input.url!==undefined){
  const url=new URL(input.url);
  if(url.protocol!=='http:'||url.port||url.username||url.password||slug(url.hostname)!==url.hostname||['localhost','broadcasthost'].includes(url.hostname))throw new Error('Use a plain local app URL, such as http://knowledge-base, without a port');
  next.hostname=url.hostname;next.appUrl=url.href.replace(/\/$/,'');
 }
 if(input.healthUrl!==undefined){
  if(!input.healthUrl){next.healthUrl=null;next.healthPath='/';}
  else {
   const url=new URL(input.healthUrl,`http://${next.hostname}`);
   if(url.protocol!=='http:'||!['localhost','127.0.0.1',next.hostname].includes(url.hostname)||url.username||url.password||(url.port&&Number(url.port)!==app.port))throw new Error('Health URL must point to this app or its local port');
   next.healthUrl=url.href;next.healthPath=healthPath(url.pathname+url.search);
  }
 }
 if(input.iconUrl!==undefined){
  if(input.iconUrl){const icon=new URL(input.iconUrl);if(!['http:','https:'].includes(icon.protocol)||icon.username||icon.password)throw new Error('Icon must be an HTTP(S) URL');next.iconUrl=icon.href;}
  else next.iconUrl=null;
 }
 if(input.startScript!==undefined){if(typeof input.startScript!=='string'||input.startScript.length>8192||input.startScript.includes('\0'))throw new Error('Invalid start script');next.startScript=input.startScript.trim();}
 return next;
}
export async function configure(registry,input) {
 return registry.mutate(async()=>{
  const app=registry.get(input.id);const next=settingsFor(app,input);
  if(registry.state.apps.some(a=>a.id!==app.id&&a.hostname===next.hostname))throw new Error('That URL is already mapped');
  if(input.projectPath!==undefined)next.projectPath=await folder(input.projectPath);
  Object.assign(app,next);return app;
 });
}
export async function importApp(registry,input) {
 return registry.import(input,async app=>{
  const next=settingsFor(app,input);
  if(input.projectPath)next.projectPath=await folder(input.projectPath);
  return next;
 });
}
export async function startApp(registry,id,input={}) { return registry.mutate(async()=>{
 // Draft runs use the same validation as saved settings without modifying the app.
 const app=settingsFor(registry.get(id),{startScript:input.startScript});
 if(input.projectPath!==undefined)app.projectPath=await folder(input.projectPath);
 if(!app.startScript)throw new Error('Set a start script in Edit first');
 if(!app.projectPath)throw new Error('Set a project folder before starting');
 if((await discover()).some(x=>x.port===app.port))throw new Error('Port is already in use. Refresh before starting.');
 const previous=launches.get(id);
 if(previous){try{process.kill(previous,0);return {starting:true,pid:previous,id};}catch{launches.delete(id);}}
 const cwd=await folder(app.projectPath);
 const logs=path.join(registry.dir,'logs');await fs.mkdir(logs,{recursive:true,mode:0o700});
 const logFile=path.join(logs,app.id+'.log');const log=await fs.open(logFile,'a',0o600);
 try {
  const child=spawn('/bin/zsh',['-lc',app.startScript],{cwd,env:{...process.env,PORT:String(app.port)},detached:true,stdio:['ignore',log.fd,log.fd]});
  await new Promise((resolve,reject)=>{child.once('spawn',resolve);child.once('error',reject);});
  launches.set(id,child.pid);child.once('exit',()=>launches.delete(id));child.unref();
  return {starting:true,id,pid:child.pid,logFile};
 }finally{await log.close();}
 }); }
