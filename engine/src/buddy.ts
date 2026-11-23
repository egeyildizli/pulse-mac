export type Mood = "critical" | "bad" | "meh" | "good" | "fire";

export interface Note {
  mood: Mood;
  headline: string;
  lines: string[];
  key: string;
}

export interface BuddyInput {
  name: string;
  segment: string;
  m: Record<string, number | null>;
  avg7: Record<string, number | null>;
  avgPrev: Record<string, number | null>;
  prev7: Record<string, number | null>;
  dayFraction: number;
  down: string[];
  lowReviews24h: number;
  prelaunch?: boolean;

  monetized?: boolean;
}

const pct = (x: number) => `%${Math.round(x * 100)}`;
const times = (x: number) => `${x.toFixed(1).replace(".", ",")} katı`;

export function buddy(i: BuddyInput): Note {
  const out: { mood: Mood; text: string; key: string; w: number }[] = [];
  const add = (mood: Mood, text: string, key: string) =>
    out.push({ mood, text, key, w: { critical: 5, bad: 4, fire: 3, good: 2, meh: 1 }[mood] });
  const m = i.m;

  if (i.down.length) add("critical", `${i.down.join(", ")} çalışmıyor, kullanıcılar şu an giremiyor. Hemen bak.`, "down");

  const pace = (today: number | null, avg: number | null, minAvg: number) => {
    if (today === null || avg === null || avg < minAvg || i.dayFraction < 0.2) return null;
    return today / (avg * i.dayFraction);
  };
  if (i.segment === "web") {
    const p = pace(m.web_visitors_today, i.avg7.web_visitors, 15);
    if (p !== null && p >= 1.8)
      add("fire", `Site bugün uçuyor 🔥 Ziyaret normalin ${times(p)} hızında. Nereden geldiğine bak, o kanalı besle.`, "pace_up");
    else if (p !== null && p <= 0.45)
      add("bad", `Siteye bugün kimse uğramıyor, normalin ${pct(p)}'i kadar ziyaret. Reklam, SEO ya da DNS bozulmuş olabilir.`, "pace_down");
  } else {
    const ratio = (y: number | null, avg: number | null, min: number) => (y === null || avg === null || avg < min ? null : y / avg);
    const p = ratio(m.installs_yday, i.avgPrev.installs, 5);
    if (p !== null && p >= 1.8)
      add("fire", `Dün uçtu 🔥 ${m.installs_yday} kurulum, normalin ${times(p)}. Nereden geldiğine bak, o kanalı besle.`, "pace_up");
    else if (p !== null && p <= 0.5)
      add("bad", `Dün kurulum çok düşüktü: ${m.installs_yday}, normalin ${pct(p)}'i. Mağaza sayfası, sıralama ya da reklam düşmüş olabilir.`, "pace_down");
    const u = ratio(m.users_yday, i.avgPrev.users, 20);
    if (u !== null && u <= 0.5)
      add("bad", `Dün aktif kullanıcı normalin ${pct(u)}'ine düştü. Giriş akışı ya da sunucu sorun çıkarıyor olabilir.`, "users_down");
  }

  const r7 = m.revenue_7d;
  const rp = i.prev7.revenue;
  if (r7 !== null && rp !== null && rp >= 50) {
    const ch = (r7 - rp) / rp;
    if (ch <= -0.4) add("bad", `Gelir geçen haftaya göre ${pct(-ch)} düştü ($${Math.round(rp)} → $${Math.round(r7)}). Paywall ya da fiyatta bir şey mi değişti?`, "rev_down");
    else if (ch >= 0.4) add("good", `Gelir geçen haftadan ${pct(ch)} yukarıda ($${Math.round(r7)}). Ne değiştiyse aynen devam.`, "rev_up");
  }

  if ((m.paywall_views_7d ?? 0) >= 50 && m.paywall_conv_7d !== null && m.paywall_conv_7d < 2)
    add("bad", `Paywall'u bu hafta ${m.paywall_views_7d} kişi gördü, sadece ${m.paywall_conv_7d}% aldı. Fiyatı ya da ilk ekranı A/B test et.`, "paywall");

  if (!i.prelaunch && i.monetized !== false && (m.installs_7d ?? 0) >= 30 && (m.revenue_7d ?? 0) === 0 && i.segment !== "web")
    add("bad", `Haftada ${m.installs_7d} kurulum var ama tek kuruş yok. Paywall akışına ya da fiyat sayfasına bak.`, "no_money");

  if (!i.prelaunch && m.installs_7d !== null && m.installs_7d <= 3 && i.segment !== "web")
    add("meh", m.installs_7d === 0 ? "Bu hafta hiç kurulum yok. Uygulama mağazada görünmüyor, ASO ve tanıtım lazım." : `Bu hafta yalnız ${m.installs_7d} kurulum. Uygulama mağazada görünmüyor, ASO ve tanıtım lazım.`, "invisible");

  const subs = m.active_subs ?? 0;
  if ((m.churned_7d ?? 0) >= Math.max(3, subs * 0.1))
    add("bad", `Bu hafta ${m.churned_7d} kişi aboneliği bıraktı. İptal nedenlerine ve son sürüme bak.`, "churn");

  if ((m.trials ?? 0) >= 15 && (m.subs_new_7d ?? 0) === 0)
    add("meh", `${m.trials} kişi denemede ama bu hafta yeni abone yok. Deneme bitişi hatırlatmasını kontrol et.`, "trial_stuck");

  const v7 = i.avg7.web_visitors !== null ? i.avg7.web_visitors * 7 : null;
  if (i.segment === "web" && v7 !== null && v7 >= 100 && (m.revenue_7d ?? null) === 0)
    add("bad", `Haftada ~${Math.round(v7)} ziyaret var ama satış yok. Fiyat sayfasını ve ödeme akışını kendin bir dene.`, "web_no_sale");
  if ((m.threats_today ?? 0) > Math.max(20, m.web_visitors_today ?? 0))
    add("meh", `Bugün ${m.threats_today} kötü niyetli istek engellendi, gerçek ziyaretçiden fazla. WAF kurallarına bir göz at.`, "threats");

  if (i.lowReviews24h >= 2) add("bad", `Son 24 saatte ${i.lowReviews24h} tane 1-2 yıldız geldi. Yorumları oku, ortak şikayet var mı bak.`, "reviews");

  if ((m.subs_new_today ?? 0) > 0) add("good", `Bugün ${m.subs_new_today} yeni abone geldi 🎉`, "subs_today");

  if (!out.length) {
    const quiet = m.users_today === null && m.web_visitors_today === null && m.active_subs === null && m.installs_7d === null;
    return {
      mood: "meh",
      headline: quiet ? "Henüz veri yok, kaynak bağlanınca yorum yaparım." : "Sakin gidiyor, olağan dışı bir şey yok.",
      lines: [],
      key: "quiet",
    };
  }
  out.sort((a, b) => b.w - a.w);
  return { mood: out[0].mood, headline: out[0].text, lines: out.slice(1, 3).map((x) => x.text), key: out[0].key };
}
