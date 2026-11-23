import { APPS, type AppDef } from "./apps";
import type { Env } from "./env";
import { kvSet, now, parseJson } from "./util";

export interface SourceState {
  ok: boolean;
  ts: number;
  err?: string;
}

export async function markSource(env: Env, app: string, source: string, ok: boolean, err = "") {
  await kvSet(env.DB, `src:${app}:${source}`, { ok, ts: now(), err: err || undefined } satisfies SourceState);
}

export const SOURCE_LABEL: Record<string, string> = {
  revenuecat: "RevenueCat",
  revenuecat_charts: "RevenueCat",
  stripe: "Stripe",
  asc_sales: "App Store satış",
  asc_reviews: "App Store yorum",
  ga4: "Google Analytics",
  cloudflare: "Cloudflare",
  health: "Sağlık nöbeti",
  admob: "AdMob",
  play: "Google Play",
  play_sales: "Google Play gelir",
  meta_ads: "Meta Reklam",
  ios_acq: "App Store indirme kaynakları",
  android_acq: "Play edinme kaynakları",
};

export function expectedSources(env: Env, a: AppDef): { source: string; configured: boolean }[] {
  const rc = parseJson<Record<string, unknown>>(env.RC_KEYS) ?? {};
  const st = parseJson<Record<string, unknown>>(env.STRIPE_KEYS) ?? {};
  const out: { source: string; configured: boolean }[] = [];
  if (a.rcProject) out.push({ source: "revenuecat_charts", configured: !!rc[a.rcProject] });
  if (a.stripe) out.push({ source: "stripe", configured: !!st[a.stripe] });
  if (a.ascId) out.push({ source: "asc_reviews", configured: !!env.ASC_P8 });
  if (a.ascId) out.push({ source: "asc_sales", configured: !!env.ASC_P8 && !!env.ASC_VENDOR });
  if (a.playPackage) out.push({ source: "play", configured: !!env.GA4_SA });
  if (a.playPackage) out.push({ source: "play_sales", configured: !!env.GA4_SA && !!env.PLAY_BUCKET });
  if (a.ga4Property) out.push({ source: "ga4", configured: !!env.GA4_SA });
  if (a.cfZone) out.push({ source: "cloudflare", configured: !!env.CF_API_TOKEN });

  return out;
}

export async function sourceStatus(env: Env) {
  const rows = await env.DB.prepare("SELECT k, v FROM kv WHERE k LIKE 'src:%'").all<{ k: string; v: string }>();
  const state: Record<string, SourceState> = {};
  for (const r of rows.results) state[r.k.slice(4)] = JSON.parse(r.v);
  const res: Record<string, { source: string; label: string; status: "ok" | "error" | "missing" | "waiting"; ts?: number; err?: string }[]> = {};
  for (const a of APPS) {
    res[a.id] = expectedSources(env, a).map(({ source, configured }) => {
      const s = state[`${a.id}:${source}`];
      const status = !configured ? "missing" : !s ? "waiting" : s.ok ? "ok" : "error";
      return { source, label: SOURCE_LABEL[source] ?? source, status, ts: s?.ts, err: s?.err };
    });
  }
  return res;
}
