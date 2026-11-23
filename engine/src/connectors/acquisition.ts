import { gunzipSync } from "node:zlib";

import { APPS } from "../apps";
import type { Env } from "../env";
import { markSource } from "../sources";
import { kvGet, kvSet, now } from "../util";
import { ascToken } from "./asc";
import { parsePlayCsv } from "./play";
import { googleToken } from "./ga4";

const SOURCES: [RegExp, string][] = [
  [/(^|\.)chatgpt\.com$|(^|\.)openai\.com$/, "chatgpt"],
  [/(^|\.)perplexity\.ai$/, "perplexity"],
  [/(^|\.)claude\.ai$/, "claude"],
  [/(^|\.)gemini\.google\.com$|(^|\.)bard\.google\.com$/, "gemini"],
  [/(^|\.)copilot\.microsoft\.com$/, "copilot"],
  [/(^|\.)you\.com$|(^|\.)phind\.com$|(^|\.)kagi\.com$/, "ai-other"],
  [/(^|\.)google\.[a-z.]+$/, "google"],
  [/(^|\.)bing\.com$/, "bing"],
  [/(^|\.)duckduckgo\.com$/, "duckduckgo"],
  [/(^|\.)yandex\.[a-z.]+$|(^|\.)ya\.ru$/, "yandex"],
  [/(^|\.)baidu\.com$/, "baidu"],
  [/(^|\.)naver\.com$/, "naver"],
  [/(^|\.)yahoo\.[a-z.]+$/, "yahoo"],
  [/(^|\.)ecosia\.org$|(^|\.)brave\.com$|(^|\.)qwant\.com$|(^|\.)startpage\.com$/, "search-other"],
  [/(^|\.)reddit\.com$/, "reddit"],
  [/(^|\.)youtube\.com$|(^|\.)youtu\.be$/, "youtube"],
  [/(^|\.)github\.com$/, "github"],
  [/(^|\.)stackoverflow\.com$|(^|\.)stackexchange\.com$/, "stackoverflow"],
  [/(^|\.)x\.com$|(^|\.)t\.co$|(^|\.)twitter\.com$/, "x"],
  [/(^|\.)facebook\.com$|(^|\.)instagram\.com$|(^|\.)threads\.net$|^l\.instagram\.com$|^lm\.facebook\.com$/, "meta"],
  [/(^|\.)tiktok\.com$/, "tiktok"],
  [/(^|\.)linkedin\.com$|(^|\.)lnkd\.in$/, "linkedin"],
  [/(^|\.)producthunt\.com$/, "producthunt"],
  [/(^|\.)apple\.com$/, "apple"],
];
const clean = (s: string | null, n = 80) => String(s ?? "").toLowerCase().replace(/[^a-z0-9._/-]/g, "").slice(0, n);

export function webSource(refHost: string, utm: string, ownHost: string): string {
  const u = clean(utm, 30).replace(/\//g, "");
  if (u) {
    for (const [re, name] of SOURCES) if (re.test(u) || re.test(`${u}.com`)) return name;
    return `utm:${u}`;
  }
  const host = clean(refHost).replace(/^www\./, "").split("/")[0];
  if (!host || host === ownHost || host.endsWith(`.${ownHost}`)) return "direct";
  for (const [re, name] of SOURCES) if (re.test(host)) return name;
  return "ref:" + host;
}

const BOT = /bot|crawl|spider|slurp|preview|headless|lighthouse|pingdom|uptime|monitor|curl|wget|python|node-fetch|axios/i;
const dayUtc = (t = Date.now()) => new Date(t).toISOString().slice(0, 10);

const ASC = "https://api.appstoreconnect.apple.com";

export async function gunzipText(buf: ArrayBuffer): Promise<string> {
  return new TextDecoder().decode(gunzipSync(new Uint8Array(buf)));
}

export async function runIosAcq(env: Env) {
  const tok = await ascToken(env);
  if (!tok) return;
  const H = { authorization: `Bearer ${tok}` };
  const get = async (p: string) => {
    const r = await fetch(`${ASC}${p}`, { headers: H });
    if (!r.ok) throw new Error(`${p.split("?")[0]} ${r.status}`);
    return (await r.json()) as any;
  };
  for (const a of APPS.filter((x) => x.ascId)) {
    try {
      let reqs = await get(`/v1/apps/${a.ascId}/analyticsReportRequests`);
      let rid: string | undefined = reqs.data?.find((q: any) => q.attributes.accessType === "ONGOING")?.id;
      if (!rid) {
        const r = await fetch(`${ASC}/v1/analyticsReportRequests`, {
          method: "POST",
          headers: { ...H, "content-type": "application/json" },
          body: JSON.stringify({ data: { type: "analyticsReportRequests", attributes: { accessType: "ONGOING" }, relationships: { app: { data: { type: "apps", id: a.ascId } } } } }),
        });
        if (!r.ok) throw new Error(`rapor talebi ${r.status}`);
        await markSource(env, a.id, "ios_acq", true, "rapor talebi açıldı, veri 1-2 gün içinde");
        continue;
      }
      const reps = await get(`/v1/analyticsReportRequests/${rid}/reports?filter[category]=COMMERCE`);
      const rep = reps.data?.find((x: any) => x.attributes.name === "App Downloads Standard");
      if (!rep) continue;
      const inst = await get(`/v1/analyticsReports/${rep.id}/instances?filter[granularity]=DAILY&limit=40`);
      const done = (await kvGet<string[]>(env.DB, `iosacq:done:${a.id}`)) ?? [];
      const fresh = (inst.data ?? []).filter((i: any) => !done.includes(i.id)).slice(0, 8);
      for (const i of fresh) {
        const segs = await get(`/v1/analyticsReportInstances/${i.id}/segments`);
        const agg: Record<string, Record<string, number>> = {};
        for (const sg of segs.data ?? []) {
          const r = await fetch(sg.attributes.url);
          if (!r.ok) continue;
          const txt = await gunzipText(await r.arrayBuffer());
          const lines = txt.split(/\r?\n/).filter(Boolean);
          const head = lines[0].split("\t");
          const ix = (n: string) => head.indexOf(n);
          const [iD, iT, iS, iC] = [ix("Date"), ix("Download Type"), ix("Source Type"), ix("Counts")];
          for (const l of lines.slice(1)) {
            const f = l.split("\t");
            if (f[iT] !== "First-time download" && f[iT] !== "Redownload") continue;
            const key = f[iT] === "Redownload" ? `${f[iS]}|yeniden` : f[iS];
            ((agg[f[iD]] ??= {})[key] ??= 0), (agg[f[iD]][key] += Number(f[iC] || 0));
          }
        }
        const stmts: D1PreparedStatement[] = [];
        for (const [day, m] of Object.entries(agg)) {
          stmts.push(env.DB.prepare("DELETE FROM acq WHERE app = ? AND channel = 'ios' AND day = ?").bind(a.id, day));
          for (const [src, n] of Object.entries(m)) stmts.push(env.DB.prepare("INSERT OR REPLACE INTO acq (app, channel, day, src, n) VALUES (?, 'ios', ?, ?, ?)").bind(a.id, day, src, n));
        }
        if (stmts.length) await env.DB.batch(stmts);
        done.push(i.id);
      }
      await kvSet(env.DB, `iosacq:done:${a.id}`, done.slice(-80));
      await markSource(env, a.id, "ios_acq", true);
    } catch (e) {
      await markSource(env, a.id, "ios_acq", false, String(e).slice(0, 200));
    }
  }
}

const ym = (d: Date) => `${d.getUTCFullYear()}${String(d.getUTCMonth() + 1).padStart(2, "0")}`;

export async function runPlayAcq(env: Env) {
  if (!env.PLAY_BUCKET) return;
  const tok = await googleToken(env, "https://www.googleapis.com/auth/devstorage.read_only");
  if (!tok) return;
  const H = { authorization: `Bearer ${tok}` };
  const nowD = new Date();
  const months = [ym(new Date(Date.UTC(nowD.getUTCFullYear(), nowD.getUTCMonth() - 1, 1))), ym(nowD)];
  for (const a of APPS.filter((x) => x.playPackage)) {
    try {
      const seen: string[] = [];
      const stmts: D1PreparedStatement[] = [];
      for (const m of months) {
        const prefix = `stats/store_performance/store_performance_${a.playPackage}_${m}`;
        const l = await fetch(`https://storage.googleapis.com/storage/v1/b/${env.PLAY_BUCKET}/o?prefix=${encodeURIComponent(prefix)}`, { headers: H });
        if (!l.ok) throw new Error(`liste ${l.status}`);
        const items = (((await l.json()) as any).items ?? []) as { name: string }[];
        for (const it of items) seen.push(it.name.split("/").pop()!);
        const obj = items.find((x) => /traffic_source/.test(x.name));
        if (!obj) continue;
        const r = await fetch(`https://storage.googleapis.com/storage/v1/b/${env.PLAY_BUCKET}/o/${encodeURIComponent(obj.name)}?alt=media`, { headers: H });
        if (!r.ok) throw new Error(`csv ${r.status}`);
        const rows = parsePlayCsv(await r.arrayBuffer());
        if (rows[0]) await kvSet(env.DB, `playacq:head`, Object.keys(rows[0]));
        const kSrc = Object.keys(rows[0] ?? {}).find((k) => /traffic source/i.test(k)) ?? "Traffic Source";
        const kN = Object.keys(rows[0] ?? {}).find((k) => /acquisitions/i.test(k) && !/retained|rate|visitors/i.test(k)) ?? "";
        const agg: Record<string, Record<string, number>> = {};
        for (const row of rows) {
          const day = row["Date"];
          const n = Number(row[kN] || 0);
          if (!day || !n) continue;
          ((agg[day] ??= {})[row[kSrc] || "Diğer"] ??= 0), (agg[day][row[kSrc] || "Diğer"] += n);
        }
        for (const [day, mm] of Object.entries(agg)) {
          stmts.push(env.DB.prepare("DELETE FROM acq WHERE app = ? AND channel = 'android' AND day = ?").bind(a.id, day));
          for (const [src, n] of Object.entries(mm)) stmts.push(env.DB.prepare("INSERT OR REPLACE INTO acq (app, channel, day, src, n) VALUES (?, 'android', ?, ?, ?)").bind(a.id, day, src, n));
        }
      }
      await kvSet(env.DB, `playacq:files:${a.id}`, seen);
      if (stmts.length) await env.DB.batch(stmts);

      await markSource(env, a.id, "android_acq", true, stmts.length ? "" : "Play edinme raporu henüz yok");
    } catch (e) {
      await markSource(env, a.id, "android_acq", false, String(e).slice(0, 200));
    }
  }
}

export interface AcqRow {
  src: string;
  v7: number;
  v30: number;
}
export interface Acquisition {
  web?: { rows: AcqRow[]; landings: { src: string; page: string; n: number }[]; refs: { host: string; n: number; src: string }[] };
  ios?: { rows: AcqRow[]; lastDay: string | null; firstDay: string | null };
  android?: { rows: AcqRow[]; lastDay: string | null; firstDay: string | null };
  webFirstDay?: string | null;
}

export async function acquisition(env: Env, id: string): Promise<Acquisition | null> {
  const app = APPS.find((a) => a.id === id);
  if (!app) return null;
  const from30 = dayUtc(Date.now() - 30 * 86400e3);
  const res = await env.DB.prepare("SELECT channel, day, src, n FROM acq WHERE app = ? AND day >= ?").bind(id, from30).all<{ channel: string; day: string; src: string; n: number }>();
  const out: Acquisition = {};
  for (const ch of ["web", "ios", "android"] as const) {
    const rs = res.results.filter((r) => r.channel === ch);
    if (!rs.length) continue;

    const last = rs.reduce((m, r) => (r.day > m ? r.day : m), "");
    const first = rs.reduce((m, r) => (r.day < m ? r.day : m), last);
    const from7 = dayUtc(new Date(`${last}T00:00:00Z`).getTime() - 6 * 86400e3);
    const agg: Record<string, AcqRow> = {};
    for (const r of rs) {
      const x = (agg[r.src] ??= { src: r.src, v7: 0, v30: 0 });
      x.v30 += r.n;
      if (r.day >= from7) x.v7 += r.n;
    }
    const rows = Object.values(agg).sort((a, b) => b.v30 - a.v30);
    if (ch === "web") {
      const land = await env.DB.prepare("SELECT src, page, SUM(n) n FROM acq_land WHERE app = ? AND day >= ? GROUP BY src, page ORDER BY n DESC LIMIT 12").bind(id, from30).all<{ src: string; page: string; n: number }>();
      const refs = await env.DB.prepare("SELECT host, n, src FROM acq_ref WHERE app = ? ORDER BY n DESC LIMIT 10").bind(id).all<{ host: string; n: number; src: string }>();
      out.web = { rows, landings: land.results, refs: refs.results };
      out.webFirstDay = first;
    } else out[ch] = { rows, lastDay: last, firstDay: first };
  }
  return Object.keys(out).length ? out : null;
}
