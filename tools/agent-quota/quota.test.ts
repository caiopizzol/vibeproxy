import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import fixture from "./fixtures/quota.json";
import manifest from "./fixtures/manifest.json";
import { parseQuota, query, QuotaError, render, type Api } from "./quota.ts";
import { passwordFromFile, proxyApi } from "./cli.ts";

const id = (id: string) => createHash("sha256").update(id).digest("hex");
const now = () => "2030-01-01T00:00:00Z";
const ok: Api = async route => route === "auth-files" ? fixture.accounts : { status_code: 200, body: JSON.stringify(fixture.current) };

test("fixture bytes match manifest", async () => {
  expect(createHash("sha256").update(await readFile(new URL("./fixtures/quota.json", import.meta.url))).digest("hex")).toBe(manifest.sha256);
});
test("current scoped windows are retained without legacy duplication or spending", () => {
  const windows = parseQuota(fixture.current);
  expect(windows).toHaveLength(3);
  expect(windows[0]?.remainingPercent).toBe(99);
  expect(windows[2]?.remainingPercent).toBe(73);
  expect(windows[2]?.scope).toEqual(fixture.current.limits[2]?.scope);
});
test("legacy full and exhausted quota remain distinct from missing quota", () => {
  expect(parseQuota(fixture.legacy).map(row => row.remainingPercent)).toEqual([100, 0]);
  for (const value of [null, {}, { limits: [] }, { ...fixture.legacy, limits: null }]) {
    expect(() => parseQuota(value)).toThrow(QuotaError);
  }
  expect(parseQuota(fixture.current)).toHaveLength(3);
});
test("invalid percentages, dates and rows refuse; valid window controls pass", () => {
  for (const percent of [null, "27", -1, 101, Infinity, NaN]) {
    expect(() => parseQuota({ limits: [{ ...fixture.current.limits[0], percent }] })).toThrow();
  }
  expect(() => parseQuota({ limits: [null] })).toThrow();
  expect(() => parseQuota({ limits: [{ ...fixture.current.limits[0], resets_at: "invalid" }] })).toThrow();
  expect(parseQuota({ limits: [fixture.current.limits[0]] })[0]?.remainingPercent).toBe(99);
});
test("requests use proxy token substitution, skip disabled/other accounts and preserve routing failure", async () => {
  const calls: Array<{route:string; body: unknown}> = [];
  const report = await query(async (route, body) => { calls.push({route,body}); return ok(route,body); }, id, now);
  expect(calls).toHaveLength(2);
  expect(calls[1]?.body).toMatchObject({ authIndex: "fixture-enabled", method: "GET", url: "https://api.anthropic.com/api/oauth/usage", header: { Authorization: "Bearer $TOKEN$" } });
  expect(report.accounts.map(row => row.status)).toEqual(["ok", "disabled"]);
  expect(report.accounts[0]).toMatchObject({proxyStatus:"error",unavailable:true,checkedAt:now()});
  expect(render(report)).toContain("73% remaining");
  expect(JSON.stringify(report)).not.toContain("fixture-enabled");
});
test("failed HTTP or malformed body is unknown and cannot leak provider diagnostics", async () => {
  for (const response of [{status_code:401,body:fixture.secret}, {status_code:200,body:fixture.secret}, {status_code:200,body:{limits:[]}}]) {
    const report = await query(async route => route === "auth-files" ? fixture.accounts : response, id, now);
    expect(report.accounts[0]?.status).toBe("unknown");
    expect(report.accounts[0]?.windows).toEqual([]);
    expect(JSON.stringify(report)).not.toContain(fixture.secret);
  }
  expect((await query(ok,id,now)).accounts[0]?.status).toBe("ok");
});
test("transport errors stay safe; timeout is distinct", async () => {
  for (const error of [new Error(fixture.secret), new QuotaError("timeout")]) {
    const report = await query(async route => { if(route === "auth-files") return fixture.accounts; throw error; },id,now);
    expect(report.accounts[0]?.status).toBe("unknown");
    expect(report.accounts[0]?.error).toBe(error instanceof QuotaError ? "timeout" : "quota-request-failed");
    expect(JSON.stringify(report)).not.toContain(fixture.secret);
  }
});
test("missing account identity or disabled state never dispatches", async () => {
  for (const change of [{auth_index:null}, {disabled:null}]) {
    let requests = 0;
    const report = await query(async route => { requests++; return {files:[{...fixture.accounts.files[0],...change}]}; }, id, now);
    expect(requests).toBe(1);
    expect(report.accounts[0]?.status).toBe("unknown");
  }
  expect((await query(ok,id,now)).accounts[0]?.status).toBe("ok");
});
test("management credentials stay in fixed loopback request headers; redirects refused", async () => {
  const request = Object.assign(async (url: string | URL | Request, init?: RequestInit) => {
    expect(url).toBe("http://127.0.0.1:18317/v0/management/auth-files");
    expect(init?.redirect).toBe("error");
    expect(init?.headers).toMatchObject({Authorization:`Bearer ${fixture.secret}`});
    return Response.json(fixture.accounts);
  }, { preconnect: fetch.preconnect });
  expect(await proxyApi(fixture.secret,request)("auth-files")).toEqual(fixture.accounts);
  const failed = Object.assign(async () => { throw new Error(fixture.secret); }, { preconnect: fetch.preconnect });
  await expect(proxyApi(fixture.secret,failed)("auth-files")).rejects.toThrow("proxy-unavailable");
});
test("credential file is parsed as data, with equals preserved", () => {
  expect(passwordFromFile("MANAGEMENT_PASSWORD='value=with=equals'\n")).toBe("value=with=equals");
  expect(passwordFromFile("MANAGEMENT_PASSWORD=$(not-executed)")).toBe("$(not-executed)");
  for (const text of ["", "MANAGEMENT_PASSWORD=", "MANAGEMENT_PASSWORD=a\nMANAGEMENT_PASSWORD=b"]) expect(() => passwordFromFile(text)).toThrow("credential-unavailable");
  expect(passwordFromFile(`MANAGEMENT_PASSWORD=${fixture.secret}`)).toBe(fixture.secret);
});
