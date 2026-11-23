import { APPS } from "./apps";
import type { Env } from "./env";
import { addDays, dayOf, kvGet, now } from "./util";
import { aiConfig, complete } from "./ai";

const SYSTEM = `Sen uygulama geliştiricisine yardım eden bir ürün analistisin. Her sabah tek bir ürün için kısa not yazarsın.
Kurallar:
- Sade, samimi yaz. Lafı dolandırma. Kötü gidiyorsa açıkça söyle, iyi gidiyorsa bunu da söyle.
- Uzun tire (em dash) kullanma.
- En fazla 4 madde. Her madde: ne oldu (sayıyla), neden olabilir, bugün ne denemeli ("şunu denesen olacak gibi").
- Acil bir şey varsa ilk maddeye "Acil:" diye yaz.
- Ekran ve olay tablosunda insanların nerede takılıp çıktığını ara: çok kişinin girip az kaldığı ekranlar, paywall'u görüp almayanlar.
- Veri yetersizse tek cümleyle söyle, uydurma.
- Selamlama ve kapanış yazma.`;

async function context(env: Env, appId: string) {
  const from = addDays(dayOf(), -14);
  const rows = await env.DB.prepare("SELECT metric, day, value FROM daily WHERE app = ? AND day >= ? ORDER BY metric, day")
    .bind(appId, from)
    .all<{ metric: string; day: string; value: number }>();
  const series: Record<string, string> = {};
  for (const r of rows.results) series[r.metric] = (series[r.metric] ? series[r.metric] + ", " : "") + `${r.day.slice(5)}=${r.value}`;
  const alerts = await env.DB.prepare("SELECT title FROM alerts WHERE app = ? AND ts > ? ORDER BY ts DESC LIMIT 10")
    .bind(appId, now() - 7 * 86400)
    .all<{ title: string }>();
  return {
    series,
    retention: await kvGet(env.DB, `ga4:retention:${appId}`),
    screens: await kvGet(env.DB, `ga4:screens:${appId}`),
    events: await kvGet(env.DB, `ga4:events:${appId}`),
    alerts: alerts.results.map((a) => a.title),
  };
}

export async function runAnalyst(env: Env) {
  const cfg = aiConfig(env);
  if (!cfg) return;

  const today = dayOf();
  if ((await kvGet<string>(env.DB, "analyst:day")) === today) return;
  const tries = (await kvGet<{ day: string; n: number }>(env.DB, "analyst:tries")) ?? { day: today, n: 0 };
  const n = tries.day === today ? tries.n : 0;
  if (n >= 3) return;
  const setKv = (k: string, v: unknown) => env.DB.prepare("INSERT OR REPLACE INTO kv (k, v, ts) VALUES (?, ?, ?)").bind(k, JSON.stringify(v), now()).run();
  await setKv("analyst:tries", { day: today, n: n + 1 });
  let wrote = 0;
  const save = async (appId: string, text: string) => {
    await env.DB.prepare("INSERT INTO insights (app, ts, kind, text) VALUES (?, ?, 'daily', ?)").bind(appId, now(), text).run();
    if (++wrote === 1) await setKv("analyst:day", today);
  };
    for (const app of APPS.filter((a) => a.kind !== "infra" && a.kind !== "social")) {
      const ctx = await context(env, app.id);
      if (Object.keys(ctx.series).length === 0) continue;
      try {
        const text = await complete(cfg, SYSTEM + (env.LANG === "en" ? "\n- Write in English." : "\n- Türkçe yaz."), `Ürün: ${app.name} (${app.kind}). Veriler JSON:\n${JSON.stringify(ctx)}`, 2000);
        if (text) await save(app.id, text);
      } catch (e) {
        console.log("analyst err", app.id, String(e));
        if (/\b429\b/.test(String(e))) break;
      }
    }
}
