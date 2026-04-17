#!/usr/bin/env node
// mmteam-bridge.mjs — Thin wrapper between Claude Code slash commands and
// the vendored `mmteam` CLI. Each /mmteam:<verb> slash routes here with
// argv[2] = subcommand and the rest forwarded verbatim.
//
// Responsibilities:
//   1. Locate the mmteam binary (prefer $MMTEAM_BIN, else search PATH,
//      else fall back to ../../../bin/mmteam relative to this file — works
//      both when installed to ~/.local/bin and when running from repo).
//   2. Spawn it with inherited stdio so the user sees live output.
//   3. Propagate exit code faithfully.
//
// We deliberately do NOT parse mmteam's own flags here — that keeps the
// bridge forward-compatible with new mmteam subcommands without needing
// plugin changes.

import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

function resolveMmteamBin() {
  if (process.env.MMTEAM_BIN && existsSync(process.env.MMTEAM_BIN)) {
    return process.env.MMTEAM_BIN;
  }

  const candidates = [
    // installed locations
    path.join(process.env.HOME || "", ".local", "bin", "mmteam"),
    path.join(process.env.HOME || "", "bin", "mmteam"),
    // repo-relative (running from clone without install)
    path.resolve(__dirname, "..", "..", "..", "bin", "mmteam"),
    // /usr/local
    "/usr/local/bin/mmteam",
    "/opt/homebrew/bin/mmteam",
  ];

  for (const p of candidates) {
    if (p && existsSync(p)) return p;
  }

  // Let PATH lookup handle it (spawn with "mmteam")
  return "mmteam";
}

function die(msg, code = 1) {
  process.stderr.write(`mmteam-bridge: ${msg}\n`);
  process.exit(code);
}

const [, , subcommand, ...rest] = process.argv;

if (!subcommand) {
  die(
    "usage: mmteam-bridge <subcommand> [args...]\n" +
      "       (this script is invoked by /mmteam:* slash commands — not meant for direct use)"
  );
}

const bin = resolveMmteamBin();

// mmteam CLI groups a2a-related verbs under `mmteam a2a <verb>`.
// Slash commands flatten that: /mmteam:send maps to `mmteam a2a send`.
// We translate here so command .md files stay readable.
const A2A_VERBS = new Set([
  "send",
  "ask",
  "fanout",
  "pipeline",
  "watch",
  "unwatch",
  "follow",
  "ls",
  "card",
  "get",
  "cancel",
  "register",
  "discover",
  "quota",
  "routes",
  "who",
  "cost",
]);

// Top-level mmteam verbs that are NOT under `a2a`:
// create, spawn, stop, destroy, status, tasks, msg, inbox, help
const TOPLEVEL = new Set([
  "create",
  "spawn",
  "stop",
  "destroy",
  "status",
  "tasks",
  "msg",
  "inbox",
  "help",
  "version",
]);

let argv;
if (subcommand === "a2a") {
  // Pass-through: slash command already specified `a2a <verb>`
  argv = ["a2a", ...rest];
} else if (A2A_VERBS.has(subcommand)) {
  argv = ["a2a", subcommand, ...rest];
} else if (TOPLEVEL.has(subcommand)) {
  argv = [subcommand, ...rest];
} else {
  // Unknown — let mmteam decide (it'll show usage)
  argv = [subcommand, ...rest];
}

const child = spawn(bin, argv, {
  stdio: "inherit",
  env: process.env,
});

child.on("error", (err) => {
  if (err.code === "ENOENT") {
    die(
      `mmteam binary not found. Tried: $MMTEAM_BIN, ~/.local/bin/mmteam, ~/bin/mmteam, repo bin/, /usr/local/bin, /opt/homebrew/bin, PATH.\n` +
        `  Run 'bash install.sh' from the mmteam-cc repo to install, or set MMTEAM_BIN to the absolute path.`
    );
  }
  die(`spawn error: ${err.message}`);
});

child.on("exit", (code, signal) => {
  if (signal) {
    process.stderr.write(`mmteam-bridge: child killed by signal ${signal}\n`);
    process.exit(128);
  }
  process.exit(code ?? 0);
});
