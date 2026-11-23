import { appById } from "../apps";
import type { Env } from "../env";
import { raise } from "../alerts";
import { markSource } from "../sources";

interface RcEvent {
  id: string;
  type: string;
  product_id?: string;
  period_type?: string;
  price?: number;
  store?: string;
  country_code?: string;
  event_timestamp_ms?: number;
  is_trial_conversion?: boolean;
  environment?: string;
  cancel_reason?: string;
  takehome_percentage?: number;
  tax_percentage?: number;
}

const FLAG = (cc?: string) =>
  cc && cc.length === 2 ? cc.toUpperCase().replace(/./g, (c) => String.fromCodePoint(127397 + c.charCodeAt(0))) : "";
const STORE: Record<string, string> = { APP_STORE: "iOS", PLAY_STORE: "Android", STRIPE: "Web", RC_BILLING: "Web" };

export async function handleRcWebhook(env: Env, appId: string, body: { event?: RcEvent }) {
  const app = appById(appId);
  const e = body.event;
  if (!app || !e?.id || !e.type) return { ok: false, reason: "bilinmeyen ürün ya da olay" };
  await markSource(env, app.id, "revenuecat_live", true);
  if (e.environment === "SANDBOX") return { ok: true, sandbox: true };
  if (e.type === "TEST") return { ok: true, test: true };
  const ts = Math.floor((e.event_timestamp_ms ?? Date.now()) / 1000);
  const ins = await env.DB.prepare(
    "INSERT OR IGNORE INTO rc_events (id, app, type, period_type, product, price_usd, store, country, ts, trial_conversion, env, takehome, tax) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'WEBHOOK', ?, ?)",
  )
    .bind(e.id, app.id, e.type, e.period_type ?? "", e.product_id ?? "", e.price ?? 0, e.store ?? "", e.country_code ?? "", ts, e.is_trial_conversion ? 1 : 0, e.takehome_percentage ?? null, e.tax_percentage ?? null)
    .run();
  if ((ins.meta.changes ?? 0) === 0) return { ok: true, duplicate: true };

  const where = [FLAG(e.country_code), STORE[e.store ?? ""] ?? e.store].filter(Boolean).join(" ");
  const price = e.price ? `$${e.price.toFixed(2)}` : "";
  const product = (e.product_id ?? "").split(/[.:]/).pop() ?? "";
  const A: Record<string, { kind: string; severity: "good" | "warning" | "info"; title: string } | undefined> = {
    INITIAL_PURCHASE: e.period_type === "TRIAL"
      ? { kind: "trial", severity: "good", title: `${app.name}: yeni deneme başladı ${where}` }
      : { kind: "sub", severity: "good", title: `${app.name}: yeni abone ${price} ${where}` },
    RENEWAL: e.is_trial_conversion
      ? { kind: "sub", severity: "good", title: `${app.name}: deneme aboneliğe döndü ${price} ${where}` }
      : { kind: "renewal", severity: "good", title: `${app.name}: abonelik yenilendi ${price} ${where}` },
    NON_RENEWING_PURCHASE: { kind: "sale", severity: "good", title: `${app.name}: satın alma ${price} ${where}` },
    CANCELLATION: { kind: "cancel", severity: "warning", title: `${app.name}: bir abonelik iptal edildi ${where}` },
    BILLING_ISSUE: { kind: "billing", severity: "warning", title: `${app.name}: ödeme sorunu, tahsilat başarısız ${where}` },
    PRODUCT_CHANGE: { kind: "change", severity: "info", title: `${app.name}: bir kullanıcı paket değiştirdi ${where}` },
  };
  const alert = A[e.type];
  if (alert)
    await raise(env, {
      app: app.id,
      metric: "rc_live",
      kind: alert.kind,
      severity: alert.severity,
      title: alert.title.replace(/\s+/g, " ").trim(),
      body: [product && `Ürün: ${product}`, e.cancel_reason && `Neden: ${e.cancel_reason}`].filter(Boolean).join(" · "),
      dedupe: `rc:${e.id}`,
    });
  return { ok: true };
}
