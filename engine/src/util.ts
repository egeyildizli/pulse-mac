export const now = () => Math.floor(Date.now() / 1000);

export const TZ = (typeof process !== "undefined" && process.env.PULSE_TZ) || Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";

export function tzOffset(ts: number = now(), tz = TZ): number {
  const p = Object.fromEntries(
    new Intl.DateTimeFormat("en-US", { timeZone: tz, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit" })
      .formatToParts(new Date(ts * 1000))
      .map((x) => [x.type, x.value]),
  );
  const asUtc = Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour, +p.minute, +p.second);
  return Math.round((asUtc - Math.floor(ts) * 1000) / 1000);
}
export function dayOf(ts: number = now(), tz = TZ): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" }).format(
    new Date(ts * 1000),
  );
}
export function addDays(day: string, n: number): string {
  const d = new Date(day + "T12:00:00Z");
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

export function localDayStart(ts: number = now()): number {
  const off = tzOffset(ts);
  return Math.floor((ts + off) / 86400) * 86400 - off;
}

const b64url = (buf: ArrayBuffer | Uint8Array) => {
  const bytes = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};
const b64urlJson = (o: unknown) => b64url(new TextEncoder().encode(JSON.stringify(o)));

function pemToDer(pem: string): ArrayBuffer {
  const body = pem.replace(/-----[^-]+-----/g, "").replace(/\\n/g, "").replace(/\s+/g, "");
  const bin = atob(body);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out.buffer;
}

export async function signJwt(
  alg: "ES256" | "RS256",
  pem: string,
  header: Record<string, unknown>,
  payload: Record<string, unknown>,
): Promise<string> {
  const algo =
    alg === "ES256"
      ? { name: "ECDSA", namedCurve: "P-256" }
      : { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" };
  const key = await crypto.subtle.importKey("pkcs8", pemToDer(pem), algo, false, ["sign"]);
  const input = `${b64urlJson({ alg, typ: "JWT", ...header })}.${b64urlJson(payload)}`;
  const sig = await crypto.subtle.sign(
    alg === "ES256" ? { name: "ECDSA", hash: "SHA-256" } : { name: "RSASSA-PKCS1-v1_5" },
    key,
    new TextEncoder().encode(input),
  );
  return `${input}.${b64url(sig)}`;
}

export async function putPoint(db: D1Database, app: string, metric: string, value: number, ts = now()) {
  const bucket = Math.floor(ts / 300) * 300;
  await db
    .prepare("INSERT OR REPLACE INTO points (app, metric, ts, value) VALUES (?, ?, ?, ?)")
    .bind(app, metric, bucket, value)
    .run();
}

export async function putDaily(db: D1Database, app: string, metric: string, day: string, value: number) {
  await db
    .prepare("INSERT OR REPLACE INTO daily (app, metric, day, value) VALUES (?, ?, ?, ?)")
    .bind(app, metric, day, value)
    .run();
}

export async function kvGet<T>(db: D1Database, k: string): Promise<T | null> {
  const r = await db.prepare("SELECT v FROM kv WHERE k = ?").bind(k).first<{ v: string }>();
  return r ? (JSON.parse(r.v) as T) : null;
}
export async function kvSet(db: D1Database, k: string, v: unknown) {
  await db.prepare("INSERT OR REPLACE INTO kv (k, v, ts) VALUES (?, ?, ?)").bind(k, JSON.stringify(v), now()).run();
}

export function parseJson<T>(s: string | undefined): T | null {
  if (!s) return null;
  try {
    return JSON.parse(s) as T;
  } catch {
    return null;
  }
}

export async function fxToUsd(db: D1Database): Promise<Record<string, number>> {
  const day = dayOf();
  const cached = await kvGet<{ day: string; rates: Record<string, number> }>(db, "fx");
  if (cached && cached.day === day) return cached.rates;
  try {
    const r = await fetch("https://open.er-api.com/v6/latest/USD");
    const j = (await r.json()) as { rates?: Record<string, number> };
    if (j.rates) {
      await kvSet(db, "fx", { day, rates: j.rates });
      return j.rates;
    }
  } catch {}
  return cached?.rates ?? { USD: 1 };
}
export const toUsd = (amount: number, cur: string, rates: Record<string, number>) => {
  const r = rates[cur.toUpperCase()];
  return r ? amount / r : 0;
};
