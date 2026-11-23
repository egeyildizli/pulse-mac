import { APPS } from "../apps";
import type { Env } from "../env";
import { raise } from "../alerts";
import { dayOf, localDayStart, kvGet, kvSet, now, parseJson, putDaily, putPoint } from "../util";

type RcKeys = Record<string, { project: string; key: string }>;

export async function runRevenueCat(env: Env) {
  const keys = parseJson<RcKeys>(env.RC_KEYS);
  if (!keys) return;
  for (const app of APPS) {
    const cfg = app.rcProject ? keys[app.rcProject] : undefined;
    if (!cfg) continue;
    try {
      const r = await fetch(`https://api.revenuecat.com/v2/projects/${cfg.project}/metrics/overview`, {
        headers: { authorization: `Bearer ${cfg.key}` },
      });
      if (!r.ok) {
        console.log("rc", app.id, r.status, await r.text());
        continue;
      }
      const j = (await r.json()) as { metrics: { id: string; value: number }[] };
      const m = Object.fromEntries(j.metrics.map((x) => [x.id, x.value]));
      const day = dayOf();
      const map: Record<string, string> = {
        active_subscriptions: "active_subs",
        active_trials: "trials",
        mrr: "mrr",
        revenue: "revenue_28d",
        new_customers: "new_customers_28d",
        active_users: "active_users_28d",
      };
      for (const [src, dst] of Object.entries(map)) {
        if (typeof m[src] !== "number") continue;
        await putPoint(env.DB, app.id, dst, m[src]);
        await putDaily(env.DB, app.id, dst, day, m[src]);
      }

      const startKey = `rc:start:${app.id}:${day}`;
      let start = await kvGet<{ subs: number; trials: number }>(env.DB, startKey);
      if (!start) {
        const prev = await env.DB.prepare(
          "SELECT value FROM points WHERE app = ? AND metric = 'active_subs' AND ts < ? ORDER BY ts DESC LIMIT 1",
        )
          .bind(app.id, localDayStart())
          .first<{ value: number }>();
        start = { subs: prev?.value ?? m.active_subscriptions ?? 0, trials: m.active_trials ?? 0 };
        await kvSet(env.DB, startKey, start);
      }
      const net = (m.active_subscriptions ?? 0) - start.subs;
      await putDaily(env.DB, app.id, "subs_net_today", day, net);

      const prevKey = `rc:prev:${app.id}`;
      const prev = await kvGet<{ subs: number; trials: number; rev: number; day: string }>(env.DB, prevKey);
      const cur = { subs: m.active_subscriptions ?? 0, trials: m.active_trials ?? 0, rev: m.revenue ?? 0, day: dayOf(now(), "UTC") };

      const webhookLive = (await kvGet(env.DB, `src:${app.id}:revenuecat_live`)) !== null;
      if (prev && !webhookLive) {
        const dSubs = cur.subs - prev.subs;
        const dTrials = cur.trials - prev.trials;

        const dRev = prev.day === cur.day ? Math.round((cur.rev - prev.rev) * 100) / 100 : 0;
        const t = now();
        const log = async (type: string, period: string, price: number, n = 1) => {
          for (let i = 0; i < n; i++)
            await env.DB.prepare(
              "INSERT OR IGNORE INTO rc_events (id, app, type, period_type, product, price_usd, store, country, ts, trial_conversion, env) VALUES (?, ?, ?, ?, '', ?, '', '', ?, 0, 'POLL')",
            )
              .bind(`poll:${app.id}:${type}:${period}:${t}:${i}`, app.id, type, period, i === 0 ? price : 0, t)
              .run();
        };
        const money = dRev > 0 ? ` ($${dRev.toFixed(2)} brüt)` : "";
        if (dSubs > 0) {
          await log("INITIAL_PURCHASE", "NORMAL", Math.max(dRev, 0), dSubs);
          await raise(env, {
            app: app.id, metric: "active_subs", kind: "sub", severity: "good",
            title: `${app.name}: +${dSubs} yeni abone 🎉${money}`,
            body: `Aktif abone ${cur.subs}, MRR $${Math.round(m.mrr ?? 0)}.`,
            dedupe: `sub:${app.id}:${t}`,
          });
        } else if (dRev > 0.5) {
          await log("RENEWAL", "NORMAL", dRev);
          await raise(env, {
            app: app.id, metric: "revenue", kind: "renewal", severity: "good",
            title: `${app.name}: para geldi 💰 $${dRev.toFixed(2)} brüt`,
            body: "Yenileme ya da tek seferlik satın alma.",
            dedupe: `rev:${app.id}:${t}`,
          });
        }
        if (dTrials > 0) {
          await log("INITIAL_PURCHASE", "TRIAL", 0, dTrials);
          await raise(env, {
            app: app.id, metric: "trials", kind: "trial", severity: "good",
            title: `${app.name}: +${dTrials} yeni deneme başladı`,
            body: `Denemede ${cur.trials} kişi var.`,
            dedupe: `trial:${app.id}:${t}`,
          });
        }
        if (dSubs < 0) {
          await log("CANCELLATION", "NORMAL", 0, -dSubs);
          await raise(env, {
            app: app.id, metric: "active_subs", kind: "cancel", severity: "info",
            title: `${app.name}: ${-dSubs} abonelik sona erdi`,
            body: `Aktif abone ${cur.subs}.`,
            dedupe: `lost:${app.id}:${t}`,
          });
        }
      }
      await kvSet(env.DB, prevKey, cur);
    } catch (e) {
      console.log("rc err", app.id, String(e));
    }
  }
}
