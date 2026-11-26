import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { resolveHarness, resolveExecutable, resolveAdapter } from "./harness-policy.js";

test("a harness must be explicitly selected in Gooarchy Ask", () => {
  assert.throws(() => resolveHarness({}), /Choose a harness/);
  assert.equal(resolveHarness({ ASK_AGENT: "claude" }), "claude");
  assert.equal(resolveHarness({ ASK_AGENT: "codex" }), "codex");
  assert.throws(() => resolveHarness({ ASK_AGENT: "gemini" }), /Choose Codex or Claude/);
});

test("Claude uses a separately installed adapter and honors explicit argv", () => {
  const bin = mkdtempSync(join(tmpdir(), "ask-adapter-"));
  try {
    const env = { PATH: bin };
    assert.throws(() => resolveAdapter("claude", "/", env), /ACP adapter is missing/);
    const adapter = join(bin, "claude-agent-acp");
    writeFileSync(adapter, "#!/bin/sh\nexit 0\n", { mode: 0o700 });
    assert.deepEqual(resolveAdapter("claude", "/", env), [adapter]);
    assert.deepEqual(resolveAdapter("claude", "/", {
      ...env, ASK_CLAUDE_ACP_COMMAND: JSON.stringify([adapter, "--flag"]),
      ASK_ACP_COMMAND: '["unused"]',
    }), [adapter, "--flag"]);
    assert.deepEqual(resolveAdapter("codex", "/example", env),
      ["/example/node_modules/.bin/codex-acp"]);
  } finally { rmSync(bin, { recursive: true }); }
});

test("PATH and executable overrides, without bundled fallback", () => {
  const bin = mkdtempSync(join(tmpdir(), "ask-path-"));
  try {
    const env = { PATH: bin };
    assert.throws(() => resolveExecutable("codex", env), /system PATH/);
    mkdirSync(join(bin, "codex"));
    assert.throws(() => resolveExecutable("codex", env), /system PATH/);
    const executable = join(bin, "custom-harness");
    writeFileSync(executable, "#!/bin/sh\nexit 0\n", { mode: 0o700 });
    assert.equal(resolveExecutable("codex", { ...env, CODEX_PATH: executable }), executable);
    assert.equal(resolveExecutable("codex", { ...env, CODEX_PATH: "custom-harness" }), executable);
    assert.equal(resolveExecutable("claude", { ...env, CLAUDE_CODE_EXECUTABLE: executable }), executable);
    assert.throws(() => resolveExecutable("codex", { ...env, CODEX_PATH: "/nonexistent/ask-test" }), /configured executable/);
  } finally { rmSync(bin, { recursive: true }); }
});

test("startup failures reach the popup as structured fatal events", () => {
  const home = mkdtempSync(join(tmpdir(), "ask-startup-"));
  try {
    for (const [overrides, expected] of [
      [{ ASK_AGENT: "" }, /Choose a harness/],
      [{ ASK_AGENT: "claude", PATH: "" }, /ACP adapter is missing/],
      [{ ASK_AGENT: "gemini" }, /Choose Codex or Claude/],
      [{ ASK_AGENT: "codex", CODEX_PATH: "/nonexistent/ask-test" }, /configured executable/],
      [{ ASK_AGENT: "codex", ASK_CODEX_ACP_COMMAND: "invalid" }, /JSON array/],
    ]) {
      const result = spawnSync(process.execPath, [new URL("bridge.js", import.meta.url).pathname], {
        env: { ...process.env, HOME: home, ASK_ACP_COMMAND: "", ASK_CODEX_ACP_COMMAND: "", ASK_CLAUDE_ACP_COMMAND: "", ...overrides },
        encoding: "utf8", timeout: 10000,
      });
      assert.equal(result.status, 1, result.stderr);
      const event = JSON.parse(result.stdout.trim());
      assert.equal(event.type, "fatal");
      assert.match(event.message, expected);
    }
  } finally { rmSync(home, { recursive: true }); }
});
