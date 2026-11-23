import { APPS } from "../apps";
import type { Env } from "../env";
import { raise } from "../alerts";
import { markSource } from "../sources";
import { googleToken } from "./ga4";

const SCOPE = "https://www.googleapis.com/auth/devstorage.read_only https://www.googleapis.com/auth/androidpublisher";

export function parsePlayCsv(buf: ArrayBuffer): Record<string, string>[] {
  let text = new TextDecoder("utf-16le").decode(buf);
  if (!text.includes(",")) text = new TextDecoder("utf-8").decode(buf);
  text = text.replace(/^﻿/, "");
  const lines = text.trim().split(/\r?\n/);
  const head = lines[0].split(",").map((h) => h.trim());
  return lines.slice(1).map((l) => {
    const f = l.split(",");
    return Object.fromEntries(head.map((h, i) => [h, (f[i] ?? "").trim()]));
  });
}

const ym = (d: Date) => `${d.getUTCFullYear()}${String(d.getUTCMonth() + 1).padStart(2, "0")}`;

export async function runPlay(env: Env) {
  if (!env.PLAY_BUCKET) return;
  const tok = await googleToken(env, SCOPE);
  if (!tok) return;
  const H = { authorization: `Bearer ${tok}` };
  const now = new Date();
  const prev = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - 1, 1));
  for (const app of APPS.filter((a) => a.playPackage)) {
    let ok = false;
    let err = "";
    const stmts: D1PreparedStatement[] = [];
    const ins = env.DB.prepare("INSERT OR REPLACE INTO daily (app, metric, day, value) VALUES (?, ?, ?, ?)");
    for (const month of [ym(prev), ym(now)]) {
      const obj = encodeURIComponent(`stats/installs/installs_${app.playPackage}_${month}_overview.csv`);
      const r = await fetch(`https://storage.googleapis.com/storage/v1/b/${env.PLAY_BUCKET}/o/${obj}?alt=media`, { headers: H });
      if (r.status === 404) continue;
      if (!r.ok) {
        err = `depo ${r.status}`;
        continue;
      }
      ok = true;
      for (const row of parsePlayCsv(await r.arrayBuffer())) {
        const day = row["Date"];
        if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) continue;
        const num = (k: string) => Number(row[k] ?? "") || 0;
        stmts.push(ins.bind(app.id, "android_installs", day, num("Daily User Installs") || num("Install events")));
        stmts.push(ins.bind(app.id, "android_uninstalls", day, num("Daily User Uninstalls") || num("Uninstall events")));
        if (row["Active Device Installs"]) stmts.push(ins.bind(app.id, "android_active_devices", day, num("Active Device Installs")));
      }
    }
    if (stmts.length) await env.DB.batch(stmts);

    const rv = await fetch(`https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${app.playPackage}/reviews?maxResults=50`, { headers: H });
    if (rv.ok) {
      ok = true;
      const j = (await rv.json()) as {
        reviews?: { reviewId: string; comments: { userComment?: { text: string; starRating: number; lastModified: { seconds: string }; reviewerLanguage?: string } }[] }[];
      };
      for (const x of j.reviews ?? []) {
        const c = x.comments[0]?.userComment;
        if (!c) continue;
        const ts = Number(c.lastModified.seconds);
        const res = await env.DB.prepare(
          "INSERT OR IGNORE INTO reviews (id, app, store, rating, title, body, ts, territory) VALUES (?, ?, 'android', ?, '', ?, ?, ?)",
        )
          .bind(`play:${x.reviewId}`, app.id, c.starRating, c.text.trim(), ts, (c.reviewerLanguage ?? "").slice(0, 5))
          .run();
        if ((res.meta.changes ?? 0) > 0 && c.starRating <= 2 && ts > Date.now() / 1000 - 3 * 86400)
          await raise(env, {
            app: app.id,
            metric: "reviews",
            kind: "review",
            severity: "warning",
            title: `${app.name}: Play'de ${c.starRating} yıldız yorum`,
            body: c.text.trim().slice(0, 200),
            dedupe: `review:play:${x.reviewId}`,
          });
      }
    } else if (!err) err = `yorum ${rv.status}`;
    await markSource(env, app.id, "play", ok, ok ? "" : err || "erişim bekleniyor");
  }
}
