import { gunzipText } from "./acquisition";
import { APPS } from "../apps";
import type { Env } from "../env";
import { raise } from "../alerts";
import { markSource } from "../sources";
import { addDays, dayOf, fxToUsd, kvGet, kvSet, now, putDaily, signJwt, toUsd } from "../util";

const API = "https://api.appstoreconnect.apple.com";

export async function ascToken(env: Env): Promise<string | null> {
  if (!env.ASC_KEY_ID || !env.ASC_ISSUER_ID || !env.ASC_P8) return null;
  const t = now();
  return signJwt(
    "ES256",
    env.ASC_P8,
    { kid: env.ASC_KEY_ID },
    { iss: env.ASC_ISSUER_ID, iat: t, exp: t + 900, aud: "appstoreconnect-v1" },
  );
}

const isDownload = (pt: string) => /^(1|1F|1T|F1|1E|1EP|1EU)$/.test(pt);
const isIap = (pt: string) => /^(IA1|IA9|IAY|IAC|FI1|IA1-M|IAY-M)$/.test(pt);

export function parseSalesTsv(tsv: string) {
  const lines = tsv.trim().split("\n");
  const head = lines[0].split("\t");
  const col = (n: string) => head.indexOf(n);
  const c = {
    sku: col("SKU"),
    pt: col("Product Type Identifier"),
    units: col("Units"),
    proceeds: col("Developer Proceeds"),
    cur: col("Currency of Proceeds"),
    appleId: col("Apple Identifier"),
    parent: col("Parent Identifier"),
    country: col("Country Code"),
  };
  return lines.slice(1).map((l) => {
    const f = l.split("\t");
    return {
      sku: f[c.sku],
      pt: f[c.pt],
      units: Number(f[c.units]) || 0,
      proceeds: Number(f[c.proceeds]) || 0,
      cur: f[c.cur],
      appleId: f[c.appleId],
      parent: f[c.parent],
      country: f[c.country],
    };
  });
}

export async function runAscSales(env: Env, maxBack = 3) {
  const tok = await ascToken(env);
  if (!tok || !env.ASC_VENDOR) return;
  const H = { authorization: `Bearer ${tok}` };

  let skuMap = await kvGet<Record<string, string>>(env.DB, "asc:skus");
  if (!skuMap) {
    const r = await fetch(`${API}/v1/apps?limit=200&fields[apps]=sku`, { headers: H });
    const j = (await r.json()) as { data: { id: string; attributes: { sku: string } }[] };
    skuMap = Object.fromEntries(j.data.map((a) => [a.attributes.sku, a.id]));
    await kvSet(env.DB, "asc:skus", skuMap);
  }
  const rates = await fxToUsd(env.DB);
  const byAsc = new Map(APPS.filter((a) => a.ascId).map((a) => [a.ascId!, a]));
  const today = dayOf(now(), "America/Los_Angeles");

  for (let back = 1; back <= maxBack; back++) {
    const d = addDays(today, -back);
    const doneKey = `asc:sales:${d}`;
    if (await kvGet(env.DB, doneKey)) continue;
    const url =
      `${API}/v1/salesReports?filter[frequency]=DAILY&filter[reportType]=SALES&filter[reportSubType]=SUMMARY` +
      `&filter[vendorNumber]=${env.ASC_VENDOR}&filter[reportDate]=${d}&filter[version]=1_1`;
    const r = await fetch(url, { headers: { ...H, accept: "application/a-gzip" } });
    if (r.status === 404) continue;
    if (!r.ok) {
      const msg = (await r.text()).slice(0, 300);
      console.log("asc sales", d, r.status, msg);
      for (const a of APPS.filter((x) => x.ascId)) await markSource(env, a.id, "asc_sales", false, `HTTP ${r.status}`);
      continue;
    }
    const tsv = await gunzipText(await r.arrayBuffer());
    const rows = parseSalesTsv(tsv);
    const agg = new Map<string, { downloads: number; proceeds: number; iapUnits: number; countries: Record<string, number> }>();
    for (const row of rows) {
      const ascId = isDownload(row.pt) ? row.appleId : isIap(row.pt) ? skuMap[row.parent] : undefined;
      const app = ascId ? byAsc.get(ascId) : undefined;
      if (!app) continue;
      const a = agg.get(app.id) ?? { downloads: 0, proceeds: 0, iapUnits: 0, countries: {} };
      if (isDownload(row.pt)) {
        a.downloads += row.units;
        a.countries[row.country] = (a.countries[row.country] ?? 0) + row.units;
      }
      if (isIap(row.pt)) a.iapUnits += row.units;
      a.proceeds += toUsd(row.units * row.proceeds, row.cur, rates);
      agg.set(app.id, a);
    }
    for (const app of APPS.filter((x) => x.ascId)) {
      const a = agg.get(app.id) ?? { downloads: 0, proceeds: 0, iapUnits: 0, countries: {} };
      await putDaily(env.DB, app.id, "ios_downloads", d, a.downloads);
      await putDaily(env.DB, app.id, "ios_proceeds_usd", d, Math.round(a.proceeds * 100) / 100);
      await putDaily(env.DB, app.id, "ios_iap_units", d, a.iapUnits);
      await kvSet(env.DB, `asc:countries:${app.id}:${d}`, a.countries);
    }
    await kvSet(env.DB, doneKey, true);
    for (const a of APPS.filter((x) => x.ascId)) await markSource(env, a.id, "asc_sales", true);
  }
}

export async function runAscReviews(env: Env) {
  const tok = await ascToken(env);
  if (!tok) return;
  for (const app of APPS.filter((a) => a.ascId)) {
    try {
      const r = await fetch(
        `${API}/v1/apps/${app.ascId}/customerReviews?sort=-createdDate&limit=20&fields[customerReviews]=rating,title,body,createdDate,territory`,
        { headers: { authorization: `Bearer ${tok}` } },
      );
      await markSource(env, app.id, "asc_reviews", r.ok, r.ok ? "" : `HTTP ${r.status}`);
      if (!r.ok) continue;
      const j = (await r.json()) as {
        data: { id: string; attributes: { rating: number; title: string; body: string; createdDate: string; territory: string } }[];
      };
      for (const rv of j.data) {
        const a = rv.attributes;
        const ins = await env.DB.prepare(
          "INSERT OR IGNORE INTO reviews (id, app, store, rating, title, body, ts, territory) VALUES (?, ?, 'ios', ?, ?, ?, ?, ?)",
        )
          .bind(rv.id, app.id, a.rating, a.title ?? "", a.body ?? "", Math.floor(Date.parse(a.createdDate) / 1000), a.territory)
          .run();
        const fresh = (ins.meta.changes ?? 0) > 0 && Date.parse(a.createdDate) > Date.now() - 3 * 86400_000;
        if (fresh && a.rating <= 2) {
          await raise(env, {
            app: app.id,
            metric: "reviews",
            kind: "review",
            severity: "warning",
            title: `${app.name}: ${a.rating} yıldız yorum (${a.territory})`,
            body: `${a.title}: ${(a.body ?? "").slice(0, 200)}`,
            dedupe: `review:${rv.id}`,
          });
        }
      }
    } catch (e) {
      console.log("asc reviews err", app.id, String(e));
    }
  }
}
