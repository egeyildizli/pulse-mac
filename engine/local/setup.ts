import { APPS, type AppDef } from "../src/apps";
import type { Env } from "../src/env";
import { addDays, dayOf, kvGet, now, parseJson, signJwt } from "../src/util";
import type { Secrets } from "./main";
import { aiCheck, aiConfig, AI_DEFAULT_MODEL, type AiProvider } from "../src/ai";

export type SetupCtx = {
  env: Env & Record<string, unknown>;
  applySecrets: (s: Secrets) => void;
  saveApps: (l: AppDef[]) => Promise<void>;
  fullSync: () => Promise<void>;
  isSyncing: () => boolean;
  webhookPort: number;
  webhookUp: () => boolean;
};

const ASC = "https://api.appstoreconnect.apple.com";
type SA = { client_email: string; private_key: string; project_id?: string };
const fail = (error: string, extra: Record<string, unknown> = {}) => Response.json({ ok: false, error, ...extra });

async function ascTokenFor(keyId: string, issuer: string, p8: string) {
  const t = now();
  return signJwt("ES256", p8, { kid: keyId }, { iss: issuer, iat: t, exp: t + 900, aud: "appstoreconnect-v1" });
}

type AscApp = { ascId: string; name: string; bundleId: string; sku: string; icon?: string };
async function ascApps(tok: string): Promise<{ apps?: AscApp[]; status: number; msg?: string }> {
  const r = await fetch(`${ASC}/v1/apps?limit=200&fields[apps]=name,bundleId,sku`, { headers: { authorization: `Bearer ${tok}` } });
  if (!r.ok) return { status: r.status, msg: (await r.text()).slice(0, 300) };
  const j = (await r.json()) as { data: { id: string; attributes: { name: string; bundleId: string; sku: string } }[] };
  const apps = j.data.map((a) => ({ ascId: a.id, name: a.attributes.name, bundleId: a.attributes.bundleId, sku: a.attributes.sku }) as AscApp);

  if (apps.length) {
    try {
      const lr = await fetch(`https://itunes.apple.com/lookup?id=${apps.map((a) => a.ascId).join(",")}`);
      const lj = (await lr.json()) as { results: { trackId: number; artworkUrl512?: string; artworkUrl100?: string }[] };
      for (const x of lj.results) {
        const a = apps.find((y) => y.ascId === String(x.trackId));
        if (a) a.icon = x.artworkUrl512 ?? x.artworkUrl100;
      }
    } catch {}
  }
  return { apps, status: 200 };
}

async function googleTokenFor(sa: SA, scope: string): Promise<{ tok?: string; error?: string }> {
  const t = now();
  let assertion: string;
  try {
    assertion = await signJwt("RS256", sa.private_key, {}, { iss: sa.client_email, scope, aud: "https://oauth2.googleapis.com/token", iat: t, exp: t + 3600 });
  } catch {
    return { error: "Anahtar dosyasındaki özel anahtar okunamadı. Google Cloud'dan indirdiğin JSON dosyasını olduğu gibi kullan." };
  }
  const r = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: `grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=${assertion}`,
  });
  const j = (await r.json()) as { access_token?: string; error_description?: string };
  if (!j.access_token) return { error: `Google anahtarı kabul etmedi: ${j.error_description ?? r.status}. Anahtar silinmiş ya da servis hesabı kapatılmış olabilir.` };
  return { tok: j.access_token };
}

export function bucketFrom(input: string): string | null {
  const s = input.trim();
  const b = s.match(/pubsite_prod_(rev_)?[0-9a-z_]+/i);
  if (b) return b[0];
  const dev = s.match(/developers\/(\d{6,})/) ?? s.match(/^(\d{6,})$/);
  return dev ? `pubsite_prod_${dev[1]}` : null;
}

type PlayApp = { playPackage: string; name: string };
async function playApps(tok: string, bucket: string): Promise<{ apps?: PlayApp[]; error?: string; code?: string }> {
  const H = { authorization: `Bearer ${tok}` };
  const r = await fetch(`https://storage.googleapis.com/storage/v1/b/${bucket}/o?prefix=${encodeURIComponent("stats/installs/")}&maxResults=1000&fields=items(name)`, { headers: H });
  if (r.status === 403 || r.status === 401)
    return {
      code: "no_access",
      error: "Servis hesabı rapor deposunu henüz göremiyor. Play Console'da kullanıcı olarak davet ettiğinden emin ol. Davet yeniyse Google'ın izni işlemesi 24 saate kadar sürebilir; panel kendisi tekrar dener.",
    };
  if (r.status === 404) return { code: "no_bucket", error: "Bu rapor deposu bulunamadı. Play Console adresini tarayıcının adres çubuğundan olduğu gibi kopyala." };
  if (!r.ok) return { code: "other", error: `Google depo hatası (${r.status}).` };
  const j = (await r.json()) as { items?: { name: string }[] };
  const pkgs = new Set<string>();
  for (const it of j.items ?? []) {
    const m = it.name.match(/^stats\/installs\/installs_(.+)_\d{6}_overview\.csv$/);
    if (m) pkgs.add(m[1]);
  }
  const names = new Map<string, string>();

  try {
    const s = await fetch("https://playdeveloperreporting.googleapis.com/v1beta1/apps:search?pageSize=200", { headers: H });
    if (s.ok) {
      const sj = (await s.json()) as { apps?: { packageName: string; displayName?: string }[] };
      for (const a of sj.apps ?? []) {
        pkgs.add(a.packageName);
        if (a.displayName) names.set(a.packageName, a.displayName);
      }
    }
  } catch {}
  return { apps: [...pkgs].sort().map((p) => ({ playPackage: p, name: names.get(p) ?? p })) };
}

type RcProj = { project: string; name: string; bundles: string[] };
async function rcProjects(key: string): Promise<{ projects?: RcProj[]; error?: string }> {
  const H = { authorization: `Bearer ${key}` };
  const r = await fetch("https://api.revenuecat.com/v2/projects?limit=50", { headers: H });
  if (r.status === 401 || r.status === 403) return { error: "RevenueCat anahtarı reddetti. Proje ayarlarındaki API Keys bölümünden v2 'Secret' anahtar oluştur (sk_ ile başlar)." };
  if (!r.ok) return { error: `RevenueCat hatası (${r.status}).` };
  const j = (await r.json()) as { items?: { id: string; name: string }[] };
  const out: RcProj[] = [];
  for (const p of j.items ?? []) {
    const bundles: string[] = [];
    try {
      const a = await fetch(`https://api.revenuecat.com/v2/projects/${p.id}/apps?limit=50`, { headers: H });
      if (a.ok) {
        const aj = (await a.json()) as { items?: Record<string, any>[] };
        for (const x of aj.items ?? []) {
          const b = x.app_store?.bundle_id ?? x.mac_app_store?.bundle_id ?? x.play_store?.package_name;
          if (b) bundles.push(b);
        }
      }
    } catch {}
    out.push({ project: p.id, name: p.name, bundles });
  }
  return { projects: out };
}

const slug = (s: string, taken: Set<string>) => {
  const base =
    s
      .toLowerCase()
      .replace(/ı/g, "i").replace(/ş/g, "s").replace(/ğ/g, "g").replace(/ü/g, "u").replace(/ö/g, "o").replace(/ç/g, "c")
      .normalize("NFKD")
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "")
      .slice(0, 30) || "app";
  let id = base;
  for (let i = 2; taken.has(id); i++) id = `${base}-${i}`;
  taken.add(id);
  return id;
};
const PALETTE = ["#4F8CFF", "#FF9F43", "#2ED3A0", "#B07CFF", "#FF5E7E", "#34C7F0", "#F5C542", "#7BD389"];

export function setupRoutes(ctx: SetupCtx) {
  const { env } = ctx;
  return async (req: Request, url: URL): Promise<Response> => {
    const body = req.method === "POST" ? ((await req.json().catch(() => ({}))) as Record<string, any>) : {};
    const p = url.pathname.replace("/v1/local/", "");

    if (p === "state") {
      const rc = parseJson<Record<string, unknown>>(env.RC_KEYS as string) ?? {};
      const st = parseJson<Record<string, unknown>>(env.STRIPE_KEYS as string) ?? {};
      const sa = parseJson<SA>(env.GA4_SA as string);
      return Response.json({
        apps: APPS,
        connected: {
          apple: !!env.ASC_KEY_ID,
          appleVendor: !!env.ASC_VENDOR,
          play: !!sa && !!env.PLAY_BUCKET,
          playEmail: sa?.client_email ?? null,
          revenuecat: Object.keys(rc),
          stripe: Object.keys(st),
          cloudflare: !!env.CF_API_TOKEN,
          meta: !!env.META_TOKEN,
          ga4: APPS.some((a) => a.ga4Property),
          anthropic: !!env.ANTHROPIC_API_KEY,
          ai: aiConfig(env) ? { provider: aiConfig(env)!.provider, model: aiConfig(env)!.model } : null,
          telegram: !!env.TELEGRAM_CHAT_ID,
          webhook: env.WEBHOOK_SECRET ? { url: env.WEBHOOK_URL ?? null, listening: ctx.webhookUp(), port: ctx.webhookPort } : null,
        },
        syncing: ctx.isSyncing(),
        lastSync: (await kvGet<{ ts: number }>(env.DB, "local:sync"))?.ts ?? null,
      });
    }

    if (p === "secrets" && req.method === "POST") {
      ctx.applySecrets(body.secrets ?? {});
      return Response.json({ ok: true });
    }

    if (p === "apple/check" && req.method === "POST") {
      const { keyId, issuerId, p8, vendor } = body as { keyId?: string; issuerId?: string; p8?: string; vendor?: string };
      if (!keyId || !issuerId || !p8) return fail("Anahtar dosyası, Key ID ve Issuer ID üçü de gerekli.");
      if (!p8.includes("PRIVATE KEY")) return fail("Bu bir .p8 anahtar dosyası gibi görünmüyor. App Store Connect'ten indirdiğin AuthKey_XXXX.p8 dosyasını kullan.");
      let tok: string;
      try {
        tok = await ascTokenFor(keyId.trim(), issuerId.trim(), p8);
      } catch {
        return fail("Anahtar dosyası okunamadı. Dosyanın bozulmadığından emin ol.");
      }
      const res = await ascApps(tok);
      if (res.status === 401) return fail("Apple anahtarı reddetti. Key ID ve Issuer ID'nin bu dosyaya ait olduğundan emin ol (Issuer ID sayfanın üstünde yazar).");
      if (res.status === 403) return fail("Anahtarın uygulama listesini okuma yetkisi yok. Finance, Sales ya da Admin rolüyle yeni anahtar oluştur.");
      if (!res.apps) return fail(`Apple hatası (${res.status}).`);
      let vendorOk: boolean | null = null;
      if (vendor?.trim()) {
        const d = addDays(dayOf(now(), "America/Los_Angeles"), -3);
        const r = await fetch(
          `${ASC}/v1/salesReports?filter[frequency]=DAILY&filter[reportType]=SALES&filter[reportSubType]=SUMMARY&filter[vendorNumber]=${encodeURIComponent(vendor.trim())}&filter[reportDate]=${d}&filter[version]=1_1`,
          { headers: { authorization: `Bearer ${tok}`, accept: "application/a-gzip" } },
        );
        vendorOk = r.ok || r.status === 404;
      }
      ctx.applySecrets({ ASC_KEY_ID: keyId.trim(), ASC_ISSUER_ID: issuerId.trim(), ASC_P8: p8, ASC_VENDOR: vendorOk ? vendor!.trim() : undefined });
      return Response.json({ ok: true, apps: res.apps, vendorOk });
    }

    if (p === "play/check" && req.method === "POST") {
      const sa = parseJson<SA>(typeof body.sa === "string" ? body.sa : JSON.stringify(body.sa ?? null));
      if (!sa?.client_email || !sa.private_key) return fail("Bu bir servis hesabı anahtar dosyası değil. Google Cloud'da servis hesabının 'Anahtarlar' sekmesinden JSON anahtar indir.");
      const bucket = body.console ? bucketFrom(String(body.console)) : null;
      const g = await googleTokenFor(
        sa,
        "https://www.googleapis.com/auth/devstorage.read_only https://www.googleapis.com/auth/androidpublisher https://www.googleapis.com/auth/playdeveloperreporting",
      );
      if (!g.tok) return fail(g.error!, { email: sa.client_email });
      if (!bucket) return Response.json({ ok: false, step: "console", email: sa.client_email, error: "Anahtar çalışıyor. Şimdi Play Console adresini yapıştır." });
      const res = await playApps(g.tok, bucket);
      if (!res.apps) {
        if (res.code === "no_access") ctx.applySecrets({ GOOGLE_SA: JSON.stringify(sa), PLAY_BUCKET: bucket });
        return Response.json({ ok: false, step: res.code === "no_access" ? "invite" : "console", pending: res.code === "no_access", bucket, email: sa.client_email, error: res.error });
      }
      ctx.applySecrets({ GOOGLE_SA: JSON.stringify(sa), PLAY_BUCKET: bucket });
      return Response.json({ ok: true, email: sa.client_email, bucket, apps: res.apps });
    }

    if (p === "revenuecat/check" && req.method === "POST") {
      const key = String(body.key ?? "").trim();
      if (!key.startsWith("sk_")) return fail("RevenueCat'te v2 'Secret' anahtar gerekli (sk_ ile başlar). Public anahtar (appl_/goog_) çalışmaz.");
      const res = await rcProjects(key);
      return res.projects ? Response.json({ ok: true, projects: res.projects }) : fail(res.error!);
    }

    if (p === "stripe/check" && req.method === "POST") {
      const key = String(body.key ?? "").trim();
      if (!/^(rk|sk)_live_/.test(key)) return fail("Canlı bir Stripe anahtarı gerekli (rk_live_ ile başlayan kısıtlı anahtar önerilir).");
      const r = await fetch("https://api.stripe.com/v1/balance", { headers: { authorization: `Bearer ${key}` } });
      if (!r.ok) return fail("Stripe anahtarı reddetti ya da 'Balance: Read' izni yok. Kısıtlı anahtarda Balance ve Charges için Read ver.");
      return Response.json({ ok: true });
    }

    if (p === "cloudflare/check" && req.method === "POST") {
      const tokn = String(body.token ?? "").trim();
      const H = { authorization: `Bearer ${tokn}` };
      const v = await fetch("https://api.cloudflare.com/client/v4/user/tokens/verify", { headers: H });
      if (!v.ok) return fail("Cloudflare anahtarı reddetti.");
      const z = await fetch("https://api.cloudflare.com/client/v4/zones?per_page=50", { headers: H });
      const zj = (await z.json()) as { result?: { name: string; account?: { id: string } }[] };
      const zones = (zj.result ?? []).map((x) => x.name);
      if (!zones.length) return fail("Anahtar çalışıyor ama hiçbir siteyi göremiyor. Anahtara 'Zone: Analytics: Read' ve 'Zone: Zone: Read' izni ver.");
      const accountId = zj.result?.[0]?.account?.id;
      ctx.applySecrets({ CF_API_TOKEN: tokn, CF_ACCOUNT_ID: accountId });
      return Response.json({ ok: true, zones, accountId });
    }

    if (p === "meta/check" && req.method === "POST") {
      const tokn = String(body.token ?? "").trim();
      const r = await fetch("https://graph.facebook.com/v21.0/me/adaccounts?fields=name,account_id,account_status,currency&limit=100", { headers: { authorization: `Bearer ${tokn}` } });
      const j = (await r.json()) as { data?: { id: string; name: string; account_status: number; currency: string }[]; error?: { message: string } };
      if (!r.ok || !j.data) return fail(`Meta token'ı reddetti: ${j.error?.message ?? r.status}. Token'a ads_read izni ver.`);
      if (!j.data.length) return fail("Token çalışıyor ama hiçbir reklam hesabını göremiyor. Sistem kullanıcısına reklam hesabını ata.");
      ctx.applySecrets({ META_TOKEN: tokn });
      return Response.json({ ok: true, accounts: j.data.map((a) => ({ id: a.id, name: a.name, active: a.account_status === 1, currency: a.currency })) });
    }

    if (p === "ga4/check" && req.method === "POST") {
      const sa = parseJson<SA>((typeof body.sa === "string" && body.sa) || (env.GA4_SA as string));
      if (!sa?.client_email) return fail("Önce bir Google servis hesabı anahtarı gerekli (Google Play adımındaki dosya da olur).");
      const g = await googleTokenFor(sa, "https://www.googleapis.com/auth/analytics.readonly");
      if (!g.tok) return fail(g.error!, { email: sa.client_email });
      const r = await fetch("https://analyticsadmin.googleapis.com/v1beta/accountSummaries?pageSize=200", { headers: { authorization: `Bearer ${g.tok}` } });
      const j = (await r.json()) as { accountSummaries?: { displayName: string; propertySummaries?: { property: string; displayName: string }[] }[]; error?: { message: string } };
      if (r.status === 403 && /not been used|disabled/i.test(j.error?.message ?? ""))
        return fail("Google Cloud projende 'Google Analytics Admin API' ve 'Google Analytics Data API' açık değil. İkisini de etkinleştir.", { email: sa.client_email });
      if (!r.ok) return fail(`Google Analytics hatası: ${j.error?.message ?? r.status}`, { email: sa.client_email });
      const props = (j.accountSummaries ?? []).flatMap((a) => (a.propertySummaries ?? []).map((pp) => ({ id: pp.property.replace("properties/", ""), name: pp.displayName, account: a.displayName })));
      if (!props.length) return fail("Servis hesabı hiçbir Analytics mülkünü göremiyor. Analytics'te Yönetici > Mülk erişimi'nden bu e-postayı Görüntüleyici olarak ekle.", { email: sa.client_email });
      if (typeof body.sa === "string" && body.sa) ctx.applySecrets({ GOOGLE_SA: JSON.stringify(sa) });
      return Response.json({ ok: true, email: sa.client_email, properties: props });
    }

    if (p === "ai/check" && req.method === "POST") {
      const provider = String(body.provider ?? "anthropic") as AiProvider;
      if (!(provider in AI_DEFAULT_MODEL)) return fail("Bilinmeyen sağlayıcı.");
      const cfg = { provider, key: String(body.key ?? "").trim(), model: String(body.model ?? "").trim() || AI_DEFAULT_MODEL[provider], url: (String(body.url ?? "").trim() || "http://127.0.0.1:11434").replace(/\/$/, "") };
      if (provider !== "ollama" && !cfg.key) return fail("API anahtarı gerekli.");
      const err = await aiCheck(cfg);
      if (err) return fail(err);
      ctx.applySecrets({ AI_PROVIDER: provider, AI_KEY: cfg.key || undefined, AI_MODEL: cfg.model, AI_URL: provider === "ollama" ? cfg.url : undefined, ANTHROPIC_API_KEY: undefined });
      return Response.json({ ok: true, provider, model: cfg.model });
    }
    if (p === "ai/remove" && req.method === "POST") {
      ctx.applySecrets({ AI_PROVIDER: undefined, AI_KEY: undefined, AI_MODEL: undefined, AI_URL: undefined, ANTHROPIC_API_KEY: undefined });
      return Response.json({ ok: true });
    }

    if (p === "telegram/check" && req.method === "POST") {
      const tokn = String(body.token ?? "").trim();
      const me = await fetch(`https://api.telegram.org/bot${encodeURIComponent(tokn)}/getMe`).then((r) => r.json()).catch(() => null) as { ok?: boolean; result?: { username: string } } | null;
      if (!me?.ok) return fail("Telegram bot anahtarı geçersiz. BotFather'ın verdiği anahtarı olduğu gibi yapıştır.");
      const up = (await fetch(`https://api.telegram.org/bot${encodeURIComponent(tokn)}/getUpdates?limit=20`).then((r) => r.json()).catch(() => null)) as { result?: { message?: { chat: { id: number } } }[] } | null;
      const chat = [...(up?.result ?? [])].reverse().find((u) => u.message?.chat?.id)?.message?.chat.id;
      if (!chat) return fail(`Bot bulundu (@${me.result?.username}). Şimdi Telegram'da bu bota herhangi bir mesaj yaz, sonra tekrar Bağla'ya bas.`, { bot: me.result?.username });
      await fetch(`https://api.telegram.org/bot${encodeURIComponent(tokn)}/sendMessage`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ chat_id: chat, text: "Pulse bağlandı. Önemli uyarılar buraya gelecek." }) });
      ctx.applySecrets({ TELEGRAM_BOT_TOKEN: tokn, TELEGRAM_CHAT_ID: String(chat) });
      return Response.json({ ok: true, bot: me.result?.username, chat: String(chat) });
    }

    if (p === "webhook/enable" && req.method === "POST") {
      const secret = (env.WEBHOOK_SECRET as string | undefined) ?? [...crypto.getRandomValues(new Uint8Array(24))].map((b) => b.toString(16).padStart(2, "0")).join("");
      const pub = String(body.url ?? "").trim().replace(/\/$/, "") || undefined;

      if (pub && !/^https:\/\/[^\s/]+$/.test(pub) && !/^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?$/.test(pub)) return fail("Adres https:// ile başlayan tünel adresi olmalı.");
      ctx.applySecrets({ WEBHOOK_SECRET: secret, WEBHOOK_URL: pub });
      return Response.json({ ok: true, secret, port: ctx.webhookPort, listening: ctx.webhookUp(), url: pub ?? null });
    }
    if (p === "webhook/test" && req.method === "POST") {
      const pub = (env.WEBHOOK_URL as string | undefined) ?? "";
      if (!pub) return fail("Önce dış adresini (tünel adresi) gir.");
      const r = await fetch(`${pub}/ping`).then((x) => x.json()).catch(() => null) as { pulse?: boolean } | null;
      return r?.pulse ? Response.json({ ok: true }) : fail(`${pub}/ping adresinden Pulse'a ulaşılamadı. Tünelin açık ve 127.0.0.1:${ctx.webhookPort} adresine yönlendiriyor olmalı.`);
    }
    if (p === "webhook/disable" && req.method === "POST") {
      ctx.applySecrets({ WEBHOOK_SECRET: undefined, WEBHOOK_URL: undefined });
      return Response.json({ ok: true });
    }

    if (p === "catalog") {
      type Item = { key: string; name: string; icon?: string; ascId?: string; bundleId?: string; playPackage?: string };
      const items: Item[] = [];
      if (env.ASC_KEY_ID && env.ASC_ISSUER_ID && env.ASC_P8) {
        const res = await ascApps(await ascTokenFor(env.ASC_KEY_ID as string, env.ASC_ISSUER_ID as string, env.ASC_P8 as string));
        for (const a of res.apps ?? []) items.push({ key: a.bundleId, name: a.name, icon: a.icon, ascId: a.ascId, bundleId: a.bundleId });
      }
      const sa = parseJson<SA>(env.GA4_SA as string);
      if (sa && env.PLAY_BUCKET) {
        const g = await googleTokenFor(sa, "https://www.googleapis.com/auth/devstorage.read_only https://www.googleapis.com/auth/playdeveloperreporting");
        const res = g.tok ? await playApps(g.tok, env.PLAY_BUCKET as string) : {};
        for (const a of res.apps ?? []) {
          const same = items.find((i) => i.bundleId === a.playPackage);
          if (same) same.playPackage = a.playPackage;
          else items.push({ key: a.playPackage, name: a.name, playPackage: a.playPackage });
        }
      }
      return Response.json({ items, selected: APPS.map((a) => a.ascId ?? a.playPackage) });
    }

    if (p === "apps" && req.method === "POST") {
      const input = (body.apps ?? []) as {
        name: string; kind?: string; ascId?: string; playPackage?: string; bundleId?: string;
        rc?: { project: string; key: string }; stripeKey?: string; site?: string; id?: string; ga4Property?: string; metaAccount?: string;
      }[];
      const taken = new Set<string>();
      const rcKeys: Record<string, { project: string; key: string }> = {};
      const stripeKeys: Record<string, string> = {};
      const list: AppDef[] = input.map((a, i) => {
        const prev = APPS.find((x) => (a.ascId && x.ascId === a.ascId) || (a.playPackage && x.playPackage === a.playPackage) || (a.id && x.id === a.id));
        const id = prev && !taken.has(prev.id) ? (taken.add(prev.id), prev.id) : slug(a.name, taken);
        if (a.rc?.key) rcKeys[id] = a.rc;
        if (a.stripeKey) stripeKeys[id] = a.stripeKey;

        const host = a.site?.trim().toLowerCase().replace(/^https?:\/\//, "").replace(/[/?#].*$/, "").replace(/^.*@/, "").replace(/:\d+$/, "");
        const site = host && /^(?=.{1,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/.test(host) ? host : undefined;
        return {
          id,
          name: a.name.slice(0, 40),
          kind: a.kind === "game" ? "game" : a.kind === "web" ? "web" : "app",
          color: prev?.color ?? PALETTE[i % PALETTE.length],
          ascId: a.ascId,
          playPackage: a.playPackage,
          rcProject: a.rc?.key ? id : undefined,
          stripe: a.stripeKey ? id : undefined,
          cfZone: site || undefined,
          ga4Property: a.ga4Property?.replace(/\D/g, "") || undefined,
          metaAccount: a.metaAccount || undefined,
          health: site ? [{ name: "Site", url: `https://${site}/` }] : undefined,
        } as AppDef;
      });
      ctx.applySecrets({
        RC_KEYS: Object.keys(rcKeys).length ? JSON.stringify(rcKeys) : undefined,
        STRIPE_KEYS: Object.keys(stripeKeys).length ? JSON.stringify(stripeKeys) : undefined,
      });
      await ctx.saveApps(list);
      void ctx.fullSync();
      return Response.json({ ok: true, apps: list, secrets: { RC_KEYS: env.RC_KEYS ?? "", STRIPE_KEYS: env.STRIPE_KEYS ?? "" } });
    }

    if (p === "sync" && req.method === "POST") {
      void ctx.fullSync();
      return Response.json({ ok: true });
    }

    return Response.json({ error: "not found" }, { status: 404 });
  };
}
