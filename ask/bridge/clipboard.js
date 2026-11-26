import { readClipboard } from "./image-paste.js";

const requestId = Number(process.argv[2]);
const controller = new AbortController();
process.on("SIGTERM", () => controller.abort());

let event;
try {
  const result = await readClipboard(JSON.parse(process.argv[3]), { signal: controller.signal });
  event = { type: "clipboard", requestId, ...result };
} catch (error) {
  event = { type: "clipboard_error", requestId, message: error.message };
}
if (!controller.signal.aborted) process.stdout.write(`${JSON.stringify(event)}\n`);
