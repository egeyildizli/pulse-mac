import { APPS } from "../apps";
import type { Env } from "../env";
import { raise } from "../alerts";
import { now } from "../util";

export async function runHealth(env: Env) {
  const targets = APPS.flatMap((a) => (a.health ?? []).map((h) => ({ app: a, ...h })));
  await Promise.all(
    targets.map(async (t) => {
      const key = `${t.app.id}:${t.name}`;
      const start = Date.now();
      let code = 0;
      try {
        const r = await fetch(t.url, {
          method: "GET",
          redirect: "manual",
          signal: AbortSignal.timeout(10_000),
          headers: { "user-agent": "Pulse/1.0 health" },
        });
        code = r.status;
        await r.body?.cancel();
      } catch {
        code = 0;
      }
      const ms = Date.now() - start;
      const ok = code > 0 && code < 500;
      const prev = await env.DB.prepare("SELECT ok, fails, since FROM health WHERE target = ?")
        .bind(key)
        .first<{ ok: number; fails: number; since: number }>();
      const fails = ok ? 0 : (prev?.fails ?? 0) + 1;
      const wasOk = prev ? prev.ok === 1 : true;
      const isDown = fails >= 2;
      const state = isDown ? 0 : ok ? 1 : wasOk ? 1 : 0;
      const since = prev && prev.ok === state ? prev.since : now();
      await env.DB.prepare(
        "INSERT OR REPLACE INTO health (target, app, url, ok, code, ms, ts, since, fails) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
      )
        .bind(key, t.app.id, t.url, state, code, ms, now(), since, fails)
        .run();
      if (wasOk && state === 0) {
        await raise(env, {
          app: t.app.id,
          metric: "health",
          kind: "down",
          severity: "critical",
          title: `${t.app.name} ${t.name} çalışmıyor`,
          body: `${t.url} yanıt vermiyor (kod ${code || "yok"}).`,
          dedupe: `down:${key}:${since}`,
        });
      } else if (!wasOk && state === 1 && prev) {
        const mins = Math.round((now() - prev.since) / 60);
        await raise(env, {
          app: t.app.id,
          metric: "health",
          kind: "up",
          severity: "good",
          title: `${t.app.name} ${t.name} yeniden açık`,
          body: `${mins} dakika kapalı kaldı.`,
          dedupe: `up:${key}:${since}`,
        });
      }
    }),
  );
}
