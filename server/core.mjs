import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import net from 'node:net';
import { randomUUID } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
const exec = promisify(execFile);
const listenerProbe = fileURLToPath(new URL('./listener-probe',import.meta.url));
export const dataDir = process.env.PORT_DATA_DIR || path.join(os.homedir(), 'Library/Application Support/Port');
export async function atomic(file, value) {
  const temp = `${file}.${randomUUID()}.tmp`;
  await fs.writeFile(temp, JSON.stringify(value, null, 2), {mode:0o600});
  await fs.rename(temp, file);
}
export function slug(value) {
  if (typeof value !== 'string') throw new Error('Name must be text');
  const s = value.trim().toLowerCase().replace(/[_\s]+/g, '-');
  if (!/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(s)) throw new Error('Use 1–63 letters, numbers and hyphens');
  return s;
}
export async function folder(value) {
  if (typeof value !== 'string' || !path.isAbsolute(value)) throw new Error('projectPath must be an absolute folder path');
  const real = await fs.realpath(value);
  if (!(await fs.stat(real)).isDirectory()) throw new Error('projectPath must be a folder');
  return real;
}
async function freePort(port) {
  for (const host of ['127.0.0.1', '::1']) {
    const ok = await new Promise(resolve => {
      const s = net.createServer();
      s.once('error', e => resolve(e.code === 'EAFNOSUPPORT'));
      s.listen({port,host,ipv6Only:true}, () => s.close(() => resolve(true)));
    });
    if (!ok) return false;
  }
  return true;
}
// Share only scans that are still running. Never cache a completed identity check:
// the process owning a port can change between requests.
const pendingPortScans = new Map();
export function discover(port) {
  if (port !== undefined && (!Number.isInteger(port) || port < 1 || port > 65535)) throw new Error('Invalid discovery port');
  if (!pendingPortScans.has(port)) {
    const pending = scanListeners(port).finally(() => pendingPortScans.delete(port));
    pendingPortScans.set(port, pending);
  }
  return pendingPortScans.get(port);
}
async function scanListeners(port) {
  if(process.platform==='darwin') {
    try {
      const {stdout}=await exec(listenerProbe,port===undefined?[]:[String(port)],{timeout:10000,maxBuffer:2e6});
      const listeners=JSON.parse(stdout);
      const seen=new Set();
      return listeners.filter(p=>{const key=`${p.pid}:${p.port}`;if(seen.has(key))return false;seen.add(key);return true;}).sort((a,b)=>a.port-b.port);
    } catch(error) {
      if(error.code!=='ENOENT')throw new Error(`Port discovery failed: ${error.message}`);
    }
  }
  let stdout = '';
  try { ({stdout} = await exec('/usr/sbin/lsof', ['-nP',port === undefined ? '-iTCP' : `-iTCP:${port}`,'-sTCP:LISTEN','-Fpcn'], {timeout:4000,maxBuffer:2e6})); }
  catch (e) { if (e.code !== 1) throw new Error(`Port discovery failed: ${e.message}`); }
  const found = []; let pid, command;
  for (const line of stdout.split('\n')) {
    if (line[0] === 'p') pid = Number(line.slice(1));
    if (line[0] === 'c') command = line.slice(1);
    if (line[0] === 'n') {
      const port = Number(line.match(/:(\d+)$/)?.[1]);
      if (port && pid && !found.some(x=>x.pid===pid && x.port===port)) found.push({pid,command,port,projectPath:null});
    }
  }
  const pids=[...new Set(found.map(x=>x.pid))];
  if(pids.length) {
    let directories;
    try {
      // One lookup for the whole scan, rather than one child process per PID.
      // Browser module loads otherwise flood the machine with lsof processes.
      const {stdout} = await exec('/usr/sbin/lsof', ['-a','-p',pids.join(','),'-d','cwd','-Fn'], {timeout:2000,maxBuffer:2e6});
      directories=stdout;
    } catch(error) {
      // A process can exit during discovery. Keep the other verified results.
      directories=error.stdout || '';
    }
    let currentPid;
    for(const line of directories.split('\n')) {
      if(line[0]==='p')currentPid=Number(line.slice(1));
      if(line[0]==='n')found.filter(x=>x.pid===currentPid).forEach(x=>x.projectPath=line.slice(1));
    }
  }
  return found.sort((a,b)=>a.port-b.port);
}
export class Registry {
  constructor(dir, excluded = []) { this.dir=dir; this.excluded=excluded; this.state={apps:[],groups:{}}; this.queue=Promise.resolve(); }
  async init() {
    await fs.mkdir(this.dir,{recursive:true,mode:0o700});
    try { this.state=JSON.parse(await fs.readFile(path.join(this.dir,'registry.json'),'utf8')); }
    catch(e) { if(e.code!=='ENOENT') throw new Error('Cannot read registry; restore registry.json from a backup. '+e.message); }
    for(const app of this.state.apps || []) if(!app.hostname || app.hostname.endsWith('.localhost'))app.hostname=app.name;
    if (!Array.isArray(this.state.apps) || !this.state.groups || typeof this.state.groups!=='object') throw new Error('Invalid registry');
  }
  mutate(fn) {
    const run=this.queue.then(async()=>{
      const old=structuredClone(this.state);
      try { const result=await fn(); await atomic(path.join(this.dir,'registry.json'),this.state); return result; }
      catch(e) { this.state=old; throw e; }
    });
    this.queue=run.catch(()=>{}); return run;
  }
  async request(input) { return this.mutate(async()=>{
    const name=slug(input.name);
    const projectPath=input.projectPath===undefined||input.projectPath===null||input.projectPath===''?null:await folder(input.projectPath);
    const requested=input.port===undefined||input.port===null?null:Number(input.port);
    if(requested!==null&&(!Number.isInteger(requested)||requested<1024||requested>65535)) throw new Error('Port must be between 1024 and 65535');
    const existing=this.state.apps.find(x=>x.name===name);
    if(existing) {
      if(projectPath && existing.projectPath && existing.projectPath!==projectPath) throw new Error('Name belongs to another folder. Choose a unique app name.');
      if(projectPath && !existing.projectPath) existing.projectPath=projectPath;
      return existing;
    }
    const group=slug(input.group || name.split('-')[0]);
    if(!Object.hasOwn(this.state.groups,group)) {
      let base=4100; const used=Object.values(this.state.groups);
      while(used.includes(base)) base+=20;
      if(base>60000) throw new Error('Port range exhausted');
      this.state.groups[group]=base;
    }
    let port;
    if(requested!==null) {
      if(this.excluded.includes(requested)) throw new Error('This port is reserved by Poko. Choose another.');
      if(this.state.apps.some(a=>a.port===requested)) throw new Error('This port is already registered. Choose another.');
      if(!await freePort(requested)) throw new Error('This port is in use. Choose another.');
      port=requested;
    } else {
      let base=this.state.groups[group];
      for(let p=base;p<base+20;p++) if(!this.excluded.includes(p) && !this.state.apps.some(a=>a.port===p) && await freePort(p)) {port=p;break;}
    }
    if(!port) throw new Error('This group has no free ports. Use another group or release an unused reservation.');
    const app={id:randomUUID(),name,group,projectPath,port,hostname:name,accepted:false,createdAt:new Date().toISOString()};
    this.state.apps.push(app); return app;
  }); }
  async accept(id) { return this.mutate(async()=>{
    const app=this.get(id); const listeners=(await discover()).filter(x=>x.port===app.port);
    if((app.projectPath && listeners.some(x=>x.projectPath!==app.projectPath)) || (!listeners.length && !await freePort(app.port))) throw new Error('Port is occupied by an unverified process. Release and request again, or explicitly import the listener.');
    app.accepted=true; return app;
  }); }
  async import(input, prepare=app=>app) { return this.mutate(async()=>{
    const name=slug(input.name), port=Number(input.port), pid=Number(input.pid);
    if(!Number.isInteger(port)||port<1024||port>65535||this.excluded.includes(port)) throw new Error('Invalid import port');
    if(this.state.apps.some(x=>x.name===name||x.port===port)) throw new Error('Name or port is already registered');
    const listener=(await discover()).find(x=>x.port===port&&x.pid===pid);
    if(!listener) throw new Error('Listener no longer exists; refresh and retry');
    const projectPath=listener.projectPath || (input.projectPath ? await folder(input.projectPath) : null);
    const app={id:randomUUID(),name,group:slug(input.group||name.split('-')[0]),projectPath,port,hostname:name,accepted:true,healthPath:this.state.healthPaths?.[String(port)]||'/',importedPid:pid,createdAt:new Date().toISOString()};
    Object.assign(app,await prepare(app));
    if(this.state.apps.some(a=>a.hostname===app.hostname))throw new Error('That URL is already mapped');
    this.state.apps.push(app); return app;
  }); }
  get(id) { const app=this.state.apps.find(a=>a.id===id); if(!app) throw new Error('App not found'); return app; }
  release(id) { return this.mutate(async()=>{this.get(id);this.state.apps=this.state.apps.filter(a=>a.id!==id);return {released:true};}); }
  async list(proxyPort) {
    const listeners=await discover();
    const apps=this.state.apps.map(app=>{
      const processes=listeners.filter(p=>p.port===app.port);
      const identity=app.projectPath ? p=>p.projectPath!==app.projectPath : app.importedPid ? p=>p.pid!==app.importedPid : ()=>false;
      const conflict=processes.some(identity);
      return {...app,iconUrl:app.iconUrl||`http://${app.hostname}/favicon.ico`,url:app.appUrl||`http://${app.hostname}`,proxyUrl:proxyPort?`http://${app.hostname}:${proxyPort}`:null,status:conflict?'conflict':!app.accepted?'reserved':processes.length?'running':'stopped',processes};
    }).sort((a,b)=>a.group.localeCompare(b.group)||a.port-b.port);
    return {apps,discovered:listeners.filter(p=>!this.excluded.includes(p.port)&&!apps.some(a=>a.port===p.port))};
  }
}
