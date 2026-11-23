import { APPS } from "../apps";
import type { Env } from "../env";
import { addDays, dayOf, kvGet, kvSet, parseJson } from "../util";
import { markSource } from "../sources";

type RcKeys = Record<string, { project: string; key: string }>;

const CHARTS: Record<string, Record<number, string>> = {
  customers_active: { 0: "users" },
  customers_new: { 0: "new_users" },
  paywall_encounter: { 0: "installs", 1: "paywall_views" },
  revenue: { 0: "revenue_usd", 1: "transactions" },
  "revenue#gross": { 0: "revenue_gross_usd" },
  trials_new: { 0: "trials_new" },
  actives_new: { 5: "subs_new" },
  churn: { 1: "subs_churned" },
  paywall_conversion: { 1: "paywall_conversions" },
  refunds: { 0: "refunded_usd" },
  ad_revenue: { 1: "ad_impressions", 2: "ad_revenue_usd" },
};

export async function runRevenueCatCharts(env: Env, only?: number) {
  const keys = parseJson<RcKeys>(env.RC_KEYS);
  if (!keys) return;
  const today = dayOf(Date.now() / 1000, "UTC");
  const list = APPS.filter((a) => a.rcProject && keys[a.rcProject]);
  const targets = only === undefined ? list : list.length ? [list[only % list.length]] : [];
  for (const app of targets) {
    const cfg = keys[app.rcProject!];
    const backfilled = await kvGet<boolean>(env.DB, `rc:backfill:${app.id}`);
    const start = addDays(today, backfilled ? -3 : -35);
    let ok = 0;
    let lastErr = "";
    for (const [key, measures] of Object.entries(CHARTS)) {
      const chart = key.split("#")[0];
      try {
        const r = await fetch(
          `https://api.revenuecat.com/v2/projects/${cfg.project}/charts/${chart}?resolution=0&start_date=${start}&end_date=${today}` +
            (key === "revenue" ? `&selectors=${encodeURIComponent(JSON.stringify({ revenue_type: "proceeds" }))}` : ""),
          { headers: { authorization: `Bearer ${cfg.key}` } },
        );
        if (r.status === 429) {
          lastErr = "429 hız sınırı";
          break;
        }
        if (!r.ok) {
          lastErr = `${chart} ${r.status}`;
          continue;
        }
        const j = (await r.json()) as { values: { cohort: number; measure: number; value: number }[] };

        const stmts: D1PreparedStatement[] = [];
        const ins = env.DB.prepare("INSERT OR REPLACE INTO daily (app, metric, day, value) VALUES (?, ?, ?, ?)");
        for (const v of j.values) {
          let metric = measures[v.measure];
          if (!metric) continue;
          if (app.ga4Property && (metric === "users" || metric === "new_users")) metric = `rc_${metric}`;
          stmts.push(ins.bind(app.id, metric, dayOf(v.cohort, "UTC"), Math.round(v.value * 100) / 100));
        }
        if (stmts.length) await env.DB.batch(stmts);
        ok++;
      } catch (e) {
        lastErr = String(e);
      }
    }
    if (ok === Object.keys(CHARTS).length) await kvSet(env.DB, `rc:backfill:${app.id}`, true);
    await markSource(env, app.id, "revenuecat_charts", ok > 0, lastErr);
  }
}
