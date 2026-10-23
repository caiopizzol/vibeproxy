#!/usr/bin/env bun
import { createHash } from "node:crypto";
import { execFile } from "node:child_process";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { QuotaError, query, render, type Api } from "./quota.ts";

export function passwordFromFile(text: string): string {
  const lines = text.split(/\r?\n/).filter(line => /^MANAGEMENT_PASSWORD=/.test(line));
  if (lines.length !== 1) throw new QuotaError("credential-unavailable");
  let password = lines[0]!.slice("MANAGEMENT_PASSWORD=".length).trim();
  if ((password.startsWith('"') && password.endsWith('"')) || (password.startsWith("'") && password.endsWith("'"))) password = password.slice(1, -1);
  if (!password || /[\r\n]/.test(password)) throw new QuotaError("credential-unavailable");
  return password;
}

export function proxyApi(password: string, request: typeof fetch = fetch): Api {
  const signal = AbortSignal.timeout(25_000);
  return async (route, body) => {
    try {
      const response = await request(`http://127.0.0.1:18317/v0/management/${route}`, {
        method: body ? "POST" : "GET", redirect: "error", signal,
        headers: { Authorization: `Bearer ${password}`, "Content-Type": "application/json" },
        ...(body ? { body: JSON.stringify(body) } : {}),
      });
      if (!response.ok) throw new QuotaError(`proxy-http-${response.status}`);
      try { return await response.json(); }
      catch { throw new QuotaError(signal.aborted ? "timeout" : "invalid-proxy-response"); }
    } catch (error) {
      if (signal.aborted) throw new QuotaError("timeout");
      throw error instanceof QuotaError ? error : new QuotaError("proxy-unavailable");
    }
  };
}

async function main() {
  let values: { json?: boolean; provider?: string; local?: boolean; help?: boolean };
  try {
    ({ values } = parseArgs({ args: process.argv.slice(2), strict: true, allowPositionals: false,
      options: { json: { type: "boolean" }, provider: { type: "string" }, local: { type: "boolean" }, help: { type: "boolean" } } }));
  } catch { throw new QuotaError("unsupported-input"); }
  if (values.help) {
    console.log("Usage: agent-quota [--provider claude] [--json] [--local]\nQueries Claude subscription windows, not paid overage. macOS uses SSH to nucbox; --local queries this host. Linux queries locally. Exit 2 means missing or incomplete quota.");
    return;
  }
  if (values.provider !== undefined && values.provider !== "claude") throw new QuotaError("unsupported-provider");
  if (process.platform === "darwin" && !values.local) {
    const args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "nucbox", ".local/bin/agent-quota", "--local", "--provider", "claude"];
    if (values.json) args.push("--json");
    await new Promise<void>((resolve, reject) => {
      execFile("ssh", args, { timeout: 35_000, maxBuffer: 1_048_576 }, (error, stdout) => {
        if (error && (error.killed || typeof error.code !== "number" || ![1, 2].includes(error.code))) {
          reject(new QuotaError(error.killed ? "timeout" : "remote-unavailable"));
          return;
        }
        process.stdout.write(stdout);
        process.exitCode = error?.code ?? 0;
        resolve();
      });
    });
    return;
  }
  let password: string;
  try { password = passwordFromFile(await readFile(join(homedir(), ".config/vibeproxy-nucbox/management.env"), "utf8")); }
  catch { throw new QuotaError("credential-unavailable"); }
  const report = await query(proxyApi(password), id => "claude-" + createHash("sha256").update(id).digest("hex").slice(0, 12));
  console.log(values.json ? JSON.stringify(report, null, 2) : render(report));
  if (!report.accounts.some(account => account.status === "ok") || report.accounts.some(account => account.status === "unknown")) process.exitCode = 2;
}

if (import.meta.main) {
  await main().catch(error => {
    console.log(JSON.stringify({ status: "unknown", error: error instanceof QuotaError ? error.code : "query-failed" }));
    process.exitCode = 1;
  });
}
