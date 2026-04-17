#!/usr/bin/env node
// register-mcp.mjs — Idempotently register the mmteam MCP server in
// ~/.claude.json so Claude Code can call mcp__mmteam__a2a_* tools natively.
//
// Safety:
//   - Always creates ~/.claude.json.bak-<timestamp> before writing.
//   - If mcpServers.mmteam already exists with the same args, exits 0 silent.
//   - If it exists with different args, updates in place (still backs up first).
//   - If ~/.claude.json is missing, creates a minimal one.
//
// Usage:
//   node register-mcp.mjs <absolute-path-to-mmteam-mcp.py>
//   node register-mcp.mjs --remove          # uninstall (removes mmteam key)
//   node register-mcp.mjs --status          # print current registration
//
// Exit codes: 0 = ok / no-op, 1 = error, 2 = already registered same args.

import { readFileSync, writeFileSync, existsSync, copyFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";

const CLAUDE_JSON = path.join(process.env.HOME || "", ".claude.json");
const KEY = "mmteam";

function timestamp() {
  return new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19);
}

function loadConfig() {
  if (!existsSync(CLAUDE_JSON)) return {};
  try {
    return JSON.parse(readFileSync(CLAUDE_JSON, "utf8"));
  } catch (err) {
    process.stderr.write(`register-mcp: cannot parse ${CLAUDE_JSON}: ${err.message}\n`);
    process.exit(1);
  }
}

function backup() {
  if (!existsSync(CLAUDE_JSON)) return null;
  const dst = `${CLAUDE_JSON}.bak-${timestamp()}`;
  copyFileSync(CLAUDE_JSON, dst);
  return dst;
}

function saveConfig(cfg) {
  const bak = backup();
  writeFileSync(CLAUDE_JSON, JSON.stringify(cfg, null, 2) + "\n", "utf8");
  return bak;
}

function currentEntry(cfg) {
  return cfg?.mcpServers?.[KEY] || null;
}

function sameArgs(a, b) {
  if (!a || !b) return false;
  if (a.command !== b.command) return false;
  if (!Array.isArray(a.args) || !Array.isArray(b.args)) return false;
  if (a.args.length !== b.args.length) return false;
  return a.args.every((v, i) => v === b.args[i]);
}

function cmdRegister(scriptPath) {
  if (!scriptPath) {
    process.stderr.write("register-mcp: missing <absolute-path-to-mmteam-mcp.py>\n");
    process.exit(1);
  }
  if (!path.isAbsolute(scriptPath)) {
    process.stderr.write(`register-mcp: path must be absolute (got '${scriptPath}')\n`);
    process.exit(1);
  }
  if (!existsSync(scriptPath)) {
    process.stderr.write(`register-mcp: script not found: ${scriptPath}\n`);
    process.exit(1);
  }

  const cfg = loadConfig();
  const desired = {
    type: "stdio",
    command: "python3",
    args: [scriptPath],
  };
  const existing = currentEntry(cfg);

  if (sameArgs(existing, desired)) {
    process.stdout.write(`register-mcp: mcpServers.${KEY} already up to date — no-op.\n`);
    process.exit(2);
  }

  if (!cfg.mcpServers) cfg.mcpServers = {};
  cfg.mcpServers[KEY] = desired;

  const bak = saveConfig(cfg);
  if (bak) {
    process.stdout.write(`register-mcp: backed up → ${bak}\n`);
  }
  process.stdout.write(
    `register-mcp: registered mcpServers.${KEY} = python3 ${scriptPath}\n` +
      `  Restart Claude Code to activate mcp__mmteam__a2a_* tools.\n`
  );
  process.exit(0);
}

function cmdRemove() {
  const cfg = loadConfig();
  if (!cfg?.mcpServers?.[KEY]) {
    process.stdout.write(`register-mcp: mcpServers.${KEY} not present — nothing to remove.\n`);
    process.exit(0);
  }
  delete cfg.mcpServers[KEY];
  const bak = saveConfig(cfg);
  if (bak) {
    process.stdout.write(`register-mcp: backed up → ${bak}\n`);
  }
  process.stdout.write(`register-mcp: removed mcpServers.${KEY}.\n`);
  process.exit(0);
}

function cmdStatus() {
  const cfg = loadConfig();
  const e = currentEntry(cfg);
  if (!e) {
    process.stdout.write(`register-mcp: mcpServers.${KEY} — NOT REGISTERED\n`);
    process.exit(1);
  }
  process.stdout.write(
    `register-mcp: mcpServers.${KEY}\n` +
      `  type    : ${e.type || "(default)"}\n` +
      `  command : ${e.command}\n` +
      `  args    : ${JSON.stringify(e.args)}\n`
  );
  process.exit(0);
}

const arg = process.argv[2];
if (arg === "--remove") cmdRemove();
else if (arg === "--status") cmdStatus();
else cmdRegister(arg);
