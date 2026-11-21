import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {parse} from 'jsonc-parser';

test('OpenCode registration preserves JSONC, backs up, reports status and refuses collisions',async()=>{
 const home=await fs.mkdtemp(path.join(os.tmpdir(),'port-agents-'));
 const configDir=path.join(home,'.config/opencode');
 const configFile=path.join(configDir,'opencode.jsonc');
 const bridge=path.join(home,'Library/Application Support/Port/runtime/server/mcp.mjs');
 const env={...process.env,HOME:home,XDG_CONFIG_HOME:path.join(home,'.config')};
 delete env.OPENCODE_CONFIG;
 const run=(...args)=>spawnSync(process.execPath,['scripts/connect-agents.mjs','opencode',...args],{env,encoding:'utf8'});
 const status=()=>JSON.parse(run('--status').stdout).find(x=>x.id==='opencode').status;
 try {
  await fs.mkdir(path.dirname(bridge),{recursive:true});await fs.writeFile(bridge,'');
  assert.equal(status(),'Not configured');
  await fs.mkdir(configDir,{recursive:true});
  const original='{// keep my settings\n "model":"example/model", "mcp":{"other":{"type":"remote","url":"http://localhost:1234"}},\n}\n';
  await fs.writeFile(configFile,original);
  assert.equal(run('--dry-run').status,0);
  assert.equal(await fs.readFile(configFile,'utf8'),original);
  const result=run();assert.equal(result.status,0,result.stderr);
  const source=await fs.readFile(configFile,'utf8'),config=parse(source);
  assert(source.includes('// keep my settings'));
  assert.equal(config.model,'example/model');assert.equal(config.mcp.other.url,'http://localhost:1234');
  assert.deepEqual(config.mcp.port,{type:'local',command:[process.execPath,bridge],enabled:true});
  const backup=(await fs.readdir(configDir)).find(x=>x.includes('.port-backup-'));
  assert.equal(await fs.readFile(path.join(configDir,backup),'utf8'),original);
  assert.equal(status(),'Configured');
  config.mcp.port.enabled=false;await fs.writeFile(configFile,JSON.stringify(config));
  assert.equal(status(),'Disabled');
  assert.equal(run().status,0);
  config.mcp.port.command=['another-server'];const collision=JSON.stringify(config);await fs.writeFile(configFile,collision);
  assert.equal(status(),'Different configuration');
  assert.notEqual(run().status,0);assert.equal(await fs.readFile(configFile,'utf8'),collision);
  await fs.writeFile(configFile,'{ invalid');assert.notEqual(run().status,0);
  assert.equal(await fs.readFile(configFile,'utf8'),'{ invalid');
 } finally {await fs.rm(home,{recursive:true,force:true});}
});
