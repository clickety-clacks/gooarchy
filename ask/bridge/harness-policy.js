import { accessSync, statSync, constants } from "node:fs";
import { join } from "node:path";

export function resolveHarness(env = process.env) {
  const agent = String(env.ASK_AGENT || "").trim();
  if (!agent)
    throw new Error("Choose a harness in Gooarchy Ask Settings (Ctrl+,), then submit again.");
  if (agent !== "codex" && agent !== "claude")
    throw new Error("Choose Codex or Claude in Gooarchy Ask Settings (Ctrl+,).");
  return agent;
}

function executablePath(executable, path) {
  const candidates = executable.includes("/") ? [executable]
    : (path || "").split(":").filter(Boolean).map(directory => join(directory, executable));
  for (const candidate of candidates) {
    try {
      accessSync(candidate, constants.X_OK);
      if (statSync(candidate).isFile()) return candidate;
    } catch {}
  }
  return "";
}

export function resolveExecutable(agent, env = process.env) {
  const override = env[agent === "codex" ? "CODEX_PATH" : "CLAUDE_CODE_EXECUTABLE"];
  const path = executablePath(override || agent, env.PATH);
  if (path) return path;

  const name = agent === "codex" ? "Codex" : "Claude Code";
  const reason = override ? "the configured executable is missing or not executable"
    : "it is not on the system PATH";
  throw new Error(`${name} could not be launched: ${reason}. Repair its installation or choose another harness in Settings (Ctrl+,).`);
}

export function resolveAdapter(agent, bridgeDirectory, env = process.env) {
  const specificKey = agent === "codex" ? "ASK_CODEX_ACP_COMMAND" : "ASK_CLAUDE_ACP_COMMAND";
  const key = env[specificKey]?.trim() ? specificKey : "ASK_ACP_COMMAND";
  const raw = env[key]?.trim();
  if (!raw && agent === "codex") return [join(bridgeDirectory, "node_modules", ".bin", "codex-acp")];

  let command = ["claude-agent-acp"];
  if (raw) {
    try { command = JSON.parse(raw); }
    catch { throw new Error(`${key} must be a JSON array of arguments.`); }
    if (!Array.isArray(command) || !command.length
        || command.some(argument => typeof argument !== "string" || !argument.trim()))
      throw new Error(`${key} must be a non-empty JSON array of non-empty strings.`);
  }

  const executable = executablePath(command[0], env.PATH);
  if (executable) return [executable, ...command.slice(1)];
  if (agent === "claude")
    throw new Error("Claude's ACP adapter is missing. Install claude-agent-acp on PATH or set ASK_CLAUDE_ACP_COMMAND to its command as a JSON array.");
  throw new Error(`Could not launch the ACP adapter configured by ${key}: ${command[0]} is missing or not executable.`);
}
