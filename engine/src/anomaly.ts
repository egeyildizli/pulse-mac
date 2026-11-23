import { APPS } from "./apps";
import type { Env } from "./env";
import { raise } from "./alerts";
import { addDays, dayOf, now } from "./util";

export const median = (xs: number[]) => {
  if (!xs.length) return 0;
  const s = [...xs].sort((a, b) => a - b);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
};

export interface Verdict {
  kind: "spike" | "drop" | null;
  baseline: number;
  ratio: number;
}

export function judge(value: number, recent: number[], seasonal: number[], minAbs: number): Verdict {
  const base = seasonal.length >= 3 ? median(seasonal) : median(recent);
  const mad = median(recent.map((x) => Math.abs(x - median(recent))));
  const noise = Math.max(1.4826 * mad, Math.sqrt(Math.max(base, 1)));
  const z = (value - base) / noise;
  const ratio = base > 0 ? value / base : value > 0 ? Infinity : 1;
  if (value >= minAbs && ratio >= 2.5 && z >= 4) return { kind: "spike", baseline: base, ratio };
  if (base >= minAbs * 2 && ratio <= 0.25 && z <= -3) return { kind: "drop", baseline: base, ratio };
  return { kind: null, baseline: base, ratio };
}

const LABEL: Record<string, string> = {
  rt_users: "canlı kullanıcı",
  web_visitors_1h: "saatlik site ziyaretçisi",
  ios_downloads: "iOS indirme",
  users: "günlük kullanıcı",
  new_users: "yeni kullanıcı",
  web_visitors: "günlük site ziyaretçisi",
  ios_proceeds_usd: "iOS gelir",
  revenue_usd: "gelir",
  installs: "kurulum",
  subs_new: "yeni abone",
};

const LIVE: { metric: string; minAbs: number }[] = [
  { metric: "rt_users", minAbs: 15 },
  { metric: "web_visitors_1h", minAbs: 40 },
];

const DAILY: { metric: string; minAbs: number }[] = [
  { metric: "ios_downloads", minAbs: 20 },
  { metric: "users", minAbs: 30 },
  { metric: "new_users", minAbs: 20 },
  { metric: "web_visitors", minAbs: 60 },
  { metric: "ios_proceeds_usd", minAbs: 20 },
  { metric: "revenue_usd", minAbs: 20 },
  { metric: "installs", minAbs: 30 },
  { metric: "subs_new", minAbs: 5 },
];

export async function runAnomalies(env: Env) {
  const t = now();
  const bucket = Math.floor(t / 300) * 300;
  for (const app of APPS) {
    for (const { metric, minAbs } of LIVE) {
      const rows = await env.DB.prepare("SELECT ts, value FROM points WHERE app = ? AND metric = ? AND ts >= ? ORDER BY ts")
        .bind(app.id, metric, t - 8 * 86400)
        .all<{ ts: number; value: number }>();
      const pts = rows.results;
      if (pts.length < 6) continue;
      const last = pts[pts.length - 1];
      if (last.ts < bucket - 900) continue;
      const recent = pts.slice(-25, -1).map((p) => p.value);
      const seasonal = pts
        .filter((p) => {
          const lag = last.ts - p.ts;
          const dayLag = Math.round(lag / 86400);
          return dayLag >= 1 && Math.abs(lag - dayLag * 86400) <= 900;
        })
        .map((p) => p.value);
      const v = judge(last.value, recent, seasonal, minAbs);
      if (!v.kind) continue;
      const hour = Math.floor(last.ts / 3600);
      await raise(env, {
        app: app.id,
        metric,
        kind: v.kind,
        severity: v.kind === "spike" ? "warning" : "critical",
        title:
          v.kind === "spike"
            ? `${app.name}: ani patlama, ${LABEL[metric]} ${Math.round(last.value)} (normali ~${Math.round(v.baseline)})`
            : `${app.name}: sert düşüş, ${LABEL[metric]} ${Math.round(last.value)} (normali ~${Math.round(v.baseline)})`,
        body:
          v.kind === "spike"
            ? `Normalin ${v.ratio.toFixed(1)} katı. Kaynağı kontrol et: reklam, paylaşım, bot ya da mağaza öne çıkarması olabilir.`
            : `Normalin %${Math.round(v.ratio * 100)}'i. Sunucu, giriş akışı ya da takip kodu bozulmuş olabilir.`,
        dedupe: `${v.kind}:${app.id}:${metric}:${hour}`,
      });
    }
    const yday = addDays(dayOf(), -1);
    for (const { metric, minAbs } of DAILY) {
      const rows = await env.DB.prepare("SELECT day, value FROM daily WHERE app = ? AND metric = ? AND day >= ? AND day <= ? ORDER BY day")
        .bind(app.id, metric, addDays(yday, -28), yday)
        .all<{ day: string; value: number }>();
      const pts = rows.results;
      if (pts.length < 8 || pts[pts.length - 1].day !== yday) continue;
      const last = pts[pts.length - 1];
      const hist = pts.slice(0, -1);
      const sameWeekday = hist.filter((p) => (Date.parse(yday) - Date.parse(p.day)) % (7 * 86400_000) === 0).map((p) => p.value);
      const v = judge(last.value, hist.slice(-14).map((p) => p.value), sameWeekday, minAbs);
      if (!v.kind) continue;
      await raise(env, {
        app: app.id,
        metric,
        kind: v.kind,
        severity: v.kind === "spike" ? "good" : "warning",
        title: `${app.name}: dün ${LABEL[metric]} ${v.kind === "spike" ? "patladı" : "çöktü"} (${Math.round(last.value)}, normali ~${Math.round(v.baseline)})`,
        body: `Normalin ${v.ratio.toFixed(1)} katı.`,
        dedupe: `d${v.kind}:${app.id}:${metric}:${yday}`,
      });
    }
  }
}
