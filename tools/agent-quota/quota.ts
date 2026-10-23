export function object(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown> : null;
}

export class QuotaError extends Error {
  constructor(readonly code: string) { super(code); }
}

export interface Window {
  name: string;
  scope: unknown;
  usedPercent: number;
  remainingPercent: number;
  resetsAt: string | null;
}

function window(name: unknown, percent: unknown, reset: unknown, scope: unknown): Window {
  if (typeof name !== "string" || !name || typeof percent !== "number" ||
      !Number.isFinite(percent) || percent < 0 || percent > 100 ||
      !(reset === null || (typeof reset === "string" && Number.isFinite(Date.parse(reset))))) {
    throw new QuotaError("invalid-quota-response");
  }
  return { name, scope: scope ?? null, usedPercent: percent, remainingPercent: 100 - percent, resetsAt: reset };
}

export function parseQuota(value: unknown): Window[] {
  const data = object(value);
  if (!data) throw new QuotaError("invalid-quota-response");
  if ("limits" in data) {
    if (!Array.isArray(data.limits) || !data.limits.length) throw new QuotaError("unknown-quota");
    return data.limits.map((value: unknown) => {
      const row = object(value);
      if (!row) throw new QuotaError("invalid-quota-response");
      // Keep provider scopes intact: model and surface limits are not interchangeable.
      return window(row.kind, row.percent, row.resets_at, row.scope);
    });
  }
  const windows: Window[] = [];
  for (const [name, value] of Object.entries(data)) {
    if (!(name === "five_hour" || name === "seven_day" || name.startsWith("seven_day_")) || value === null) continue;
    const row = object(value);
    if (!row) throw new QuotaError("invalid-quota-response");
    windows.push(window(name, row.utilization, row.resets_at, null));
  }
  if (!windows.length) throw new QuotaError("unknown-quota");
  return windows;
}

export type Api = (route: "auth-files" | "api-call", body?: Record<string, unknown>) => Promise<unknown>;
export interface Account {
  account: string;
  proxyStatus: string;
  unavailable: boolean | null;
  nextRetryAfter: string | null;
  status: "ok" | "unknown" | "disabled";
  checkedAt: string;
  windows: Window[];
  error?: string;
}
export interface Report { provider: "claude"; accounts: Account[]; }

export async function query(api: Api, identify: (id: string) => string, now = () => new Date().toISOString()): Promise<Report> {
  const data = object(await api("auth-files"));
  if (!data || !Array.isArray(data.files)) throw new QuotaError("invalid-account-response");
  const accounts: Account[] = [];
  for (const value of data.files) {
    const row = object(value);
    if (!row) throw new QuotaError("invalid-account-response");
    if ((row.provider ?? row.type) !== "claude") continue;
    const id = typeof row.auth_index === "string" ? row.auth_index : "";
    const account: Account = {
      account: id ? identify(id) : "unidentified",
      proxyStatus: typeof row.status === "string" ? row.status : "unknown",
      unavailable: typeof row.unavailable === "boolean" ? row.unavailable : null,
      nextRetryAfter: typeof row.next_retry_after === "string" ? row.next_retry_after : null,
      status: "unknown", checkedAt: now(), windows: [],
    };
    if (row.disabled === true) account.status = "disabled";
    else if (!id || row.disabled !== false) account.error = "invalid-account-response";
    else {
      try {
        const response = object(await api("api-call", {
          authIndex: id, method: "GET", url: "https://api.anthropic.com/api/oauth/usage",
          header: { Authorization: "Bearer $TOKEN$", "Content-Type": "application/json", "anthropic-beta": "oauth-2025-04-20" },
        }));
        if (!response || typeof response.status_code !== "number") throw new QuotaError("invalid-proxy-response");
        if (response.status_code !== 200) throw new QuotaError(`upstream-http-${response.status_code}`);
        let body: unknown = response.body;
        if (typeof body === "string") {
          try { body = JSON.parse(body); } catch { throw new QuotaError("invalid-quota-response"); }
        }
        account.windows = parseQuota(body);
        account.status = "ok";
      } catch (error) {
        account.error = error instanceof QuotaError ? error.code : "quota-request-failed";
      }
      account.checkedAt = now();
    }
    accounts.push(account);
  }
  return { provider: "claude", accounts };
}

export function render(report: Report): string {
  if (!report.accounts.length) return "No Claude accounts found.";
  return report.accounts.map(account => {
    const lines = [`${account.account}: quota=${account.status}; proxy=${account.proxyStatus}; unavailable=${account.unavailable ?? "unknown"}; checked=${account.checkedAt}`];
    if (account.nextRetryAfter) lines.push(`  proxy retry: ${account.nextRetryAfter}`);
    if (account.error) lines.push(`  ${account.error}`);
    for (const row of account.windows) {
      lines.push(`  ${row.name}${row.scope === null ? "" : ` ${JSON.stringify(row.scope)}`}: ${row.remainingPercent}% remaining; resets ${row.resetsAt ?? "unknown"}`);
    }
    return lines.join("\n");
  }).join("\n");
}
