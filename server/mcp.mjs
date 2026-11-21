import {McpServer} from '@modelcontextprotocol/sdk/server/mcp.js';
import {StdioServerTransport} from '@modelcontextprotocol/sdk/server/stdio.js';
import {z} from 'zod';
import {api} from './client.mjs';
const settings={url:z.string().optional(),healthUrl:z.string().optional(),iconUrl:z.string().optional(),startScript:z.string().max(8192).optional(),projectPath:z.string().optional()};
const server=new McpServer({name:'poko',version:'1.0.0'},{instructions:'Before starting a local dev service, request_port with its unique name and absolute project folder; accept_port using the returned id BEFORE starting it; set PORT to the allocated port. Optional port pins a free port. Use the returned localhost URL. Never hardcode a shared default port. Allocation is advisory until the service binds.'});
function tool(name,description,inputSchema,endpoint,readOnly=false) {
  server.registerTool(name,{description,inputSchema,annotations:{readOnlyHint:readOnly,destructiveHint:['release_port','shutdown_app'].includes(name),openWorldHint:false}},async input=>{
    try {const result=await api(endpoint,readOnly?undefined:input);return {content:[{type:'text',text:JSON.stringify(result,null,2)}]};}
    catch(e){return {isError:true,content:[{type:'text',text:e.message}]};}
  });
}
tool('request_port','Reserve an available port with just a name (optionally pin a specific free port, 1024–65535). projectPath is optional; a later request with the same name can attach it. Same name returns the existing reservation. Related group services receive nearby ports.',{name:z.string(),projectPath:z.string().optional(),group:z.string().optional(),port:z.number().int().optional()},'request');
tool('accept_port','Accept a reservation and activate its hostname proxy. Prefer calling before starting the service. Running listeners must match the project folder.',{id:z.string()},'accept');
tool('list_apps','Read all UI data: mappings, ports, direct and proxy URLs, folders, PIDs, live state, configured health path and health results.',{},'status',true);
tool('inspect_ports','Discover local TCP listeners, PIDs and project folders where permissions allow.',{},'status',true);
tool('release_port','Remove a reservation and proxy route. Does not stop the process.',{id:z.string()},'release');
tool('map_app','Map an existing running listener without changing its port.',{name:z.string(),port:z.number().int(),pid:z.number().int(),group:z.string().optional(),...settings},'import');
tool('set_health_endpoint','Configure a local health path. Default / checks the home page; 2xx/3xx is healthy.',{id:z.string().optional(),port:z.number().int().optional(),healthPath:z.string()},'health');
tool('shutdown_app','Send SIGTERM to the exact PID currently listening on the given port. Stops the app, including all ports served by that process.',{pid:z.number().int(),port:z.number().int()},'shutdown');
tool('configure_app','Edit the same settings as the UI: URL, health URL, icon URL (empty uses favicon), start script and project folder. Start scripts execute as the current user in the project folder with PORT set.',{id:z.string(),...settings},'configure');
tool('start_app','Run the app’s configured start script from its project folder with its allocated PORT. Returns PID and log path. Optional startScript and projectPath test a draft without saving it.',{id:z.string(),startScript:settings.startScript,projectPath:settings.projectPath},'start');
server.registerTool('get_port_info',{description:'Look up who owns a port or which port an app uses. Pass port (number) or name. Returns the registered app (if any) and the live process listening there (PID, command, folder), or reports the port as free.',inputSchema:{port:z.number().int().optional(),name:z.string().optional()},annotations:{readOnlyHint:true,destructiveHint:false,openWorldHint:false}},async({port,name})=>{
  try {
    if(port===undefined&&!name)throw new Error('Provide port or name');
    const status=await api('status');
    const wanted=name?.trim().toLowerCase();
    const apps=status.apps.filter(a=>(port===undefined||a.port===port)&&(!wanted||a.name===wanted));
    const ports=new Set([...(port===undefined?[]:[port]),...apps.map(a=>a.port)]);
    const listeners=[...status.apps.flatMap(a=>a.processes||[]),...status.discovered].filter(p=>ports.has(p.port));
    const result={apps,listeners,free:ports.size>0&&!apps.length&&!listeners.length};
    return {content:[{type:'text',text:JSON.stringify(result,null,2)}]};
  } catch(e){return {isError:true,content:[{type:'text',text:e.message}]};}
});
tool('get_app_logs','Read the last lines of the log written by start_app for an app (stdout and stderr of its start script).',{id:z.string(),lines:z.number().int().min(1).max(500).optional()},'logs');
await server.connect(new StdioServerTransport());
