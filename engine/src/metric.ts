import { APPS } from "./apps";
import type { Env } from "./env";
import { addDays, dayOf, localDayStart, now } from "./util";

export const KEYS = ["users", "web", "installs", "net", "mrr", "devices"] as const;
export type MetricKey = (typeof KEYS)[number];

export const CARD_METRIC: Record<MetricKey, string> = {
  users: "users_today", web: "web_visitors_today", installs: "installs_today", net: "revenue_today", mrr: "mrr", devices: "android_active_devices",
};

type CardLite = { id: string; metrics: Record<string, number | null> };
const BUCKET = 600;

export async function recordIntraday(env: Env, cards: CardLite[], t = now()) {
  const ts = Math.floor(t / BUCKET) * BUCKET;
  const stmts: D1PreparedStatement[] = [];
  for (const c of cards)
    for (const k of KEYS) {
      const v = c.metrics[CARD_METRIC[k]];
      if (typeof v === "number") stmts.push(env.DB.prepare("INSERT OR REPLACE INTO intraday (app, metric, ts, value) VALUES (?, ?, ?, ?)").bind(c.id, k, ts, v));
    }
  if (stmts.length) await env.DB.batch(stmts);

  if (ts % 86400 === 0) await env.DB.prepare("DELETE FROM intraday WHERE ts < ?").bind(ts - 40 * 86400).run();
}

export interface Base { now: number | null; then: number | null; pct: number | null; estimated: boolean; label: string; days: number }
type PerApp = Record<string, number[]>;

const median = (xs: number[]) => {
  const a = [...xs].sort((x, y) => x - y);
  const m = Math.floor(a.length / 2);
  return a.length % 2 ? a[m] : (a[m - 1] + a[m]) / 2;
};

async function pastSameTime(env: Env, t: number): Promise<Record<MetricKey, PerApp & { _d?: never }> & { dayCount: Record<MetricKey, number> }> {
  const out = { users: {}, web: {}, installs: {}, net: {}, mrr: {}, devices: {}, dayCount: { users: 0, web: 0, installs: 0, net: 0, mrr: 0, devices: 0 } } as Record<MetricKey, PerApp> & { dayCount: Record<MetricKey, number> };
  const ranges = Array.from({ length: 7 }, (_, i) => t - (i + 1) * 86400);
  const where = ranges.map(() => "(ts > ? AND ts <= ?)").join(" OR ");
  const binds = ranges.flatMap((at) => [at - 1800, at]);
  const rows = (await env.DB.prepare(`SELECT app, metric, ts, value FROM intraday WHERE ${where} ORDER BY ts`).bind(...binds)
    .all<{ app: string; metric: string; ts: number; value: number }>()).results;

  const byDay: Record<string, Record<string, Record<number, number>>> = {};
  for (const r of rows) {
    const d = Math.round((t - r.ts) / 86400);
    ((byDay[r.metric] ??= {})[r.app] ??= {})[d] = r.value;
  }
  if (!byDay.mrr) {
    const m = (await env.DB.prepare(`SELECT app, ts, value FROM points WHERE app IN (${APPS.map(() => "?").join(",")}) AND metric = 'mrr' AND ts > ? AND ts <= ? ORDER BY ts`)
      .bind(...APPS.map((a) => a.id), t - 86400 - 1800, t - 86400).all<{ app: string; ts: number; value: number }>()).results;
    for (const r of m) ((byDay.mrr ??= {})[r.app] ??= {})[1] = r.value;
  }
  for (const k of KEYS) {
    const days = new Set<number>();
    for (const [app, ds] of Object.entries(byDay[k] ?? {})) {
      out[k][app] = Object.keys(ds).map(Number).sort((a, b) => a - b).map((d) => ds[d]);
      Object.keys(ds).forEach((d) => days.add(Number(d)));
    }
    out.dayCount[k] = days.size;
  }
  return out;
}

async function webRatio(env: Env, t: number): Promise<Record<string, number>> {
  const dayStart = localDayStart(t);
  const rows = (
    await env.DB.prepare(`SELECT app, ts, value FROM points WHERE app IN (${APPS.map(() => "?").join(",")}) AND metric = 'web_visitors_1h' AND ts >= ?`)
      .bind(...APPS.map((a) => a.id), dayStart - 86400).all<{ app: string; ts: number; value: number }>()
  ).results;
  const tod: Record<string, number> = {}, yes: Record<string, number> = {};
  for (const r of rows) {
    if (r.ts >= dayStart) tod[r.app] = (tod[r.app] ?? 0) + r.value;
    else if (r.ts <= t - 86400) yes[r.app] = (yes[r.app] ?? 0) + r.value;
  }
  const out: Record<string, number> = {};
  for (const a of Object.keys(yes)) if (yes[a] > 0 && tod[a] !== undefined) out[a] = tod[a] / yes[a];
  return out;
}

const pct = (a: number | null, b: number | null) => (a === null || b === null || b === 0 ? null : Math.round(((a - b) / Math.abs(b)) * 100));

export async function baselines(env: Env, cards: CardLite[], t = now()) {
  const past = await pastSameTime(env, t);
  let ratio: Record<string, number> | null = null;
  const total: Partial<Record<MetricKey, Base>> = {};
  const perApp: Partial<Record<MetricKey, Record<string, Base>>> = {};
  for (const k of KEYS) {
    const m = CARD_METRIC[k];
    const n = past.dayCount[k];
    const useMedian = k !== "mrr" && n >= 3;
    const label = useMedian ? "normal bu saat" : "dün bu saat";
    const apps: Record<string, Base> = {};
    for (const c of cards) {
      const nowV = typeof c.metrics[m] === "number" ? (c.metrics[m] as number) : null;
      const xs = past[k][c.id];
      let then: number | null = null, estimated = false;
      if (xs?.length) then = useMedian ? median(xs) : xs[0];
      else if (k === "web" && nowV !== null) {
        ratio ??= await webRatio(env, t);
        if (ratio[c.id]) { then = Math.round(nowV / ratio[c.id]); estimated = true; }
      }
      if (nowV === null && then === null) continue;
      apps[c.id] = { now: nowV, then: then === null ? null : Math.round(then * 100) / 100, pct: pct(nowV, then), estimated, label, days: xs?.length ?? 0 };
    }
    perApp[k] = apps;

    const both = Object.values(apps).filter((a) => a.now !== null && a.then !== null);
    const nowAll = Object.values(apps).filter((a) => a.now !== null);
    if (both.length) {
      const a = both.reduce((x, b) => x + b.now!, 0), b = both.reduce((x, y) => x + y.then!, 0);
      total[k] = {
        now: nowAll.length ? nowAll.reduce((x, y) => x + y.now!, 0) : null, then: Math.round(b * 100) / 100, pct: pct(a, b),
        estimated: both.some((x) => x.estimated), label, days: useMedian ? n : 1,
      };
    }
  }
  return { total, perApp };
}

export async function sameHourTotals(env: Env, cards: CardLite[], t = now()) {
  return (await baselines(env, cards, t)).total;
}

export async function metricDetail(env: Env, key: MetricKey, days: number, cards: CardLite[]) {
  const t = now();
  const today = dayOf(t);
  const from = addDays(today, -(days - 1));
  const daily = (
    await env.DB.prepare(
      "SELECT app, metric, day, value FROM daily WHERE day >= ? AND metric IN ('users','web_visitors','installs','ios_downloads','android_installs','revenue_usd','ad_revenue_usd','revenue_gross_usd','refunded_usd','mrr','ios_proceeds_usd','android_proceeds_usd','android_active_devices')",
    ).bind(from).all<{ app: string; metric: string; day: string; value: number }>()
  ).results;
  const D: Record<string, Record<string, Record<string, number>>> = {};
  for (const r of daily) ((D[r.app] ??= {})[r.day] ??= {})[r.metric] = r.value;
  const storeNet = (d: Record<string, number>) =>
    d.ios_proceeds_usd === undefined && d.android_proceeds_usd === undefined ? undefined : (d.ios_proceeds_usd ?? 0) + (d.android_proceeds_usd ?? 0);
  const valueOf = (app: string, day: string): number | undefined => {
    const d = D[app]?.[day];
    if (!d) return undefined;
    switch (key) {
      case "users": return d.users;
      case "web": return d.web_visitors;

      case "installs": return d.installs ?? (d.ios_downloads === undefined && d.android_installs === undefined ? undefined : (d.ios_downloads ?? 0) + (d.android_installs ?? 0));
      case "net": return d.revenue_usd === undefined && d.ad_revenue_usd === undefined ? storeNet(d) : (d.revenue_usd ?? 0) + (d.ad_revenue_usd ?? 0);
      case "mrr": return d.mrr;
      case "devices": return d.android_active_devices;
    }
  };
  const grossOf = (app: string, day: string) => {
    const d = D[app]?.[day];
    if (!d) return undefined;
    const g = d.revenue_gross_usd !== undefined ? Math.max(0, d.revenue_gross_usd + (d.refunded_usd ?? 0)) : d.revenue_usd ?? storeNet(d);
    return g === undefined && d.ad_revenue_usd === undefined ? undefined : (g ?? 0) + (d.ad_revenue_usd ?? 0);
  };
  const appIds = APPS.map((a) => a.id);
  const r2 = (v: number) => Math.round(v * 100) / 100;
  const series = Array.from({ length: days }, (_, i) => {
    const day = addDays(today, -(days - 1 - i));
    const byApp: Record<string, number> = {};
    for (const a of appIds) {
      const v = valueOf(a, day);
      if (v !== undefined) byApp[a] = r2(v);
    }

    if (day === today) for (const c of cards) {
      const v = c.metrics[CARD_METRIC[key]];
      if (typeof v === "number") byApp[c.id] = r2(v);
    }
    const gross: Record<string, number> = {};
    if (key === "net") for (const a of appIds) { const g = grossOf(a, day); if (g !== undefined && g !== 0) gross[a] = r2(g); }
    return { day, byApp, ...(key === "net" ? { gross } : {}) };
  });

  const dayStart = localDayStart(t);
  const curve = (
    await env.DB.prepare("SELECT app, ts, value FROM intraday WHERE metric = ? AND ts >= ? ORDER BY ts").bind(key, dayStart - 86400)
      .all<{ app: string; ts: number; value: number }>()
  ).results;
  const intraday = { today: [] as { m: number; app: string; v: number }[], yday: [] as { m: number; app: string; v: number }[] };
  for (const r of curve) {
    const tday = r.ts >= dayStart;
    const m = Math.round((r.ts - (tday ? dayStart : dayStart - 86400)) / 60);
    (tday ? intraday.today : intraday.yday).push({ m, app: r.app, v: r2(r.value) });
  }

  const base = await baselines(env, cards, t);
  const per = base.perApp[key] ?? {};
  const apps = Object.entries(per).map(([id, b]) => ({ id, now: b.now, then: b.then, pct: b.pct, yday: series[series.length - 2]?.byApp[id] ?? null }))
    .concat(cards.filter((c) => !per[c.id] && series.some((s) => s.byApp[c.id] !== undefined)).map((c) => ({ id: c.id, now: null, then: null, pct: null, yday: series[series.length - 2]?.byApp[c.id] ?? null })));
  const tb = base.total[key];

  return {
    key, days, at: t,
    sameHourEstimated: tb?.estimated ?? false,

    baseLabel: tb?.label ?? null,
    baseDays: tb?.days ?? 0,

    intradaySince: (await env.DB.prepare("SELECT min(ts) m FROM intraday WHERE metric = ?").bind(key).first<{ m: number | null }>())?.m ?? null,
    apps, series, intraday,
  };
}
