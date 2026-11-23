import { join } from "node:path";
import { chmodSync, mkdirSync } from "node:fs";
import { timingSafeEqual } from "node:crypto";
import schemaSql from "../schema.sql" with { type: "text" };
import worker from "../src/index";
import { APPS, type AppDef } from "../src/apps";
import type { Env } from "../src/env";
import { kvGet, kvSet } from "../src/util";
import { runAscReviews, runAscSales } from "../src/connectors/asc";
import { runPlay } from "../src/connectors/play";
import { runPlaySales } from "../src/connectors/playsales";
import { runIosAcq, runPlayAcq } from "../src/connectors/acquisition";
import { runRevenueCat } from "../src/connectors/revenuecat";
import { runRevenueCatCharts } from "../src/connectors/rccharts";
import { runStripe } from "../src/connectors/stripe";
import { runHealth } from "../src/connectors/health";
import { runCloudflare } from "../src/connectors/cloudflare";
import { META_ACCOUNTS, runMeta } from "../src/connectors/meta";
import { runGa4Daily, runGa4Deep, runGa4Realtime } from "../src/connectors/ga4";
import { LocalD1 } from "./d1";
import { runAnalyst } from "../src/analyst";
import { handleRcWebhook } from "../src/connectors/rcwebhook";
import { setupRoutes } from "./setup";

export type Secrets = {
  ASC_KEY_ID?: string;
  ASC_ISSUER_ID?: string;
  ASC_P8?: string;
  ASC_VENDOR?: string;
  GOOGLE_SA?: string;
  PLAY_BUCKET?: string;
  RC_KEYS?: string;
  STRIPE_KEYS?: string;
  CF_API_TOKEN?: string;
  CF_ACCOUNT_ID?: string;
  ANTHROPIC_API_KEY?: string;
  META_TOKEN?: string;
  AI_PROVIDER?: string;
  AI_KEY?: string;
  AI_MODEL?: string;
  AI_URL?: string;
  TELEGRAM_BOT_TOKEN?: string;
  TELEGRAM_CHAT_ID?: string;
  WEBHOOK_SECRET?: string;
  WEBHOOK_URL?: string;
};

type Boot = { token: string; home: string; lang?: string; secrets?: Secrets };

const SECRET_KEYS = new Set<string>([
  "ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_P8", "ASC_VENDOR", "GOOGLE_SA", "PLAY_BUCKET", "RC_KEYS", "STRIPE_KEYS",
  "CF_API_TOKEN", "CF_ACCOUNT_ID", "ANTHROPIC_API_KEY", "META_TOKEN", "AI_PROVIDER", "AI_KEY", "AI_MODEL", "AI_URL",
  "TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID", "WEBHOOK_SECRET", "WEBHOOK_URL",
]);

export function sameSecret(a: string | null | undefined, b: string | null | undefined) {
  if (!a || !b) return false;
  const x = Buffer.from(a), y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
}

const log = (...a: unknown[]) => console.error("[engine]", ...a);

async function readBoot(): Promise<{ boot: Boot; rest: AsyncIterator<string> }> {
  const it = console[Symbol.asyncIterator]();
  const first = await it.next();
  if (first.done) process.exit(0);
  return { boot: JSON.parse(first.value) as Boot, rest: it };
}

process.umask(0o077);
const { boot, rest } = await readBoot();
mkdirSync(boot.home, { recursive: true });
try { chmodSync(boot.home, 0o700); } catch {}
const DB = new LocalD1(join(boot.home, "pulse.db"));
await DB.exec(schemaSql);
for (const f of ["pulse.db", "pulse.db-wal", "pulse.db-shm"]) { try { chmodSync(join(boot.home, f), 0o600); } catch {} }

await DB.prepare("DELETE FROM kv WHERE k LIKE 'gtoken:%'").run();

export const env = { DB, PULSE_TOKEN: boot.token, LANG: boot.lang === "en" ? "en" : "tr" } as unknown as Env & Record<string, unknown>;

export function applySecrets(s: Secrets) {
  for (const [k, v] of Object.entries(s)) {
    if (!SECRET_KEYS.has(k)) continue;
    const key = k === "GOOGLE_SA" ? "GA4_SA" : k;
    if (v === undefined || v === null || v === "") delete env[key];
    else env[key] = v;
  }
  ensureWebhook();
}

export const WEBHOOK_PORT = Number(process.env.PULSE_WEBHOOK_PORT ?? 47870);
let hook: ReturnType<typeof Bun.serve> | null = null;
function ensureWebhook() {
  const secret = env.WEBHOOK_SECRET as string | undefined;
  if (!secret) {
    hook?.stop(true);
    hook = null;
    return;
  }
  if (hook) return;
  try {
    hook = Bun.serve({
      hostname: "127.0.0.1",
      port: WEBHOOK_PORT,
      async fetch(req) {
        const url = new URL(req.url);
        if (url.pathname === "/ping") return Response.json({ pulse: true });
        const m = url.pathname.match(/^\/rc\/([a-z0-9-]+)$/);
        if (!m || req.method !== "POST") return Response.json({ error: "not found" }, { status: 404 });
        if (!sameSecret(req.headers.get("authorization"), `Bearer ${env.WEBHOOK_SECRET}`)) return Response.json({ error: "unauthorized" }, { status: 401 });

        if (Number(req.headers.get("content-length") ?? 0) > 256_000) return Response.json({ error: "too large" }, { status: 413 });
        const raw = await req.text();
        if (raw.length > 256_000) return Response.json({ error: "too large" }, { status: 413 });
        let body: unknown = {};
        try { body = JSON.parse(raw); } catch {}
        const res = await handleRcWebhook(env, m[1], body as never);
        return Response.json(res, { status: res.ok ? 200 : 400 });
      },
    });
  } catch (e) {
    log("webhook portu açılamadı", WEBHOOK_PORT, String(e));
  }
}
applySecrets(boot.secrets ?? {});

export async function loadApps() {
  const list = (await kvGet<AppDef[]>(env.DB, "local:apps")) ?? [];
  APPS.splice(0, APPS.length, ...list);
  for (const k of Object.keys(META_ACCOUNTS)) delete META_ACCOUNTS[k];
  for (const a of list) if (a.metaAccount) META_ACCOUNTS[a.id] = a.metaAccount;
}
export async function saveApps(list: AppDef[]) {
  await kvSet(env.DB, "local:apps", list);
  await loadApps();
  await env.DB.prepare("DELETE FROM kv WHERE k IN ('snapshot', 'icons', 'asc:skus')").run();
}
await loadApps();

const safe = async (name: string, f: () => Promise<unknown>) => {
  try {
    await f();
  } catch (e) {
    log("iş hatası", name, String(e));
  }
};

let syncing: Promise<void> | null = null;
let again = false;

export function fullSync(): Promise<void> {
  if (syncing) {
    again = true;
    return syncing;
  }
  syncing = (async () => {
    await kvSet(env.DB, "local:sync", { running: true, ts: Date.now() });
    await Promise.all([
      safe("asc", () => runAscSales(env, 30)),
      safe("reviews", () => runAscReviews(env)),
      safe("iosacq", () => runIosAcq(env)),
      safe("play", () => runPlay(env)),
      safe("playsales", () => runPlaySales(env)),
      safe("playacq", () => runPlayAcq(env)),
      safe("rc", () => runRevenueCat(env)),
      safe("rccharts", () => runRevenueCatCharts(env)),
      safe("stripe", () => runStripe(env)),
      safe("health", () => runHealth(env)),
      safe("cf", () => runCloudflare(env)),
      safe("meta", () => runMeta(env)),
      safe("ga4", () => runGa4Daily(env)),
      safe("ga4rt", () => runGa4Realtime(env)),
      safe("ga4deep", () => runGa4Deep(env)),
    ]);
    await worker.fetch(new Request("http://local/v1/snapshot?fresh=1", { headers: { authorization: `Bearer ${boot.token}` } }), env);
    await kvSet(env.DB, "local:sync", { running: false, ts: Date.now() });
  })().finally(() => {
    syncing = null;
    if (again) {
      again = false;
      void fullSync();
    }
  });
  return syncing;
}
export const isSyncing = () => syncing !== null;

let tickBusy = false;
let lastTick = Date.now();
async function tick() {
  if (tickBusy || !APPS.length) return;
  tickBusy = true;

  const slept = Date.now() - lastTick > 15 * 60_000;
  lastTick = Date.now();
  if (slept) await fullSync();

  if (new Date().getHours() >= 6) void safe("analyst", () => runAnalyst(env));
  const ctx = { waitUntil: (p: Promise<unknown>) => p.catch(() => {}), passThroughOnException() {} };
  await safe("scheduled", () => worker.scheduled({ scheduledTime: Date.now(), cron: "*/5 * * * *", noRetry() {} } as never, env, ctx as never));
  tickBusy = false;
}
function scheduleNext() {
  const step = 5 * 60_000;
  const wait = step - (Date.now() % step) + 1000;
  setTimeout(async () => {
    await tick();
    scheduleNext();
  }, wait);
}
scheduleNext();

if (APPS.length) setTimeout(() => fullSync(), 3000);

const setup = setupRoutes({ env, applySecrets, saveApps, fullSync, isSyncing, webhookPort: WEBHOOK_PORT, webhookUp: () => hook !== null });
const server = Bun.serve({
  hostname: "127.0.0.1",
  port: 0,
  idleTimeout: 120,
  async fetch(req) {
    const url = new URL(req.url);
    if (url.pathname.startsWith("/v1/local/")) {
      if (!sameSecret(req.headers.get("authorization"), `Bearer ${boot.token}`)) return Response.json({ error: "unauthorized" }, { status: 401 });
      return setup(req, url);
    }
    return worker.fetch(req, env);
  },
});

console.log(`READY ${server.port}`);

(async () => {
  for (;;) {
    const n = await rest.next();
    if (n.done) break;
    try {
      const m = JSON.parse(n.value) as { secrets?: Secrets };
      if (m.secrets) applySecrets(m.secrets);
    } catch {}
  }
  log("uygulama kapandı, motor duruyor");
  process.exit(0);
})();
