import { timingSafeEqual } from "node:crypto";
import { APPS, appById, type AppDef } from "./apps";
import type { Env } from "./env";
import { runHealth } from "./connectors/health";
import { runRevenueCat } from "./connectors/revenuecat";
import { runStripe } from "./connectors/stripe";
import { runAscReviews, runAscSales } from "./connectors/asc";
import { runGa4Daily, runGa4Deep, runGa4Realtime } from "./connectors/ga4";
import { runCloudflare } from "./connectors/cloudflare";
import { runRevenueCatCharts } from "./connectors/rccharts";
import { runPlay } from "./connectors/play";
import { runPlaySales } from "./connectors/playsales";
import { markSource, sourceStatus } from "./sources";
import { buddy } from "./buddy";
import { raise } from "./alerts";
import { runAnomalies } from "./anomaly";
import { runAnalyst } from "./analyst";
import { addDays, dayOf, localDayStart, kvGet, kvSet, now, putPoint, tzOffset } from "./util";
import { diagnose } from "./diagnose";
import { recordTodayHist, todayHistory } from "./history";
import { KEYS as METRIC_KEYS, metricDetail, recordIntraday, sameHourTotals, type MetricKey } from "./metric";
import { META_ACCOUNTS, metaDetail, metaSummary, runMeta } from "./connectors/meta";
import { sourcesOverview } from "./sources-overview";
import { acquisition, runIosAcq, runPlayAcq } from "./connectors/acquisition";

export const SEGMENTS = [
  { id: "app", title: "Uygulamalar" },
  { id: "game", title: "Oyunlar" },
  { id: "web", title: "Web" },
  { id: "social", title: "Sosyal" },
  { id: "infra", title: "Altyapı" },
] as const;

async function icons(env: Env): Promise<Record<string, string>> {
  const cached = await kvGet<{ ts: number; map: Record<string, string> }>(env.DB, "icons");
  if (cached && cached.ts > now() - 7 * 86400 && Object.keys(cached.map).length && APPS.every((a) => !a.icon || cached.map[a.id]?.includes(a.icon))) return cached.map;
  const map: Record<string, string> = {};
  const ids = APPS.filter((a) => a.ascId).map((a) => a.ascId).join(",");
  for (const country of ["tr", "us", "gb", "de"]) {
    try {
      const r = await fetch(`https://itunes.apple.com/lookup?id=${ids}&country=${country}`);
      const j = (await r.json()) as { results: { trackId: number; artworkUrl512?: string; artworkUrl100?: string }[] };
      for (const x of j.results) {
        const app = APPS.find((a) => a.ascId === String(x.trackId));
        if (app && !map[app.id]) map[app.id] = x.artworkUrl512 ?? x.artworkUrl100 ?? "";
      }
    } catch {}
  }
  for (const a of APPS) {
    if (map[a.id] || a.ascId) continue;
    const host = a.cfZone ?? (a.health?.[0] ? new URL(a.health[0].url).hostname : undefined);

    void host;
  }
  await kvSet(env.DB, "icons", { ts: now(), map });
  return map;
}

type DailyMap = Record<string, Record<string, Record<string, number>>>;

async function snapshot(env: Env) {
  const today = dayOf();
  const yday = addDays(today, -1);
  const from = addDays(today, -14);
  const t = now();

  const [daily, pts, health, alerts, reviews, iconMap] = await Promise.all([
    env.DB.prepare("SELECT app, metric, day, value FROM daily WHERE day >= ?").bind(from).all<{ app: string; metric: string; day: string; value: number }>(),
    env.DB.prepare("SELECT app, metric, ts, value FROM points WHERE ts >= ? ORDER BY ts").bind(t - 86400).all<{ app: string; metric: string; ts: number; value: number }>(),
    env.DB.prepare("SELECT target, app, ok, code, ms, ts, since FROM health").all<{ target: string; app: string; ok: number; code: number; ms: number; ts: number; since: number }>(),
    env.DB.prepare("SELECT id, app, metric, kind, severity, title, body, ts, acked FROM alerts WHERE ts >= ? ORDER BY ts DESC LIMIT 60").bind(t - 3 * 86400).all(),
    env.DB.prepare("SELECT app, store, rating, title, body, ts, territory FROM reviews ORDER BY ts DESC LIMIT 40").all(),
    icons(env),
  ]);

  const liveRows = (
    await env.DB.prepare("SELECT app, type, period_type, price_usd, trial_conversion, ts FROM rc_events WHERE ts >= ?").bind(localDayStart(t)).all<{
      app: string; type: string; period_type: string; price_usd: number; trial_conversion: number; ts: number;
    }>()
  ).results;

  const early = (r: { ts: number }) => r.ts < localDayStart(t) + Math.max(0, tzOffset(t));
  const live = (app?: string, onlyEarly = false) => {
    const rows = liveRows.filter((r) => (!app || r.app === app) && (!onlyEarly || early(r)));
    return {
      newSubs: rows.filter((r) => (r.type === "INITIAL_PURCHASE" && r.period_type !== "TRIAL") || (r.type === "RENEWAL" && r.trial_conversion)).length,
      trials: rows.filter((r) => r.type === "INITIAL_PURCHASE" && r.period_type === "TRIAL").length,
      renewals: rows.filter((r) => r.type === "RENEWAL" && !r.trial_conversion).length,
      cancels: rows.filter((r) => r.type === "CANCELLATION").length,
      purchases: rows.filter((r) => r.type === "NON_RENEWING_PURCHASE").length,
      gross: Math.round(rows.filter((r) => r.type !== "CANCELLATION").reduce((x, r) => x + (r.price_usd || 0), 0) * 100) / 100,
      any: rows.length > 0,
    };
  };

  const D: DailyMap = {};
  for (const r of daily.results) ((D[r.app] ??= {})[r.metric] ??= {})[r.day] = r.value;
  const get = (app: string, m: string, day: string) => D[app]?.[m]?.[day];
  const series14 = (app: string, m: string) =>
    Array.from({ length: 14 }, (_, i) => get(app, m, addDays(today, i - 13)) ?? null);

  const P: Record<string, Record<string, { ts: number; value: number }[]>> = {};
  for (const p of pts.results) ((P[p.app] ??= {})[p.metric] ??= []).push({ ts: p.ts, value: p.value });
  const lastPt = (app: string, m: string) => {
    const arr = P[app]?.[m];
    return arr?.length ? arr[arr.length - 1].value : undefined;
  };
  const live24 = (app: string, m: string) => (P[app]?.[m] ?? []).map((p) => p.value);

  const src = await sourceStatus(env);

  const metaOuts: Record<string, Awaited<ReturnType<typeof metaDetail>>> = {};
  for (const id of Object.keys(META_ACCOUNTS)) metaOuts[id] = await metaDetail(env, id);

  const appInstalls = (app: string, d: string) => {
    const rc = get(app, "installs", d);
    if (rc !== undefined) return rc;
    const def = appById(app);
    const i = get(app, "ios_downloads", d), p = get(app, "android_installs", d);
    if (def?.ascId && def?.playPackage && (i === undefined || p === undefined)) return undefined;
    return i === undefined && p === undefined ? undefined : (i ?? 0) + (p ?? 0);
  };
  const appRevenue = (app: string, d: string) => {
    const r = get(app, "revenue_usd", d), ad = get(app, "ad_revenue_usd", d);
    if (r === undefined && ad === undefined) {
      const i = get(app, "ios_proceeds_usd", d), p = get(app, "android_proceeds_usd", d);
      return i === undefined && p === undefined ? undefined : (i ?? 0) + (p ?? 0);
    }
    return (r ?? 0) + (ad ?? 0);
  };
  const cards = APPS.map((a: AppDef) => {
    const g = (m: string, d: string) => get(a.id, m, d);
    const firstOf = (ms: string[], d: string) => {
      for (const m of ms) {
        const v = g(m, d);
        if (v !== undefined) return v;
      }
      return undefined;
    };
    const sumOf = (ms: string[], d: string) => {
      const vs = ms.map((m) => g(m, d)).filter((v): v is number => v !== undefined);
      return vs.length ? vs.reduce((x, y) => x + y, 0) : undefined;
    };
    const range = (fn: (d: string) => number | undefined, n: number, from = 0) => {
      let tot: number | undefined;
      for (let i = from; i < from + n; i++) {
        const v = fn(addDays(today, -i));
        if (v !== undefined) tot = (tot ?? 0) + v;
      }
      return tot;
    };
    const users = (d: string) => firstOf(["users", "web_visitors"], d);
    const installs = (d: string) => appInstalls(a.id, d);
    const revenue = (d: string) => appRevenue(a.id, d);

    const gross = (d: string) => {
      const rg = g("revenue_gross_usd", d);
      const g1 = rg !== undefined ? Math.max(0, rg + (g("refunded_usd", d) ?? 0)) : g("revenue_usd", d);
      const ad = g("ad_revenue_usd", d);
      return g1 === undefined && ad === undefined ? undefined : (g1 ?? 0) + (ad ?? 0);
    };
    const r2 = (v: number | undefined) => (v === undefined ? null : Math.round(v * 100) / 100);

    const appAlerts = alerts.results.filter((x: any) => x.app === a.id && !x.acked);
    const hs = health.results.filter((h) => h.app === a.id);
    const rt = lastPt(a.id, "rt_users");
    const v1h = lastPt(a.id, "web_visitors_1h");
    const uT = users(today);
    const uY = users(yday);
    const adRevY = g("ad_revenue_usd", yday);
    const impY = g("ad_impressions", yday);
    const mo = metaOuts[a.id];
    const spend7 = mo ? mo.d7.spend : range((d) => g("ad_spend_usd", d), 7, 1);
    const rev7 = range(revenue, 7, 1);

    const lastFull = (() => {
      for (let i = 1; i <= 6; i++) if (installs(addDays(today, -i)) !== undefined) return i;
      return 1;
    })();
    const lastOf = (m: string) => {
      for (let i = 1; i <= 7; i++) {
        const v = g(m, addDays(today, -i));
        if (v !== undefined) return v;
      }
      return null;
    };
    const pv7 = range((d) => g("paywall_views", d), 7, 1);
    const pc7 = range((d) => g("paywall_conversions", d), 7, 1);

    const metrics: Record<string, number | null> = {
      rt_users: rt ?? null,
      users_today: g("users", today) ?? null,
      users_yday: g("users", yday) ?? null,
      new_users_today: g("new_users", today) ?? null,
      installs_today: installs(today) ?? null,
      installs_yday: installs(yday) ?? null,
      installs_7d: range(installs, 7, lastFull) ?? null,
      android_installs_yday: g("android_installs", yday) ?? g("android_installs", addDays(today, -2)) ?? null,
      android_uninstalls_7d: range((d) => g("android_uninstalls", d), 7, 1) ?? null,
      android_active_devices: lastOf("android_active_devices"),
      ios_downloads_yday: g("ios_downloads", yday) ?? g("ios_downloads", addDays(today, -2)) ?? null,
      revenue_today: r2(revenue(today)),
      revenue_yday: r2(revenue(yday)),
      revenue_7d: r2(rev7),
      gross_today: r2(gross(today)),
      gross_yday: r2(gross(yday)),
      gross_7d: r2(range(gross, 7, 1)),
      revenue_28d: lastPt(a.id, "revenue_28d") ?? null,
      transactions_today: g("transactions", today) ?? g("sales", today) ?? null,
      active_subs: lastPt(a.id, "active_subs") ?? null,
      trials: lastPt(a.id, "trials") ?? null,
      mrr: lastPt(a.id, "mrr") ?? null,
      subs_new_today: Math.max(g("subs_new", today) ?? 0, live(a.id).newSubs) || (g("subs_new", today) !== undefined || live(a.id).any ? 0 : null),
      subs_new_yday: g("subs_new", yday) ?? null,
      trials_today_live: live(a.id).trials || null,
      subs_new_7d: range((d) => g("subs_new", d), 7, 0) ?? null,
      trials_new_today: g("trials_new", today) ?? null,
      churned_7d: range((d) => g("subs_churned", d), 7, 0) ?? null,
      paywall_views_7d: pv7 ?? null,
      paywall_conv_7d: pv7 && pc7 !== undefined ? Math.round((pc7 / pv7) * 1000) / 10 : null,
      refunds_7d: r2(range((d) => g("refunded_usd", d), 7, 0)),
      ret_d1: g("ret_d1", today) ?? g("ret_d1", yday) ?? null,
      ret_d7: g("ret_d7", today) ?? g("ret_d7", yday) ?? null,
      avg_session_s: g("avg_session_s", yday) ?? null,
      visitors_1h: v1h ?? null,
      web_visitors_today: g("web_visitors", today) ?? null,
      web_visitors_yday: g("web_visitors", yday) ?? null,
      threats_today: g("web_threats", today) ?? null,
      ad_revenue_yday: r2(adRevY),
      ad_impressions_yday: impY ?? null,
      ecpm_yday: adRevY && impY ? Math.round((adRevY / impY) * 100000) / 100 : null,
      impressions_per_dau: impY && uY ? Math.round((impY / uY) * 10) / 10 : null,
      arpdau: uY && revenue(yday) ? Math.round((revenue(yday)! / uY) * 1000) / 1000 : null,
      ad_spend_7d: r2(spend7),
      roas_7d: mo?.d7.roas ?? null,
    };

    const avgOf = (fn: (d: string) => number | undefined) => {
      const v = range(fn, 7, 1);
      return v === undefined ? null : v / 7;
    };
    const lowReviews24h = reviews.results.filter((r: any) => r.app === a.id && r.rating <= 2 && r.ts > t - 86400).length;

    const monetized = !!a.rcProject || !!a.stripe || (range((d) => (g("ios_proceeds_usd", d) ?? 0) + (g("android_proceeds_usd", d) ?? 0), 30, 1) ?? 0) > 0;
    const note = buddy({
      name: a.name,
      segment: a.kind,
      m: metrics,
      avg7: {
        installs: avgOf(installs),
        users: avgOf((d) => g("users", d)),
        web_visitors: avgOf((d) => g("web_visitors", d)),
      },
      avgPrev: {
        installs: (() => { const v = range(installs, 7, 2); return v === undefined ? null : v / 7; })(),
        users: (() => { const v = range((d) => g("users", d), 7, 2); return v === undefined ? null : v / 7; })(),
      },
      prev7: { revenue: range(revenue, 7, 8) ?? null },
      dayFraction: (t % 86400) / 86400,
      down: hs.filter((h) => h.ok === 0).map((h) => h.target.split(":")[1]),
      lowReviews24h,
      prelaunch: a.stage === "prelaunch",
      monetized,
    });

    const hero =
      rt !== undefined ? { label: "şu an", value: rt, unit: "num", subLabel: "bugün", subValue: uT ?? null }
      : uT !== undefined ? { label: g("users", today) === undefined ? "bugün ziyaret" : "bugün aktif", value: uT, unit: "num", subLabel: "dün", subValue: uY ?? null }
      : metrics.active_subs !== null ? { label: "abone", value: metrics.active_subs, unit: "num", subLabel: null, subValue: null }
      : (() => {
          for (let i = 1; i <= 6; i++) {
            const v = installs(addDays(today, -i));
            if (v !== undefined) return { label: i === 1 ? "kurulum dün" : `kurulum ${i} gün önce`, value: v, unit: "num", subLabel: "7 gün", subValue: range(installs, 7, i) ?? null };
          }
          return null;
        })();

    const score = (rt ?? 0) * 20 + (uT ?? 0) + (v1h ?? 0) * 3 + (installs(today) ?? 0) * 2 + (revenue(today) ?? 0) * 5;
    return {
      id: a.id,
      name: a.name,
      segment: a.kind,
      color: a.color,
      icon: iconMap[a.id] ?? null,
      ascId: a.ascId ?? null,
      site: a.cfZone ?? null,
      score,
      hero,
      note,
      social: null,
      metrics,
      sources: src[a.id] ?? [],
      spark: {
        live: live24(a.id, "rt_users").length ? live24(a.id, "rt_users") : live24(a.id, "web_visitors_1h"),
        users: Array.from({ length: 14 }, (_, i) => users(addDays(today, i - 13)) ?? null),
        installs: Array.from({ length: 14 }, (_, i) => installs(addDays(today, i - 13)) ?? null),
        revenue: Array.from({ length: 14 }, (_, i) => revenue(addDays(today, i - 13)) ?? null),
      },
      health: hs.map((h) => ({ name: h.target.split(":")[1], ok: h.ok === 1, code: h.code, ms: h.ms, since: h.since })),
      openAlerts: appAlerts.length,
      worst: appAlerts.some((x: any) => x.severity === "critical") ? "critical" : appAlerts.some((x: any) => x.severity === "warning") ? "warning" : null,
    };
  }).sort((x, y) => y.score - x.score);

  const total = (k: string) => {
    const vs = cards.map((c) => c.metrics[k]).filter((v): v is number => v !== null);
    return vs.length ? Math.round(vs.reduce((x, y) => x + y, 0) * 100) / 100 : null;
  };

  const days14 = Array.from({ length: 14 }, (_, i) => addDays(today, i - 13));
  const sumDay = (metrics: string[], d: string) => {
    let tot: number | null = null;
    for (const a of APPS) {
      for (const m of metrics) {
        const v = get(a.id, m, d);
        if (v !== undefined) {
          tot = (tot ?? 0) + v;
          break;
        }
      }
    }
    return tot;
  };
  const sumDayAll = (metrics: string[], d: string) => {
    let tot: number | null = null;
    for (const a of APPS) for (const m of metrics) {
      const v = get(a.id, m, d);
      if (v !== undefined) tot = (tot ?? 0) + v;
    }
    return tot;
  };
  const sumApps = (fn: (app: string, d: string) => number | undefined, d: string) => {
    let tot: number | null = null;
    for (const a of APPS) {
      const v = fn(a.id, d);
      if (v !== undefined) tot = (tot ?? 0) + v;
    }
    return tot;
  };
  const series = {
    appUsers: days14.map((d) => sumDay(["users"], d)),
    web: days14.map((d) => sumDay(["web_visitors"], d)),
    installs: days14.map((d) => sumApps(appInstalls, d)),
    revenue: days14.map((d) => sumApps(appRevenue, d)),
  };

  const ydayVsAvg = (arr: (number | null)[]) => {
    const prev = arr.slice(5, 12).filter((v): v is number => v !== null);
    const y = arr[12];
    if (y === null || prev.length < 4) return null;
    const avg = prev.reduce((x, z) => x + z, 0) / prev.length;
    return avg > 0 ? Math.round(((y - avg) / avg) * 100) : null;
  };
  const rev7 = series.revenue.slice(6, 13).reduce<number>((x, v) => x + (v ?? 0), 0);
  let revPrev7 = 0;
  for (let i = 8; i <= 14; i++) revPrev7 += sumApps(appRevenue, addDays(today, -i)) ?? 0;
  const moodRank: Record<string, number> = { critical: 5, bad: 4, fire: 3, good: 2, meh: 0 };
  const top = cards
    .filter((c) => c.note.key !== "quiet" && moodRank[c.note.mood] > 0)
    .sort((x, y) => moodRank[y.note.mood] - moodRank[x.note.mood] || y.score - x.score)[0];
  const dayStart = localDayStart(t);
  const todayAlerts = alerts.results.filter((x: any) => x.ts >= dayStart);

  await recordIntraday(env, cards, t).catch(() => {});
  const sameHour = await sameHourTotals(env, cards, t).catch(() => ({}));

  await recordTodayHist(env, today, {
    problems: cards.filter((c) => c.note.mood === "critical" || c.note.mood === "bad").map((c) => c.id),
    services: [...new Set(health.results.filter((h) => h.ok === 0).map((h) => h.app))],
  }).catch(() => {});

  return {
    generatedAt: t,
    day: today,
    segments: SEGMENTS,
    spotlight: top ? { app: top.id, name: top.name, mood: top.note.mood, headline: top.note.headline } : null,
    series,
    changes: {
      appUsers: ydayVsAvg(series.appUsers),
      web: ydayVsAvg(series.web),
      installs: ydayVsAvg(series.installs),
      revenue7d: revPrev7 > 0 ? Math.round(((rev7 - revPrev7) / revPrev7) * 100) : null,

      sameHour,
    },

    sources: await sourcesOverview(env, 1)
      .then((o) => ({ total: o.web.total, cfTotal: o.web.cfTotal, top: o.web.bySrc.slice(0, 4).map((x) => ({ src: x.src, n: x.n })), sites: o.web.byApp.filter((x) => x.n > 0).length }))
      .catch(() => null),
    today: {
      newSubs: Math.max(live().newSubs, todayAlerts.filter((x: any) => x.kind === "sub").length),
      newSubsYday: (() => {
        const v = total("subs_new_yday");
        return v === null ? null : Math.max(0, v - live(undefined, true).newSubs);
      })(),
      trials: live().trials,
      renewals: live().renewals,
      cancels: live().cancels,
      liveGross: live().gross,
      liveConnected: liveRows.length > 0 || (await env.DB.prepare("SELECT 1 FROM kv WHERE k LIKE 'src:%:revenuecat_live' LIMIT 1").first()) !== null,
      sales: todayAlerts.filter((x: any) => x.kind === "sale").length + live().purchases,
      lowReviews: reviews.results.filter((r: any) => r.rating <= 2 && r.ts >= dayStart).length,
      reviews: reviews.results.filter((r: any) => r.ts >= dayStart).length,
      problems: cards.filter((c) => c.note.mood === "critical" || c.note.mood === "bad").length,
      hot: cards.filter((c) => c.note.mood === "fire").length,

      byApp: (() => {
        const uniq = (xs: (string | null | undefined)[]) => [...new Set(xs.filter((x): x is string => !!x))];
        const ev = (f: (r: (typeof liveRows)[number]) => boolean) => uniq(liveRows.filter(f).map((r) => r.app));
        return {
          subs: uniq([
            ...ev((r) => (r.type === "INITIAL_PURCHASE" && r.period_type !== "TRIAL") || (r.type === "RENEWAL" && !!r.trial_conversion)),
            ...todayAlerts.filter((x: any) => x.kind === "sub").map((x: any) => x.app),
          ]),
          trials: ev((r) => r.type === "INITIAL_PURCHASE" && r.period_type === "TRIAL"),
          cancels: ev((r) => r.type === "CANCELLATION"),
          sales: uniq([...ev((r) => r.type === "NON_RENEWING_PURCHASE"), ...todayAlerts.filter((x: any) => x.kind === "sale").map((x: any) => x.app)]),
          problems: cards.filter((c) => c.note.mood === "critical" || c.note.mood === "bad").map((c) => c.id),
          reviews: uniq(reviews.results.filter((r: any) => r.ts >= dayStart).map((r: any) => r.app)),
          services: uniq(health.results.filter((h) => h.ok === 0).map((h) => h.app)),
        };
      })(),
    },
    totals: {
      visitors1h: total("visitors_1h"),
      liveUsers: total("rt_users"),
      usersToday: total("users_today"),
      usersYday: total("users_yday"),
      webVisitorsToday: total("web_visitors_today"),
      webVisitorsYday: total("web_visitors_yday"),
      installsToday: total("installs_today"),
      installsYday: total("installs_yday"),
      revenueToday: total("revenue_today"),
      revenueYday: total("revenue_yday"),
      revenue7d: total("revenue_7d"),
      gross7d: total("gross_7d"),
      grossYday: total("gross_yday"),
      grossToday: total("gross_today"),
      activeSubs: total("active_subs"),
      trials: total("trials"),
      mrr: total("mrr"),
      subsNewToday: total("subs_new_today"),
      ...(() => {
        const active = APPS.filter((a) => Array.from({ length: 10 }, (_, k) => appInstalls(a.id, addDays(today, -1 - k))).some((v) => v !== undefined));
        for (let i = 1; i <= 7; i++) {
          const d = addDays(today, -i);
          if (!active.length || active.some((a) => appInstalls(a.id, d) === undefined)) continue;
          return { installsLast: active.reduce((x, a) => x + (appInstalls(a.id, d) ?? 0), 0), installsLastDay: d };
        }
        return { installsLast: null, installsLastDay: null };
      })(),
      activeDevices: total("android_active_devices"),
      ...(() => {
        const rs = (reviews.results as { rating: number; ts: number }[]).filter((r) => r.ts > t - 30 * 86400);
        return { ratingAvg: rs.length ? Math.round((rs.reduce((x, r) => x + r.rating, 0) / rs.length) * 10) / 10 : null, ratingCount: rs.length };
      })(),
      adSpendToday: Object.values((await metaSummary(env)) ?? {}).reduce((a, x) => a + x.spendToday, 0),
      servicesDown: health.results.filter((h) => h.ok === 0).length,
      servicesTotal: health.results.length,
    },
    cards,
    alerts: alerts.results,
    reviews: reviews.results,
  };
}

async function detail(env: Env, id: string) {
  const app = appById(id);
  if (!app) return null;
  const from = addDays(dayOf(), -30);
  const rows = await env.DB.prepare("SELECT metric, day, value FROM daily WHERE app = ? AND day >= ? ORDER BY day").bind(id, from).all<{ metric: string; day: string; value: number }>();
  const series: Record<string, { day: string; value: number }[]> = {};
  for (const r of rows.results) (series[r.metric] ??= []).push({ day: r.day, value: r.value });

  if (series.revenue_gross_usd) {
    const ref = new Map((series.refunded_usd ?? []).map((p) => [p.day, p.value]));
    series.revenue_gross_usd = series.revenue_gross_usd.map((p) => ({ day: p.day, value: Math.max(0, Math.round((p.value + (ref.get(p.day) ?? 0)) * 100) / 100) }));
  }
  const live = await env.DB.prepare("SELECT metric, ts, value FROM points WHERE app = ? AND ts >= ? ORDER BY ts").bind(id, localDayStart() - 86400).all();
  const insight = await env.DB.prepare("SELECT ts, text FROM insights WHERE app = ? ORDER BY ts DESC LIMIT 3").bind(id).all();
  const yday = addDays(dayOf(), -1);
  const reviews = (await env.DB.prepare("SELECT rating, title, body, ts, territory FROM reviews WHERE app = ? ORDER BY ts DESC LIMIT 15").bind(id).all<{ rating: number; title: string | null }>()).results;
  const countries = await kvGet<Record<string, number>>(env.DB, `asc:countries:${id}:${yday}`);
  const diagnosis = app.kind === "social" ? null : diagnose({
    segment: app.kind,
    prelaunch: app.stage === "prelaunch",
    hasRc: !!app.rcProject,
    hasGa4: !!app.ga4Property,
    hasStripe: !!app.stripe,
    hasSite: !!app.cfZone,
    series,
    today: dayOf(now(), "UTC"),
    reviews,
    countries,
  });
  return {
    diagnosis,
    social: null,
    liveCost: null,
    traffic: null,
    siteSources: null,
    acquisition: await acquisition(env, id),
    meta: await metaDetail(env, id),
    id,
    name: app.name,
    segment: app.kind,
    series,
    live: live.results,
    retention: await kvGet(env.DB, `ga4:retention:${id}`),
    screens: await kvGet(env.DB, `ga4:screens:${id}`),
    liveScreens: await kvGet(env.DB, `ga4:rtscreens:${id}`),
    events: await kvGet(env.DB, `ga4:events:${id}`),
    countries,
    insights: insight.results,
    reviews,
    alerts: (await env.DB.prepare("SELECT * FROM alerts WHERE app = ? ORDER BY ts DESC LIMIT 30").bind(id).all()).results,
  };
}

const json = (d: unknown, status = 200) =>
  new Response(JSON.stringify(d), { status, headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" } });

async function safe(name: string, f: () => Promise<void>) {
  try {
    await f();
  } catch (e) {
    console.log("job fail", name, String(e));
  }
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    if (url.pathname === "/health") return json({ ok: true });
    const auth = req.headers.get("authorization");
    if (!env.PULSE_TOKEN || !auth || auth.length !== env.PULSE_TOKEN.length + 7 || !timingSafeEqual(Buffer.from(auth), Buffer.from(`Bearer ${env.PULSE_TOKEN}`))) return json({ error: "unauthorized" }, 401);

    if (url.pathname === "/v1/snapshot") {
      const cached = await env.DB.prepare("SELECT v FROM kv WHERE k = 'snapshot'").first<{ v: string }>();
      if (cached && url.searchParams.get("fresh") !== "1")
        return new Response(cached.v, { headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" } });
      const s = await snapshot(env);
      await kvSet(env.DB, "snapshot", s);
      return json(s);
    }
    const mt = url.pathname.match(/^\/v1\/meta\/([a-z0-9-]+)$/);
    if (mt) {
      const d = await metaDetail(env, mt[1]);
      return d ? json(d) : json({ error: "not found" }, 404);
    }
    const mk = url.pathname.match(/^\/v1\/metric\/([a-z]+)$/);
    if (mk && (METRIC_KEYS as readonly string[]).includes(mk[1])) {
      const n = Math.min(120, Math.max(7, Number(url.searchParams.get("days")) || 30));
      const snap = await kvGet<{ cards: { id: string; metrics: Record<string, number | null> }[] }>(env.DB, "snapshot");
      return json(await metricDetail(env, mk[1] as MetricKey, n, snap?.cards ?? []));
    }
    if (url.pathname === "/v1/sources") {
      const n = [1, 7, 30].includes(Number(url.searchParams.get("days"))) ? Number(url.searchParams.get("days")) : 1;
      return json(await sourcesOverview(env, n));
    }
    if (url.pathname === "/v1/today/history") {
      const n = Math.min(120, Math.max(7, Number(url.searchParams.get("days")) || 60));
      return json(await todayHistory(env, n));
    }
    const m = url.pathname.match(/^\/v1\/app\/([a-z0-9-]+)$/);
    if (m) {
      const d = await detail(env, m[1]);
      return d ? json(d) : json({ error: "not found" }, 404);
    }
    const ack = url.pathname.match(/^\/v1\/alerts\/(\d+)\/ack$/);
    if (ack && req.method === "POST") {
      await env.DB.prepare("UPDATE alerts SET acked = 1 WHERE id = ?").bind(Number(ack[1])).run();
      await kvSet(env.DB, "snapshot", await snapshot(env));
      return json({ ok: true });
    }
    if (url.pathname === "/v1/alerts/ack-all" && req.method === "POST") {
      await env.DB.prepare("UPDATE alerts SET acked = 1 WHERE acked = 0").run();
      await kvSet(env.DB, "snapshot", await snapshot(env));
      return json({ ok: true });
    }

    if (url.pathname === "/v1/run" && req.method === "POST") {
      const job = url.searchParams.get("job") ?? "";
      const jobs: Record<string, () => Promise<void>> = {
        health: () => runHealth(env),
        rc: () => runRevenueCat(env),
        play: () => runPlay(env),
        rccharts: () => runRevenueCatCharts(env, url.searchParams.has("i") ? Number(url.searchParams.get("i")) : undefined),
        stripe: () => runStripe(env),
        asc: () => runAscSales(env, Math.min(Number(url.searchParams.get("back") ?? 3), 40)),
        reviews: () => runAscReviews(env),
        ga4rt: () => runGa4Realtime(env),
        ga4: () => runGa4Daily(env),
        ga4deep: () => runGa4Deep(env),
        cf: () => runCloudflare(env),
        anomaly: () => runAnomalies(env),
        analyst: () => runAnalyst(env),
        iosacq: () => runIosAcq(env),
        playacq: () => runPlayAcq(env),
        meta: () => runMeta(env),

        refresh: async () => {
          await Promise.allSettled([runRevenueCat(env), runStripe(env), runHealth(env)]);
        },
      };
      if (!jobs[job]) return json({ error: "unknown job", jobs: Object.keys(jobs) }, 400);
      await jobs[job]();
      await kvSet(env.DB, "snapshot", await snapshot(env));
      return json({ ok: true, job });
    }
    return json({ error: "not found" }, 404);
  },

  async scheduled(ev: ScheduledController, env: Env, ctx: ExecutionContext) {
    const d = new Date(ev.scheduledTime);
    const min = d.getUTCMinutes();
    const hour = d.getUTCHours();
    const jobs: Promise<void>[] = [safe("health", () => runHealth(env)), safe("ga4rt", () => runGa4Realtime(env))];

    jobs.push(safe("rc", () => runRevenueCat(env)));
    if (min % 15 === 0) jobs.push(safe("stripe", () => runStripe(env)));
    if (min % 15 === 5 && Object.keys(META_ACCOUNTS).length) jobs.push(safe("meta", () => runMeta(env)));
    if (min === 20) jobs.push(safe("iosacq", () => runIosAcq(env)));
    if (min === 25) jobs.push(safe("playacq", () => runPlayAcq(env)));
    if (min === 0) {
      jobs.push(
        safe("ga4", () => runGa4Daily(env)),
        safe("cf", () => runCloudflare(env)),
      );
    }

    jobs.push(safe("rccharts", () => runRevenueCatCharts(env, Math.floor((hour * 60 + min) / 5))));
    if (min === 30) jobs.push(safe("reviews", () => runAscReviews(env)));
    if (min === 15) jobs.push(safe("play", () => runPlay(env)));
    if (min === 35) jobs.push(safe("playsales", () => runPlaySales(env)));
    if (min === 45) jobs.push(safe("asc", () => runAscSales(env)));
    if (min === 0 && hour === 3) jobs.push(safe("ga4deep", () => runGa4Deep(env)));
    await Promise.all(jobs);
    await safe("anomaly", () => runAnomalies(env));
    await safe("snapshot", async () => {
      const s = await snapshot(env);
      await kvSet(env.DB, "snapshot", s);

      const day = dayOf();
      for (const c of s.cards) {
        const n = c.note;
        if (n.mood !== "fire" && n.mood !== "bad") continue;
        await raise(env, {
          app: c.id,
          metric: "note",
          kind: n.key,
          severity: n.mood === "fire" ? "good" : "warning",
          title: `${c.name}: ${n.headline}`,
          body: n.lines.join(" "),
          dedupe: `note:${c.id}:${n.key}:${day}`,
        });
      }
    });

    if (min === 0 && hour === 4) {
      ctx.waitUntil(safe("analyst", () => runAnalyst(env)));
      await env.DB.prepare("DELETE FROM points WHERE ts < ?").bind(now() - 35 * 86400).run();
    }
  },
};
