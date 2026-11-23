import type { Env } from "./env";
import { addDays, dayOf, localDayStart, kvGet, kvSet } from "./util";

type Hist = { problems: string[]; services: string[] };
const KEYS = ["subs", "trials", "cancels", "sales", "reviews", "problems", "services", "alerts"] as const;
type Key = (typeof KEYS)[number];

export async function recordTodayHist(env: Env, day: string, now: Hist) {
  const k = `todayhist:${day}`;
  const prev = (await kvGet<Hist>(env.DB, k)) ?? { problems: [], services: [] };
  const next: Hist = {
    problems: [...new Set([...prev.problems, ...now.problems])].sort(),
    services: [...new Set([...prev.services, ...now.services])].sort(),
  };
  if (next.problems.length !== prev.problems.length || next.services.length !== prev.services.length) await kvSet(env.DB, k, next);
}

export interface HistDay {
  day: string;
  subs: number; trials: number; cancels: number; sales: number;
  netUsd: number; grossUsd: number; refundUsd: number;
  reviews: number; lowReviews: number; problems: number | null; services: number | null; alerts: number;
  byApp: Partial<Record<Key, Record<string, number>>>;
}

export async function todayHistory(env: Env, days = 30) {
  const today = dayOf();
  const from = addDays(today, -(days - 1));
  const fromTs = localDayStart() - (days - 1) * 86400;
  const [daily, events, reviews, alerts, hist] = await Promise.all([
    env.DB.prepare(
      "SELECT app, metric, day, value FROM daily WHERE day >= ? AND metric IN ('subs_new','trials_new','sales','revenue_usd','ad_revenue_usd','revenue_gross_usd','refunded_usd')",
    ).bind(from).all<{ app: string; metric: string; day: string; value: number }>(),
    env.DB.prepare("SELECT app, type, period_type, trial_conversion, ts FROM rc_events WHERE ts >= ?").bind(fromTs)
      .all<{ app: string; type: string; period_type: string; trial_conversion: number; ts: number }>(),
    env.DB.prepare("SELECT app, rating, ts FROM reviews WHERE ts >= ?").bind(fromTs).all<{ app: string; rating: number; ts: number }>(),
    env.DB.prepare("SELECT app, kind, severity, ts FROM alerts WHERE ts >= ?").bind(fromTs).all<{ app: string; kind: string; severity: string; ts: number }>(),
    env.DB.prepare("SELECT k, v FROM kv WHERE k >= ? AND k <= ?").bind(`todayhist:${from}`, `todayhist:${today}`).all<{ k: string; v: string }>(),
  ]);

  const C: Record<string, Partial<Record<Key, Record<string, number>>>> = {};
  const bump = (day: string, key: Key, app: string, n = 1) => {
    const m = ((C[day] ??= {})[key] ??= {});
    m[app] = (m[app] ?? 0) + n;
  };
  const money: Record<string, { net: number; gross: number; refund: number }> = {};
  const M = (day: string) => (money[day] ??= { net: 0, gross: 0, refund: 0 });

  const fromDaily: Record<string, Partial<Record<Key, Record<string, number>>>> = {};
  for (const r of daily.results) {
    if (r.metric === "subs_new" || r.metric === "trials_new" || r.metric === "sales") {
      const key: Key = r.metric === "subs_new" ? "subs" : r.metric === "trials_new" ? "trials" : "sales";
      const m = ((fromDaily[r.day] ??= {})[key] ??= {});
      m[r.app] = (m[r.app] ?? 0) + r.value;
    } else if (r.metric === "revenue_usd" || r.metric === "ad_revenue_usd") M(r.day).net += r.value;
    else if (r.metric === "revenue_gross_usd") M(r.day).gross += r.value;
    else if (r.metric === "refunded_usd") M(r.day).refund += r.value;
  }
  for (const e of events.results) {
    const day = dayOf(e.ts);
    if ((e.type === "INITIAL_PURCHASE" && e.period_type !== "TRIAL") || (e.type === "RENEWAL" && e.trial_conversion)) bump(day, "subs", e.app);
    else if (e.type === "INITIAL_PURCHASE") bump(day, "trials", e.app);
    else if (e.type === "CANCELLATION") bump(day, "cancels", e.app);
    else if (e.type === "NON_RENEWING_PURCHASE") bump(day, "sales", e.app);
  }
  for (const [day, keys] of Object.entries(fromDaily))
    for (const [key, apps] of Object.entries(keys) as [Key, Record<string, number>][])
      for (const [app, n] of Object.entries(apps)) {
        if (Math.round(n) <= 0) continue;
        const m = ((C[day] ??= {})[key] ??= {});
        m[app] = Math.max(m[app] ?? 0, Math.round(n));
      }
  const low: Record<string, number> = {};
  for (const r of reviews.results) {
    const day = dayOf(r.ts);
    bump(day, "reviews", r.app);
    if (r.rating <= 2) low[day] = (low[day] ?? 0) + 1;
  }
  for (const a of alerts.results) if (a.severity === "critical" || a.severity === "warning") bump(dayOf(a.ts), "alerts", a.app);
  const H: Record<string, Hist> = {};
  for (const r of hist.results) {
    try { H[r.k.slice("todayhist:".length)] = JSON.parse(r.v) as Hist; } catch {  }
  }
  const sum = (o?: Record<string, number>) => Object.values(o ?? {}).reduce((x, y) => x + y, 0);

  const out: HistDay[] = [];
  for (let i = 0; i < days; i++) {
    const day = addDays(today, -i);
    const c = C[day] ?? {};
    const h = H[day];
    const byApp: HistDay["byApp"] = { ...c };
    if (h) {
      byApp.problems = Object.fromEntries(h.problems.map((a) => [a, 1]));
      byApp.services = Object.fromEntries(h.services.map((a) => [a, 1]));
    }
    const mo = money[day];
    out.push({
      day,
      subs: sum(c.subs), trials: sum(c.trials), cancels: sum(c.cancels), sales: sum(c.sales),
      netUsd: Math.round((mo?.net ?? 0) * 100) / 100,

      grossUsd: Math.round(Math.max(0, (mo?.gross ?? 0) + (mo?.refund ?? 0)) * 100) / 100,
      refundUsd: Math.round((mo?.refund ?? 0) * 100) / 100,
      reviews: sum(c.reviews), lowReviews: low[day] ?? 0,
      problems: h ? h.problems.length : null,
      services: h ? h.services.length : null,
      alerts: sum(c.alerts),
      byApp,
    });
  }
  return {
    days: out,

    eventsSince: events.results.length ? dayOf(Math.min(...events.results.map((e) => e.ts))) : null,
    statusSince: Object.keys(H).sort()[0] ?? null,
  };
}
