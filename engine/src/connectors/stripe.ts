import { APPS } from "../apps";
import type { Env } from "../env";
import { raise } from "../alerts";
import { markSource } from "../sources";
import { dayOf, fxToUsd, localDayStart, kvGet, kvSet, parseJson, putDaily, putPoint, toUsd } from "../util";

export async function runStripe(env: Env) {
  const keys = parseJson<Record<string, string>>(env.STRIPE_KEYS);
  if (!keys) return;
  const rates = await fxToUsd(env.DB);
  for (const app of APPS) {
    const key = app.stripe ? keys[app.stripe] : undefined;
    if (!key) continue;
    try {
      const backfilled = await kvGet<boolean>(env.DB, `stripe:backfill:${app.id}`);
      const since = backfilled ? localDayStart() : localDayStart() - 35 * 86400;
      const byDay: Record<string, { net: number; sales: number; refunds: number }> = {};
      let url = `https://api.stripe.com/v1/balance_transactions?limit=100&created[gte]=${since}`;
      let gross = 0;
      let net = 0;
      let sales = 0;
      let refunds = 0;
      for (let page = 0; page < 10; page++) {
        const r = await fetch(url, { headers: { authorization: `Bearer ${key}` } });
        if (!r.ok) {
          console.log("stripe", app.id, r.status);
          await markSource(env, app.id, "stripe", false, `HTTP ${r.status}`);
          break;
        }
        const j = (await r.json()) as {
          data: { id: string; type: string; amount: number; net: number; currency: string; created: number }[];
          has_more: boolean;
        };
        for (const t of j.data) {
          const amt = toUsd(t.amount / 100, t.currency, rates);
          const n = toUsd(t.net / 100, t.currency, rates);
          const bd = (byDay[dayOf(t.created)] ??= { net: 0, sales: 0, refunds: 0 });
          if (t.type === "charge" || t.type === "payment") {
            bd.net += n;
            bd.sales++;
          } else if (t.type === "refund" || t.type === "payment_refund") {
            bd.net += n;
            bd.refunds++;
          }
          if (t.created < localDayStart()) continue;
          if (t.type === "charge" || t.type === "payment") {
            gross += amt;
            net += n;
            sales++;
          } else if (t.type === "refund" || t.type === "payment_refund") {
            net += n;
            refunds++;
          }
        }
        if (!j.has_more || !j.data.length) break;
        url = `https://api.stripe.com/v1/balance_transactions?limit=100&created[gte]=${since}&starting_after=${j.data[j.data.length - 1].id}`;
      }
      const day = dayOf();
      if (!backfilled) {
        for (let d = since; d < localDayStart(); d += 86400) {
          const k = dayOf(d + 3600);
          const v = byDay[k] ?? { net: 0, sales: 0, refunds: 0 };
          await putDaily(env.DB, app.id, "revenue_usd", k, Math.round(v.net * 100) / 100);
          await putDaily(env.DB, app.id, "sales", k, v.sales);
        }
        await kvSet(env.DB, `stripe:backfill:${app.id}`, true);
      }
      await putDaily(env.DB, app.id, "revenue_usd", day, net);
      await putDaily(env.DB, app.id, "sales", day, sales);
      await putDaily(env.DB, app.id, "refunds", day, refunds);
      await putPoint(env.DB, app.id, "revenue_today", net);
      await markSource(env, app.id, "stripe", true);

      const lastKey = `stripe:last:${app.id}:${day}`;
      const last = (await kvGet<number>(env.DB, lastKey)) ?? 0;
      if (sales > last) {
        await raise(env, {
          app: app.id,
          metric: "sales",
          kind: "sale",
          severity: "good",
          title: `${app.name}: +${sales - last} satış`,
          body: `Bugün ${sales} satış, net $${net.toFixed(2)}.`,
          dedupe: `sale:${app.id}:${day}:${sales}`,
        });
      }
      await kvSet(env.DB, lastKey, sales);
    } catch (e) {
      console.log("stripe err", app.id, String(e));
    }
  }
}
