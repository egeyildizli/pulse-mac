import type { Env } from "../env";
import { markSource } from "../sources";
import { addDays, dayOf, kvGet, kvSet, now } from "../util";

export const GRAPH = "https://graph.facebook.com/v21.0";

export const META_ACCOUNTS: Record<string, string> = {};

type Action = { action_type: string; value: string };

const PREF = {
  installs: ["omni_app_install", "mobile_app_install", "app_install"],
  trials: ["omni_start_trial", "app_custom_event.fb_mobile_start_trial", "mobile_app_start_trial", "start_trial_total", "start_trial"],
  subs: ["omni_subscribe", "app_custom_event.fb_mobile_subscribe", "mobile_app_subscribe", "subscribe_total", "subscribe"],
  purchases: ["omni_purchase", "app_custom_event.fb_mobile_purchase", "mobile_app_purchase", "purchase"],
} as const;

export function pickAction(actions: Action[] | undefined, kind: keyof typeof PREF): number {
  const list = actions ?? [];
  for (const t of PREF[kind]) {
    const a = list.find((x) => x.action_type === t);
    if (a) return Number(a.value) || 0;
  }
  return 0;
}

export interface MetaDay {
  day: string; spend: number; impressions: number; clicks: number; installs: number; trials: number; subs: number; purchases: number;
}
export interface MetaCampaign {
  id: string; name: string; status: string; effective: string; budget: number | null;
  spendToday: number; spend7d: number; installsToday: number; installs7d: number;
}

export interface MetaAd {
  id: string; name: string; campaign: string; effective: string;
  spendToday: number; installsToday: number;
  spend: number; impressions: number; clicks: number; ctr: number | null; installs: number; cpi: number | null;
}

type Insight = { ad_id?: string; ad_name?: string; date_start?: string; spend?: string; impressions?: string; clicks?: string; actions?: Action[]; campaign_id?: string; campaign_name?: string };

async function gget<T>(env: Env, path: string, params: Record<string, string>): Promise<T> {
  const q = new URLSearchParams(params);
  const r = await fetch(`${GRAPH}/${path}?${q}`, { method: "GET", headers: { authorization: `Bearer ${env.META_TOKEN ?? ""}` } });
  if (!r.ok) {
    const t = (await r.text()).replace(/access_token=[^&\s"]+/g, "access_token=***").slice(0, 240);
    throw new Error(`meta ${path.replace(/act_\d+/, "act")} ${r.status} ${t}`);
  }
  return (await r.json()) as T;
}

async function glist<T>(env: Env, path: string, params: Record<string, string>): Promise<T[]> {
  const out: T[] = [];
  let j = await gget<{ data: T[]; paging?: { next?: string } }>(env, path, { limit: "200", ...params });
  out.push(...j.data);
  for (let i = 0; i < 4 && j.paging?.next; i++) {
    const r = await fetch(j.paging.next, { method: "GET" });
    if (!r.ok) break;
    j = (await r.json()) as typeof j;
    out.push(...j.data);
  }
  return out;
}

export async function runMeta(env: Env) {
  if (!env.META_TOKEN) return;
  const today = dayOf();
  const from = addDays(today, -30);
  for (const [app, act] of Object.entries(META_ACCOUNTS)) {
    try {
      const acct = await gget<{ name: string; currency: string; account_status: number }>(env, act, { fields: "name,currency,account_status" });
      const rows = await glist<Insight>(env, `${act}/insights`, {
        level: "account", time_increment: "1", time_range: JSON.stringify({ since: from, until: today }),
        fields: "spend,impressions,clicks,actions",
      });
      const byDay = new Map(rows.map((r) => [r.date_start!, r]));
      const ins = env.DB.prepare("INSERT OR REPLACE INTO meta_daily (app, day, spend, impressions, clicks, installs, trials, subs, purchases, ts) VALUES (?,?,?,?,?,?,?,?,?,?)");
      const t = now();
      const stmts: D1PreparedStatement[] = [];
      for (let i = -30; i <= 0; i++) {
        const day = addDays(today, i);
        const r = byDay.get(day);
        stmts.push(ins.bind(app, day, Number(r?.spend) || 0, Number(r?.impressions) || 0, Number(r?.clicks) || 0,
          pickAction(r?.actions, "installs"), pickAction(r?.actions, "trials"), pickAction(r?.actions, "subs"), pickAction(r?.actions, "purchases"), t));
      }
      await env.DB.batch(stmts);

      const camps = await glist<{ id: string; name: string; status: string; effective_status: string; daily_budget?: string }>(env, `${act}/campaigns`, {
        fields: "name,status,effective_status,daily_budget",
      });
      const insC = async (range: Record<string, string>) =>
        new Map((await glist<Insight>(env, `${act}/insights`, { level: "campaign", fields: "campaign_id,campaign_name,spend,actions", ...range })).map((r) => [r.campaign_id!, r]));
      const c7 = await insC({ time_range: JSON.stringify({ since: addDays(today, -6), until: today }) });
      const c1 = await insC({ time_range: JSON.stringify({ since: today, until: today }) });
      const list: MetaCampaign[] = camps.map((c) => ({
        id: c.id, name: c.name, status: c.status, effective: c.effective_status,
        budget: c.daily_budget ? Number(c.daily_budget) / 100 : null,
        spendToday: Number(c1.get(c.id)?.spend) || 0, spend7d: Number(c7.get(c.id)?.spend) || 0,
        installsToday: pickAction(c1.get(c.id)?.actions, "installs"), installs7d: pickAction(c7.get(c.id)?.actions, "installs"),
      }));

      const adsMeta = await glist<{ id: string; name: string; effective_status: string; campaign?: { name: string } }>(env, `${act}/ads`, {
        fields: "name,effective_status,campaign{name}",
      });
      const insA = async (range: Record<string, string>) =>
        new Map((await glist<Insight>(env, `${act}/insights`, { level: "ad", fields: "ad_id,ad_name,spend,impressions,clicks,actions", ...range })).map((r) => [r.ad_id!, r]));
      const a30 = await insA({ time_range: JSON.stringify({ since: from, until: today }) });
      const a1 = await insA({ time_range: JSON.stringify({ since: today, until: today }) });
      const ads: MetaAd[] = adsMeta
        .filter((a) => a30.has(a.id) || a.effective_status === "ACTIVE")
        .map((a) => {
          const r = a30.get(a.id), d = a1.get(a.id);
          const spend = r2(Number(r?.spend) || 0), impressions = Number(r?.impressions) || 0, clicks = Number(r?.clicks) || 0;
          const installs = pickAction(r?.actions, "installs");
          return {
            id: a.id, name: a.name, campaign: a.campaign?.name ?? "", effective: a.effective_status,
            spendToday: r2(Number(d?.spend) || 0), installsToday: pickAction(d?.actions, "installs"),
            spend, impressions, clicks, installs,
            ctr: impressions > 0 ? r2((clicks / impressions) * 100) : null,
            cpi: spend > 0 && installs > 0 ? r2(spend / installs) : null,
          };
        })
        .sort((x, y) => y.spend - x.spend);

      const valOf = async (since: string) => {
        const r = (await glist<{ action_values?: Action[] }>(env, `${act}/insights`, {
          level: "account", fields: "action_values", time_range: JSON.stringify({ since, until: today }),
        }))[0];
        return r2(pickAction(r?.action_values, "subs") + pickAction(r?.action_values, "purchases"));
      };
      const value = { today: await valOf(today), d7: await valOf(addDays(today, -6)), d30: await valOf(from) };
      await kvSet(env.DB, `meta:acct:${app}`, { id: act, name: acct.name, currency: acct.currency, status: acct.account_status, campaigns: list, ads, value, ts: t });
      await markSource(env, app, "meta_ads", true);
    } catch (e) {
      await markSource(env, app, "meta_ads", false, String(e).slice(0, 200));
      console.log("meta fail", app, String(e));
    }
  }
  await computeAndStore(env);
}

export interface Win {
  spend: number; impressions: number; clicks: number; ctr: number | null; cpm: number | null;
  metaInstalls: number; metaCpi: number | null;
  totalInstalls: number | null; blendedCpi: number | null;
  trials: number | null; costPerTrial: number | null;
  subs: number | null; costPerSub: number | null;
  revenue: number | null;
  metaTrials: number; metaSubs: number; metaValue: number;
  roas: number | null;
}

export interface Lift {
  start: string; days: number; reliable: boolean;
  spend: number;
  installsPerDay: { before: number; after: number }; extraInstalls: number;
  trialsPerDay: { before: number; after: number }; subsPerDay: { before: number; after: number }; revenuePerDay: { before: number; after: number };
  extraTrials: number; extraSubs: number; extraRevenue: number;
  costPerExtraTrial: number | null; roas: number | null;
}

export interface MetaOut {
  app: string; ts: number; account: { id: string; name: string; currency: string } | null;
  measured: boolean;
  today: Win; d7: Win; d30: Win;
  days: { day: string; spend: number; metaInstalls: number; totalInstalls: number | null }[];
  campaigns: MetaCampaign[];
  ads: MetaAd[];
  lift: Lift | null;
}

const median = (xs: number[]) => {
  if (!xs.length) return 0;
  const a = [...xs].sort((x, y) => x - y), m = Math.floor(a.length / 2);
  return a.length % 2 ? a[m] : (a[m - 1] + a[m]) / 2;
};

export function computeLift(today: string, rows: MetaDay[], daily: Record<string, Record<string, number>>): Lift | null {
  const start = rows.filter((r) => r.spend > 0).map((r) => r.day).sort()[0];
  if (!start) return null;
  const grossOf = (d: string) => {
    const g = daily.revenue_gross_usd?.[d];
    return g !== undefined ? Math.max(0, g + (daily.refunded_usd?.[d] ?? 0)) : daily.revenue_usd?.[d];
  };
  const series = (f: (d: string) => number | undefined, days: string[]) => days.map(f).filter((v): v is number => v !== undefined);
  const before = Array.from({ length: 14 }, (_, i) => addDays(start, i - 14));
  const after: string[] = [];
  for (let d = start; d <= today; d = addDays(d, 1)) after.push(d);
  const full = after.filter((d) => d < today);
  const base = (f: (d: string) => number | undefined) => median(series(f, before));
  const avg = (xs: number[]) => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : 0);
  const I = (d: string) => { const i = daily.installs?.[d] ?? daily.ios_downloads?.[d], a = daily.android_installs?.[d]; return i === undefined && a === undefined ? undefined : (i ?? 0) + (a ?? 0); };
  const T = (d: string) => daily.trials_new?.[d], S = (d: string) => daily.subs_new?.[d];

  const use = full.length ? full : after;
  const iB = base(I), iA = avg(series(I, use));
  const tB = base(T), sB = base(S), rB = base(grossOf);
  const tA = avg(series(T, use)), sA = avg(series(S, use)), rA = avg(series(grossOf, use));
  const spend = r2(rows.filter((r) => use.includes(r.day)).reduce((a, r) => a + r.spend, 0));
  const n = use.length;
  const extraTrials = r2((tA - tB) * n), extraSubs = r2((sA - sB) * n), extraRevenue = r2((rA - rB) * n);
  return {
    start, days: full.length, reliable: full.length >= 7, spend,
    installsPerDay: { before: r2(iB), after: r2(iA) }, extraInstalls: r2((iA - iB) * n),
    trialsPerDay: { before: r2(tB), after: r2(tA) }, subsPerDay: { before: r2(sB), after: r2(sA) }, revenuePerDay: { before: r2(rB), after: r2(rA) },
    extraTrials, extraSubs, extraRevenue,
    costPerExtraTrial: spend > 0 && extraTrials > 0 ? r2(spend / extraTrials) : null,
    roas: spend > 0 ? r2(Math.max(0, extraRevenue) / spend) : null,
  };
}

const div = (a: number, b: number | null) => (b && b > 0 ? Math.round((a / b) * 100) / 100 : null);
const r2 = (n: number) => Math.round(n * 100) / 100;

export function computeWin(days: string[], md: Map<string, MetaDay>, daily: Record<string, Record<string, number>>, metaValue = 0): Win {
  const g = (m: string, d: string) => daily[m]?.[d];
  const sum = (f: (d: string) => number | undefined) => {
    const vs = days.map(f).filter((v): v is number => v !== undefined);
    return vs.length ? vs.reduce((a, b) => a + b, 0) : null;
  };
  const M = (k: keyof MetaDay) => days.reduce((a, d) => a + (Number(md.get(d)?.[k]) || 0), 0);
  const spend = r2(M("spend")), impressions = M("impressions"), clicks = M("clicks"), metaInstalls = M("installs");
  const metaTrials = M("trials"), metaSubs = M("subs");

  const ios = sum((d) => g("installs", d) ?? g("ios_downloads", d));
  const and = sum((d) => g("android_installs", d));
  const totalInstalls = ios === null && and === null ? null : (ios ?? 0) + (and ?? 0);
  const trials = sum((d) => g("trials_new", d));
  const subs = sum((d) => g("subs_new", d));
  const gross = sum((d) => (g("revenue_gross_usd", d) !== undefined ? Math.max(0, (g("revenue_gross_usd", d) ?? 0) + (g("refunded_usd", d) ?? 0)) : g("revenue_usd", d)));
  return {
    spend, impressions, clicks,
    ctr: impressions > 0 ? r2((clicks / impressions) * 100) : null,
    cpm: impressions > 0 ? r2((spend / impressions) * 1000) : null,
    metaInstalls, metaCpi: spend > 0 ? div(spend, metaInstalls) : null,
    totalInstalls, blendedCpi: spend > 0 ? div(spend, totalInstalls) : null,

    trials, costPerTrial: spend > 0 ? div(spend, metaTrials) : null,
    subs, costPerSub: spend > 0 ? div(spend, metaSubs) : null,
    revenue: gross === null ? null : r2(gross),
    metaTrials, metaSubs, metaValue: r2(metaValue),
    roas: spend > 0 && metaValue > 0 ? r2(metaValue / spend) : null,
  };
}

export function computeMetaOut(app: string, today: string, rows: MetaDay[], daily: Record<string, Record<string, number>>, acct: { id: string; name: string; currency: string; campaigns: MetaCampaign[]; ads?: MetaAd[]; value?: { today: number; d7: number; d30: number } } | null): MetaOut {
  const md = new Map(rows.map((r) => [r.day, r]));
  const range = (n: number) => Array.from({ length: n }, (_, i) => addDays(today, i - (n - 1)));
  const d30 = range(31);
  return {
    app, ts: now(),
    account: acct ? { id: acct.id, name: acct.name, currency: acct.currency } : null,
    measured: rows.some((r) => r.installs > 0),
    today: computeWin([today], md, daily, acct?.value?.today), d7: computeWin(range(7), md, daily, acct?.value?.d7), d30: computeWin(d30, md, daily, acct?.value?.d30),
    days: d30.map((d) => ({
      day: d, spend: md.get(d)?.spend ?? 0, metaInstalls: md.get(d)?.installs ?? 0,
      totalInstalls: (() => {
        const i = daily.installs?.[d] ?? daily.ios_downloads?.[d]; const a = daily.android_installs?.[d];
        return i === undefined && a === undefined ? null : (i ?? 0) + (a ?? 0);
      })(),
    })),
    campaigns: (acct?.campaigns ?? []).sort((a, b) => b.spend7d - a.spend7d || b.spendToday - a.spendToday),
    ads: acct?.ads ?? [],
    lift: computeLift(today, rows, daily),
  };
}

export async function computeAndStore(env: Env) {
  const today = dayOf();
  const from = addDays(today, -30);
  const fromDaily = addDays(today, -60);
  const summary: Record<string, { spendToday: number; spend7d: number }> = {};
  for (const app of Object.keys(META_ACCOUNTS)) {
    const rows = (await env.DB.prepare("SELECT day, spend, impressions, clicks, installs, trials, subs, purchases FROM meta_daily WHERE app = ? AND day >= ? ORDER BY day").bind(app, from).all<MetaDay>()).results;
    const dr = (await env.DB.prepare("SELECT metric, day, value FROM daily WHERE app = ? AND day >= ? AND metric IN ('installs','ios_downloads','android_installs','trials_new','subs_new','revenue_gross_usd','refunded_usd','revenue_usd')").bind(app, fromDaily).all<{ metric: string; day: string; value: number }>()).results;
    const daily: Record<string, Record<string, number>> = {};
    for (const r of dr) (daily[r.metric] ??= {})[r.day] = r.value;
    const acct = await kvGet<{ id: string; name: string; currency: string; campaigns: MetaCampaign[]; ads?: MetaAd[]; value?: { today: number; d7: number; d30: number } }>(env.DB, `meta:acct:${app}`);
    const out = computeMetaOut(app, today, rows, daily, acct);
    await kvSet(env.DB, `meta:out:${app}`, out);
    summary[app] = { spendToday: out.today.spend, spend7d: out.d7.spend };
  }
  await kvSet(env.DB, "meta:summary", summary);
}

export const metaDetail = (env: Env, app: string) => (META_ACCOUNTS[app] ? kvGet<MetaOut>(env.DB, `meta:out:${app}`) : Promise.resolve(null));
export const metaSummary = (env: Env) => kvGet<Record<string, { spendToday: number; spend7d: number }>>(env.DB, "meta:summary");
