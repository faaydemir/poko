import fs from 'node:fs/promises';
import path from 'node:path';
import {dataDir} from './core.mjs';
export async function api(endpoint,body) {
  let connection,token;
  try {connection=JSON.parse(await fs.readFile(path.join(dataDir,'connection.json'),'utf8'));token=(await fs.readFile(path.join(dataDir,'token'),'utf8')).trim();}
  catch {throw new Error('Poko Server is not running. Open Poko Server.app or run npm start.');}
  const response=await fetch(`http://127.0.0.1:${connection.controlPort}/v1/${endpoint}`,{method:body?'POST':'GET',headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(15000)});
  const result=await response.json();if(!response.ok)throw new Error(result.error||`HTTP ${response.status}`);return result;
}
