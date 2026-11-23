import { APPS } from "../apps";
import type { Env } from "../env";
import { markSource } from "../sources";
import { kvGet, kvSet, putDaily, putPoint } from "../util";

const CF = "https://api.cloudflare.com/client/v4";

async function zoneTag(env: Env, name: string): Promise<string | null> {
  const k = `cf:zone:${name}`;
  const c = await kvGet<string>(env.DB, k);
  if (c) return c;
  const r = await fetch(`${CF}/zones?name=${encodeURIComponent(name)}`, { headers: { authorization: `Bearer ${env.CF_API_TOKEN}` } });
  const j = (await r.json()) as { result?: { id: string }[] };
  const id = j.result?.[0]?.id ?? null;
  if (id) await kvSet(env.DB, k, id);
  return id;
}

export async function runCloudflare(env: Env) {
  if (!env.CF_API_TOKEN) return;
  const since = new Date(Date.now() - 2 * 86400_000).toISOString().slice(0, 10);
  const hourSince = new Date(Date.now() - 3 * 3600_000).toISOString();
  for (const app of APPS.filter((a) => a.cfZone)) {
    const tag = await zoneTag(env, app.cfZone!);
    if (!tag) continue;
    const query = `query($tag: String!, $since: Date!, $h: Time!) { viewer { zones(filter: {zoneTag: $tag}) {
      d: httpRequests1dGroups(limit: 3, filter: {date_geq: $since}, orderBy: [date_ASC]) { dimensions { date } uniq { uniques } sum { requests pageViews threats } }
      h: httpRequests1hGroups(limit: 3, filter: {datetime_geq: $h}, orderBy: [datetime_DESC]) { dimensions { datetime } uniq { uniques } }
    } } }`;
    try {
      const r = await fetch(`${CF}/graphql`, {
        method: "POST",
        headers: { authorization: `Bearer ${env.CF_API_TOKEN}`, "content-type": "application/json" },
        body: JSON.stringify({ query, variables: { tag, since, h: hourSince } }),
      });
      const j = (await r.json()) as {
        data?: { viewer: { zones: { d: any[]; h: any[] }[] } };
        errors?: unknown;
      };
      const z = j.data?.viewer.zones[0];
      await markSource(env, app.id, "cloudflare", !!z, z ? "" : "zone erişimi yok");
      if (!z) {
        console.log("cf", app.id, JSON.stringify(j.errors).slice(0, 300));
        continue;
      }

      const pixel = (await kvGet<{ ok: boolean }>(env.DB, `src:${app.id}:web_counter`))?.ok === true;
      for (const g of z.d) {
        await putDaily(env.DB, app.id, "web_visitors_cf", g.dimensions.date, g.uniq.uniques);
        if (!pixel) await putDaily(env.DB, app.id, "web_visitors", g.dimensions.date, g.uniq.uniques);
        else {
          const r = await env.DB.prepare("SELECT COALESCE(SUM(n), 0) n FROM acq WHERE app = ? AND channel = 'web' AND day = ?").bind(app.id, g.dimensions.date).first<{ n: number }>();
          await putDaily(env.DB, app.id, "web_visitors", g.dimensions.date, r?.n ?? 0);
        }
        await putDaily(env.DB, app.id, "web_requests", g.dimensions.date, g.sum.requests);
        await putDaily(env.DB, app.id, "web_pageviews", g.dimensions.date, g.sum.pageViews);
        await putDaily(env.DB, app.id, "web_threats", g.dimensions.date, g.sum.threats);
      }
      if (z.h[0] && !pixel) await putPoint(env.DB, app.id, "web_visitors_1h", z.h[0].uniq.uniques);
    } catch (e) {
      console.log("cf err", app.id, String(e));
    }
  }
}
