#!/usr/bin/env node
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {parse,modify,applyEdits} from 'jsonc-parser';

const home = os.homedir();
const runtimeDir = path.join(home, 'Library/Application Support/Port/runtime');
const bridge = path.join(runtimeDir, 'server/mcp.mjs');
const skillSource = path.join(runtimeDir, 'SKILL.md');

// Alphabetical order by display name: Antigravity, Claude Code, Codex, Cursor, OpenCode
const allAgents = ['antigravity', 'claude', 'codex', 'cursor', 'opencode'];
const agentNames = {
  antigravity: 'Antigravity',
  claude: 'Claude Code',
  codex: 'Codex',
  cursor: 'Cursor',
  opencode: 'OpenCode'
};

const args = process.argv.slice(2);
const dry = args.includes('--dry-run');

// Locate node entry
let nodeExec = process.execPath;
try {
  const conf = JSON.parse(await fs.readFile(path.join(runtimeDir, 'agent-config.json'), 'utf8'));
  if (conf.node) nodeExec = conf.node;
} catch {}

const entry = {command: nodeExec, args: [bridge]};
const openCodeEntry = {type: 'local', command: [entry.command, ...entry.args], enabled: true};

async function openCodeConfig() {
  const base = path.join(process.env.XDG_CONFIG_HOME || path.join(home, '.config'), 'opencode');
  const files = process.env.OPENCODE_CONFIG ? [path.resolve(process.env.OPENCODE_CONFIG)] : [path.join(base, 'opencode.json'), path.join(base, 'opencode.jsonc')];
  const configs = [];
  for (const file of files) {
    let source;
    try { source = await fs.readFile(file, 'utf8'); } catch (e) { if (e.code === 'ENOENT') continue; throw e; }
    const errors = [], config = parse(source, errors, {allowTrailingComma: true});
    if (errors.length || !config || typeof config !== 'object' || Array.isArray(config) || (config.mcp !== undefined && (!config.mcp || typeof config.mcp !== 'object' || Array.isArray(config.mcp)))) {
      throw new Error('Cannot read OpenCode configuration; fix its JSON before adding Poko.');
    }
    configs.push({file, source, config});
  }
  return configs.length ? configs : [{file: files[0], source: '{}\n', config: {}}];
}

function matchesOpenCode(server) {
  return server?.type === 'local' && JSON.stringify(server.command) === JSON.stringify(openCodeEntry.command);
}

function getSkillPath(agent) {
  switch (agent) {
    case 'antigravity': return path.join(home, '.gemini/antigravity/skills/poko/SKILL.md');
    case 'claude': return path.join(home, '.claude/skills/poko/SKILL.md');
    case 'codex': return path.join(home, '.codex/skills/poko/SKILL.md');
    case 'cursor': return path.join(home, '.cursor/skills/poko/SKILL.md');
    case 'opencode': return path.join(home, '.config/opencode/skills/poko/SKILL.md');
    default: return null;
  }
}

async function isAgentDetected(agent) {
  switch (agent) {
    case 'antigravity': {
      try { await fs.access('/Applications/Antigravity.app'); return true; } catch {}
      const res = spawnSync('which', ['antigravity'], {encoding: 'utf8'});
      return res.status === 0;
    }
    case 'claude': {
      const res = spawnSync('which', ['claude'], {encoding: 'utf8'});
      if (res.status === 0) return true;
      try { await fs.access(path.join(home, '.claude.json')); return true; } catch {}
      return false;
    }
    case 'codex': {
      const res = spawnSync('which', ['codex'], {encoding: 'utf8'});
      if (res.status === 0) return true;
      try { await fs.access(path.join(home, '.codex')); return true; } catch {}
      return false;
    }
    case 'cursor': {
      for (const p of ['/Applications/Cursor.app', path.join(home, 'Applications/Cursor.app'), path.join(home, '.cursor')]) {
        try { await fs.access(p); return true; } catch {}
      }
      const res = spawnSync('which', ['cursor'], {encoding: 'utf8'});
      return res.status === 0;
    }
    case 'opencode': {
      const res = spawnSync('which', ['opencode'], {encoding: 'utf8'});
      if (res.status === 0) return true;
      try { await fs.access(path.join(home, '.config/opencode')); return true; } catch {}
      return false;
    }
    default:
      return true;
  }
}

async function checkSkillStatus(agent) {
  const sp = getSkillPath(agent);
  if (!sp) return 'Not configured';
  try {
    const stat = await fs.stat(sp);
    return stat.size > 0 ? 'Configured' : 'Not configured';
  } catch {
    return 'Not configured';
  }
}

async function installSkill(agent) {
  const targetPath = getSkillPath(agent);
  if (!targetPath) throw new Error(`Unknown agent for skill: ${agent}`);
  let content;
  try {
    content = await fs.readFile(skillSource, 'utf8');
  } catch (e) {
    throw new Error(`Cannot find SKILL.md to install: ${e.message}`);
  }
  if (dry) {
    console.log(`Would install skill to ${targetPath}`);
    return;
  }
  await fs.mkdir(path.dirname(targetPath), {recursive: true});
  await fs.writeFile(targetPath, content, 'utf8');
  console.log(`${agentNames[agent]}: Skill installed to ${targetPath}`);
}

async function removeSkill(agent) {
  const targetPath = getSkillPath(agent);
  if (!targetPath) return;
  try {
    await fs.unlink(targetPath);
    console.log(`${agentNames[agent]}: Skill removed`);
  } catch (e) {
    if (e.code !== 'ENOENT') throw e;
  }
}

function matchesBridgeEntry(existing) {
  if (!existing || typeof existing !== 'object') return false;
  if (existing.command === entry.command && JSON.stringify(existing.args) === JSON.stringify(entry.args)) return true;
  return Array.isArray(existing.args) && existing.args.some(a => typeof a === 'string' && a.endsWith('/server/mcp.mjs'));
}

async function checkMcpStatus(target) {
  try {
    let existing;
    if (target === 'opencode') {
      const configs = await openCodeConfig();
      const servers = configs.map(x => x.config.mcp?.port ?? x.config.mcp?.poko).filter(x => x !== undefined);
      return !servers.length ? 'Not configured' : servers.some(x => !matchesOpenCode(x)) ? 'Different configuration' : servers.at(-1).enabled === false ? 'Disabled' : 'Configured';
    } else if (target === 'codex') {
      try {
        const toml = await fs.readFile(path.join(home, '.codex/config.toml'), 'utf8');
        if (/^\[mcp_servers\.(port|poko)\]/m.test(toml)) return 'Configured';
      } catch {}
      return 'Not configured';
    } else if (target === 'antigravity') {
      const file = path.join(home, '.gemini/config/mcp_config.json');
      try {
        const servers = JSON.parse(await fs.readFile(file, 'utf8')).mcpServers;
        existing = servers?.port ?? servers?.poko;
        return !existing ? 'Not configured' : matchesBridgeEntry(existing) ? 'Configured' : 'Different configuration';
      } catch {
        return 'Not configured';
      }
    } else {
      const file = target === 'cursor' ? path.join(home, '.cursor/mcp.json') : path.join(home, '.claude.json');
      try {
        const servers = JSON.parse(await fs.readFile(file, 'utf8')).mcpServers;
        existing = servers?.port ?? servers?.poko;
        return !existing ? 'Not configured' : matchesBridgeEntry(existing) ? 'Configured' : 'Different configuration';
      } catch {
        return 'Not configured';
      }
    }
  } catch {
    return 'Cannot read configuration';
  }
}

async function backup(file) {
  const stamp = new Date().toISOString().replaceAll(':', '-');
  try { await fs.copyFile(file, `${file}.port-backup-${stamp}`); } catch (e) { if (e.code !== 'ENOENT') throw e; }
}

async function installMcp(target) {
  if (target === 'opencode') {
    const configs = await openCodeConfig();
    if (configs.some(x => x.config.mcp?.port !== undefined && !matchesOpenCode(x.config.mcp.port))) {
      throw new Error('OpenCode already has a different port MCP server. Rename it before proceeding.');
    }
    const {file, source, config} = configs.at(-1);
    if (dry) { console.log(`Would merge opencode: ${file}`, openCodeEntry); return; }
    const next = applyEdits(source, modify(source, ['mcp', 'port'], {...config.mcp?.port, ...openCodeEntry}, {formattingOptions: {insertSpaces: true, tabSize: 2, eol: '\n'}}));
    await backup(file);
    await fs.mkdir(path.dirname(file), {recursive: true});
    const temp = `${file}.port-tmp`;
    await fs.writeFile(temp, next, {mode: 0o600});
    await fs.rename(temp, file);
    console.log('OpenCode: MCP connected (existing configuration preserved)');
  } else if (target === 'codex') {
    const file = path.join(home, '.codex/config.toml');
    const check = spawnSync('codex', ['mcp', 'get', 'port', '--json'], {encoding: 'utf8', timeout: 10000});
    if (check.status === 0) {
      console.log('Codex: Poko MCP already connected');
      return;
    }
    if (dry) { console.log('Would register Codex stdio MCP:', entry); return; }
    await backup(file);
    const result = spawnSync('codex', ['mcp', 'add', 'port', '--', entry.command, ...entry.args], {encoding: 'utf8', timeout: 10000});
    if (result.status !== 0) {
      const toml = `\n[mcp_servers.port]\ncommand = "${entry.command}"\nargs = [${entry.args.map(a => `"${a}"`).join(', ')}]\n`;
      await fs.appendFile(file, toml);
    }
    console.log('Codex: MCP connected');
  } else if (target === 'antigravity') {
    const file = path.join(home, '.gemini/config/mcp_config.json');
    let config = {};
    try { config = JSON.parse(await fs.readFile(file, 'utf8')); } catch {}
    if (!config.mcpServers) config.mcpServers = {};
    config.mcpServers.port = {
      command: entry.command,
      args: entry.args
    };
    if (dry) { console.log('Would update Antigravity mcp_config.json:', config); return; }
    await backup(file);
    await fs.mkdir(path.dirname(file), {recursive: true});
    const temp = `${file}.port-tmp`;
    await fs.writeFile(temp, JSON.stringify(config, null, 2) + '\n', {mode: 0o600});
    await fs.rename(temp, file);
    console.log('Antigravity: MCP connected');
  } else {
    const file = target === 'cursor' ? path.join(home, '.cursor/mcp.json') : path.join(home, '.claude.json');
    let config = {};
    try { config = JSON.parse(await fs.readFile(file, 'utf8')); } catch (e) { if (e.code !== 'ENOENT') throw e; }
    if (!config.mcpServers) config.mcpServers = {};
    config.mcpServers.port = {type: 'stdio', ...entry};
    if (dry) { console.log(`Would merge ${target}: ${file}`, entry); return; }
    await backup(file);
    await fs.mkdir(path.dirname(file), {recursive: true});
    const temp = `${file}.port-tmp`;
    await fs.writeFile(temp, JSON.stringify(config, null, 2) + '\n', {mode: 0o600});
    await fs.rename(temp, file);
    console.log(`${agentNames[target]}: MCP connected (existing configuration preserved)`);
  }
}

async function removeMcp(target) {
  if (target === 'opencode') {
    const configs = await openCodeConfig();
    const {file, source, config} = configs.at(-1);
    if (config.mcp?.port) {
      const next = applyEdits(source, modify(source, ['mcp', 'port'], undefined, {}));
      await fs.writeFile(file, next, 'utf8');
      console.log('OpenCode: MCP removed');
    }
  } else if (target === 'codex') {
    spawnSync('codex', ['mcp', 'remove', 'port'], {encoding: 'utf8', timeout: 5000});
    const file = path.join(home, '.codex/config.toml');
    try {
      let toml = await fs.readFile(file, 'utf8');
      if (toml.includes('[mcp_servers.port]')) {
        toml = toml.replace(/\[mcp_servers\.port\][^[]*/g, '');
        await fs.writeFile(file, toml, 'utf8');
      }
    } catch {}
    console.log('Codex: MCP removed');
  } else if (target === 'antigravity') {
    const file = path.join(home, '.gemini/config/mcp_config.json');
    try {
      const config = JSON.parse(await fs.readFile(file, 'utf8'));
      if (config.mcpServers?.port) {
        delete config.mcpServers.port;
        await fs.writeFile(file, JSON.stringify(config, null, 2) + '\n', 'utf8');
      }
    } catch {}
    console.log('Antigravity: MCP removed');
  } else {
    const file = target === 'cursor' ? path.join(home, '.cursor/mcp.json') : path.join(home, '.claude.json');
    try {
      const config = JSON.parse(await fs.readFile(file, 'utf8'));
      if (config.mcpServers?.port) {
        delete config.mcpServers.port;
        await fs.writeFile(file, JSON.stringify(config, null, 2) + '\n', 'utf8');
      }
    } catch {}
    console.log(`${agentNames[target]}: MCP removed`);
  }
}

// -------------------------------------------------------------
// Entry Point Handling
// -------------------------------------------------------------

if (args.includes('--status')) {
  const result = [];
  for (const agent of allAgents) {
    const mcpStatus = await checkMcpStatus(agent);
    const skillStatus = await checkSkillStatus(agent);
    const detected = await isAgentDetected(agent);
    result.push({
      id: agent,
      name: agentNames[agent],
      status: mcpStatus,
      mcp: mcpStatus,
      skill: skillStatus,
      detected
    });
  }
  process.stdout.write(JSON.stringify(result) + '\n');
} else {
  const isSkillAction = args.includes('skill') || args.includes('--skill');
  const isRemoveAction = args.includes('remove') || args.includes('--remove');
  const filteredTargets = args.filter(a => !a.startsWith('--') && a !== 'skill' && a !== 'mcp' && a !== 'remove');
  const selectedTargets = filteredTargets.length ? filteredTargets : allAgents;

  for (const agent of selectedTargets) {
    if (!allAgents.includes(agent)) {
      console.error(`Unknown agent: ${agent}. Choose from: ${allAgents.join(', ')}`);
      process.exit(1);
    }
    if (isRemoveAction) {
      if (isSkillAction) {
        await removeSkill(agent);
      } else {
        await removeMcp(agent);
      }
    } else {
      if (isSkillAction) {
        await installSkill(agent);
      } else {
        await installMcp(agent);
      }
    }
  }

  if (!isSkillAction && !isRemoveAction) {
    console.log('Restart agent sessions to load the Poko tools.');
  }
}
