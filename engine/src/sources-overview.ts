import { APPS } from "./apps";
import type { Env } from "./env";

const dayUtc = (t = Date.now()) => new Date(t).toISOString().slice(0, 10);
const back = (day: string, n: number) => dayUtc(new Date(`${day}T00:00:00Z`).getTime() - n * 86400e3);

export interface SrcAgg { src: string; n: number; apps: Record<string, number> }
export interface ChannelAgg {
  total: number;
  bySrc: SrcAgg[];
  byApp: { app: string; n: number; cf?: number | null }[];
  from: string;
  to: string;
}
export interface SourcesOverview {
  days: number;
  web: ChannelAgg & {
    cfTotal: number | null;
    landings: { app: string; src: string; page: string; n: number }[];
    refs: { app: string; host: string; src: string; n: number }[];
    since: string | null;
  };
  ios: ChannelAgg | null;
  android: ChannelAgg | null;
}

function aggregate(rows: { app: string; src: string; n: number }[], from: string, to: string): ChannelAgg {
  const S: Record<string, SrcAgg> = {};
  const A: Record<string, number> = {};
  let total = 0;
  for (const r of rows) {
    const s = (S[r.src] ??= { src: r.src, n: 0, apps: {} });
    s.n += r.n;
    s.apps[r.app] = (s.apps[r.app] ?? 0) + r.n;
    A[r.app] = (A[r.app] ?? 0) + r.n;
    total += r.n;
  }
  return {
    total,
    bySrc: Object.values(S).sort((a, b) => b.n - a.n),
    byApp: Object.entries(A).map(([app, n]) => ({ app, n })).sort((a, b) => b.n - a.n),
    from,
    to,
  };
}

export async function sourcesOverview(env: Env, days: number): Promise<SourcesOverview> {
  const today = dayUtc();
  const from = back(today, days - 1);
  const [acq, land, refs, cf, first] = await Promise.all([
    env.DB.prepare("SELECT app, channel, day, src, n FROM acq WHERE day >= ?").bind(back(today, days + 4)).all<{ app: string; channel: string; day: string; src: string; n: number }>(),
    env.DB.prepare("SELECT app, src, page, SUM(n) n FROM acq_land WHERE day >= ? GROUP BY app, src, page ORDER BY n DESC LIMIT 15").bind(from).all<{ app: string; src: string; page: string; n: number }>(),
    env.DB.prepare("SELECT app, host, src, n FROM acq_ref ORDER BY last DESC, n DESC LIMIT 15").all<{ app: string; host: string; src: string; n: number }>(),
    env.DB.prepare("SELECT app, SUM(value) v FROM daily WHERE metric = 'web_visitors_cf' AND day >= ? GROUP BY app").bind(from).all<{ app: string; v: number }>(),
    env.DB.prepare("SELECT MIN(day) d FROM acq WHERE channel = 'web'").first<{ d: string | null }>(),
  ]);

  const webRows = acq.results.filter((r) => r.channel === "web" && r.day >= from);
  const web = aggregate(webRows, from, today);
  web.bySrc.sort((a, b) => b.n - a.n);

  const cfBy = Object.fromEntries(cf.results.map((r) => [r.app, Math.round(r.v)]));
  for (const app of APPS.filter((a) => a.cfZone)) {
    if (!web.byApp.find((x) => x.app === app.id) && cfBy[app.id]) web.byApp.push({ app: app.id, n: 0 });
  }
  for (const b of web.byApp) b.cf = cfBy[b.app] ?? null;
  web.byApp.sort((a, b) => b.n - a.n || (b.cf ?? 0) - (a.cf ?? 0));
  const cfTotal = cf.results.length ? cf.results.reduce((s, r) => s + Math.round(r.v), 0) : null;

  const store = (ch: "ios" | "android"): ChannelAgg | null => {
    const rs = acq.results.filter((r) => r.channel === ch);
    if (!rs.length) return null;
    const last = rs.reduce((m, r) => (r.day > m ? r.day : m), "");
    const f = back(last, days - 1);
    return aggregate(rs.filter((r) => r.day >= f), f, last);
  };

  return {
    days,
    web: { ...web, cfTotal, landings: land.results, refs: refs.results, since: first?.d ?? null },
    ios: store("ios"),
    android: store("android"),
  };
}
