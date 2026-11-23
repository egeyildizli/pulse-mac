import { APPS } from "../apps";
import type { Env } from "../env";
import { markSource } from "../sources";
import { addDays, dayOf, kvGet, kvSet, now, parseJson, putDaily, putPoint, signJwt } from "../util";

interface SA {
  client_email: string;
  private_key: string;
}

const TOKENS = new Map<string, { tok: string; exp: number }>();

export async function googleToken(env: Env, scope = "https://www.googleapis.com/auth/analytics.readonly"): Promise<string | null> {
  const sa = parseJson<SA>(env.GA4_SA);
  if (!sa) return null;

  const cacheKey = `${sa.client_email}|${scope}`;
  const cached = TOKENS.get(cacheKey);
  if (cached && cached.exp > now() + 120) return cached.tok;
  const t = now();
  const assertion = await signJwt(
    "RS256",
    sa.private_key,
    {},
    {
      iss: sa.client_email,
      scope,
      aud: "https://oauth2.googleapis.com/token",
      iat: t,
      exp: t + 3600,
    },
  );
  const r = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: `grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=${assertion}`,
  });
  const j = (await r.json()) as { access_token?: string; expires_in?: number };
  if (!j.access_token) {
    console.log("ga4 token fail", JSON.stringify(j));
    return null;
  }
  TOKENS.set(cacheKey, { tok: j.access_token, exp: t + (j.expires_in ?? 3600) });
  return j.access_token;
}

type Row = { dimensionValues?: { value: string }[]; metricValues?: { value: string }[] };

async function ga(tok: string, prop: string, method: string, body: unknown, beta = "v1beta"): Promise<Row[] | null> {
  const r = await fetch(`https://analyticsdata.googleapis.com/${beta}/properties/${prop}:${method}`, {
    method: "POST",
    headers: { authorization: `Bearer ${tok}`, "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!r.ok) {
    console.log("ga4", prop, method, r.status, (await r.text()).slice(0, 300));
    return null;
  }
  const j = (await r.json()) as { rows?: Row[] };
  return j.rows ?? [];
}

const num = (r: Row, i: number) => Number(r.metricValues?.[i]?.value ?? 0);
const dim = (r: Row, i: number) => r.dimensionValues?.[i]?.value ?? "";

export async function runGa4Realtime(env: Env) {
  const tok = await googleToken(env);
  if (!tok) return;
  for (const app of APPS.filter((a) => a.ga4Property)) {
    const total = await ga(tok, app.ga4Property!, "runRealtimeReport", { metrics: [{ name: "activeUsers" }] });
    if (!total) continue;
    const users = total.length ? num(total[0], 0) : 0;
    await putPoint(env.DB, app.id, "rt_users", users);
    const screens = await ga(tok, app.ga4Property!, "runRealtimeReport", {
      dimensions: [{ name: "unifiedScreenName" }],
      metrics: [{ name: "activeUsers" }],
      limit: 6,
    });
    if (screens) await kvSet(env.DB, `ga4:rtscreens:${app.id}`, screens.map((r) => ({ screen: dim(r, 0), users: num(r, 0) })));
  }
}

export async function runGa4Daily(env: Env) {
  const tok = await googleToken(env);
  if (!tok) return;
  for (const app of APPS.filter((a) => a.ga4Property)) {
    const rows = await ga(tok, app.ga4Property!, "runReport", {
      dateRanges: [{ startDate: "2daysAgo", endDate: "today" }],
      dimensions: [{ name: "date" }],
      metrics: [
        { name: "activeUsers" },
        { name: "newUsers" },
        { name: "sessions" },
        { name: "averageSessionDuration" },
        { name: "screenPageViews" },
        { name: "purchaseRevenue" },
      ],
    });
    await markSource(env, app.id, "ga4", !!rows, rows ? "" : "GA4 erişimi yok");
    if (!rows) continue;
    for (const r of rows) {
      const d = dim(r, 0);
      const day = `${d.slice(0, 4)}-${d.slice(4, 6)}-${d.slice(6, 8)}`;
      await putDaily(env.DB, app.id, "users", day, num(r, 0));
      await putDaily(env.DB, app.id, "new_users", day, num(r, 1));
      await putDaily(env.DB, app.id, "sessions", day, num(r, 2));
      await putDaily(env.DB, app.id, "avg_session_s", day, Math.round(num(r, 3)));
      await putDaily(env.DB, app.id, "views", day, num(r, 4));
    }
  }
}

export async function runGa4Deep(env: Env) {
  const tok = await googleToken(env);
  if (!tok) return;
  const today = dayOf();
  for (const app of APPS.filter((a) => a.ga4Property)) {
    const end = addDays(today, -1);
    const start = addDays(today, -15);
    const rows = await ga(tok, app.ga4Property!, "runReport", {
      dimensions: [{ name: "cohort" }, { name: "cohortNthDay" }],
      metrics: [{ name: "cohortActiveUsers" }],
      cohortSpec: {
        cohorts: [{ name: "c", dimension: "firstSessionDate", dateRange: { startDate: start, endDate: end } }],
        cohortsRange: { granularity: "DAILY", startOffset: 0, endOffset: 7 },
      },
    });
    if (rows && rows.length) {
      const byDay: Record<number, number> = {};
      for (const r of rows) byDay[Number(dim(r, 1))] = (byDay[Number(dim(r, 1))] ?? 0) + num(r, 0);
      const d0 = byDay[0] ?? 0;
      if (d0 > 0) {
        const curve = Array.from({ length: 8 }, (_, i) => Math.round(((byDay[i] ?? 0) / d0) * 1000) / 10);
        await kvSet(env.DB, `ga4:retention:${app.id}`, { cohortUsers: d0, curve });
        await putDaily(env.DB, app.id, "ret_d1", today, curve[1]);
        await putDaily(env.DB, app.id, "ret_d7", today, curve[7]);
      }
    }

    const screens = await ga(tok, app.ga4Property!, "runReport", {
      dateRanges: [{ startDate: "7daysAgo", endDate: "yesterday" }],
      dimensions: [{ name: "unifiedScreenName" }],
      metrics: [{ name: "activeUsers" }, { name: "screenPageViews" }, { name: "userEngagementDuration" }],
      orderBys: [{ metric: { metricName: "activeUsers" }, desc: true }],
      limit: 25,
    });
    if (screens)
      await kvSet(
        env.DB,
        `ga4:screens:${app.id}`,
        screens.map((r) => ({
          screen: dim(r, 0),
          users: num(r, 0),
          views: num(r, 1),
          secPerUser: num(r, 0) ? Math.round(num(r, 2) / num(r, 0)) : 0,
        })),
      );

    const events = await ga(tok, app.ga4Property!, "runReport", {
      dateRanges: [{ startDate: "7daysAgo", endDate: "yesterday" }],
      dimensions: [{ name: "eventName" }],
      metrics: [{ name: "totalUsers" }, { name: "eventCount" }],
      orderBys: [{ metric: { metricName: "totalUsers" }, desc: true }],
      limit: 30,
    });
    if (events)
      await kvSet(env.DB, `ga4:events:${app.id}`, events.map((r) => ({ event: dim(r, 0), users: num(r, 0), count: num(r, 1) })));
  }
}
