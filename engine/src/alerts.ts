import type { Env } from "./env";
import { now } from "./util";

export type Severity = "critical" | "warning" | "good" | "info";

export interface NewAlert {
  app: string;
  metric: string;
  kind: string;
  severity: Severity;
  title: string;
  body: string;
  dedupe: string;
}

export async function raise(env: Env, a: NewAlert): Promise<boolean> {
  const r = await env.DB.prepare(
    "INSERT OR IGNORE INTO alerts (app, metric, kind, severity, title, body, ts, dedupe) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
  )
    .bind(a.app, a.metric, a.kind, a.severity, a.title, a.body, now(), a.dedupe)
    .run();
  const isNew = (r.meta.changes ?? 0) > 0;
  if (isNew && a.severity !== "info") await telegram(env, `${icon(a.severity)} ${a.title}\n${a.body ?? ""}`);
  return isNew;
}

const icon = (s: Severity) => ({ critical: "🔴", warning: "🟠", good: "🟢", info: "🔵" })[s];

export async function telegram(env: Env, text: string) {
  if (!env.TELEGRAM_BOT_TOKEN || !env.TELEGRAM_CHAT_ID) return;
  try {
    await fetch(`https://api.telegram.org/bot${encodeURIComponent(env.TELEGRAM_BOT_TOKEN)}/sendMessage`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ chat_id: env.TELEGRAM_CHAT_ID, text, disable_web_page_preview: true }),
    });
  } catch {}
}
