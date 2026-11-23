import { addDays } from "./util";

export type Sev = "critical" | "bad" | "meh" | "good";

export interface Finding {
  sev: Sev;
  area: string;
  title: string;
  why: string;
  fix: string;
}

export interface FunnelStep {
  label: string;
  now: number;
  prev: number | null;
  money?: boolean;
  rateTxt?: string;
  targetTxt?: string;
  ok?: boolean;
}

export interface Gap {
  title: string;
  how: string;
}

export interface Diagnosis {
  score: number;
  verdict: string;
  funnel: FunnelStep[];
  issues: Finding[];
  wins: Finding[];
  gaps: Gap[];
  window: string;
}

export interface DiagnoseInput {
  segment: string;
  prelaunch?: boolean;
  hasRc: boolean;
  hasGa4: boolean;
  hasStripe: boolean;
  hasSite: boolean;
  series: Record<string, { day: string; value: number }[]>;
  today: string;
  reviews?: { rating: number; title?: string | null }[];
  countries?: Record<string, number> | null;
}

const n = (x: number) => Math.round(x).toLocaleString("tr-TR");
const r1 = (x: number) => Math.round(x * 10) / 10;
const pctTxt = (x: number) => `%${n(x)}`;
const pctStep = (n: number, base: number, of: string, target?: number): Partial<FunnelStep> => {
  if (!base) return {};
  const r = (n / base) * 100;
  return {
    rateTxt: `${of} %${r < 10 ? r.toFixed(1).replace(".", ",") : Math.round(r)}`,
    ...(target !== undefined ? { targetTxt: `ölçüt %${target}`, ok: r >= target } : {}),
  };
};
const money = (x: number) => `$${x >= 100 ? Math.round(x) : x.toFixed(2)}`;

export function diagnose(i: DiagnoseInput): Diagnosis {
  const s = i.series;
  const end = addDays(i.today, -1);
  const from = addDays(i.today, -7);
  const pFrom = addDays(i.today, -14);
  const pEnd = addDays(i.today, -8);
  const has = (m: string) => (s[m]?.length ?? 0) > 0;
  const sum = (m: string, a: string, b: string) => (s[m] ?? []).filter((x) => x.day >= a && x.day <= b).reduce((t, x) => t + x.value, 0);
  const cur = (m: string) => sum(m, from, end);
  const prv = (m: string) => {
    const pts = (s[m] ?? []).filter((x) => x.day >= pFrom && x.day <= pEnd);
    return pts.length ? pts.reduce((t, x) => t + x.value, 0) : null;
  };
  const last = (m: string) => {
    const pts = s[m] ?? [];
    return pts.length ? pts[pts.length - 1].value : null;
  };
  const change = (c: number, p: number | null, min: number) => (p === null || p < min ? null : ((c - p) / p) * 100);

  const breakDay = (m: string) => {
    const pts = (s[m] ?? []).filter((x) => x.day >= pFrom && x.day <= end);
    let best: { day: string; from: number; to: number } | null = null;
    for (let k = 1; k < pts.length; k++) {
      const d = pts[k - 1].value - pts[k].value;
      if (d > 0 && (!best || d > best.from - best.to)) best = { day: pts[k].day, from: pts[k - 1].value, to: pts[k].value };
    }
    return best;
  };
  const dayTr = (d: string) => {
    const [, mo, da] = d.split("-").map(Number);
    return `${da} ${["Oca", "Şub", "Mar", "Nis", "May", "Haz", "Tem", "Ağu", "Eyl", "Eki", "Kas", "Ara"][mo - 1]}`;
  };

  const issues: Finding[] = [];
  const wins: Finding[] = [];
  const gaps: Gap[] = [];
  const funnel: FunnelStep[] = [];
  const add = (f: Finding) => (f.sev === "good" ? wins : issues).push(f);

  const W = cur("web_visitors");
  const Wp = prv("web_visitors");
  const wCh = change(W, Wp, 50);

  if (i.segment === "web") {
    const pv = cur("web_pageviews");
    funnel.push({ label: "Ziyaretçi", now: W, prev: Wp });
    if (W > 0) funnel.push({ label: "Sayfa görüntüleme", now: pv, prev: prv("web_pageviews"), rateTxt: `kişi başı ${r1(pv / W).toString().replace(".", ",")} sayfa`, targetTxt: "ölçüt 1,5+", ok: pv / W >= 1.5 });
    if (wCh !== null && wCh <= -30)
      add({
        sev: "bad", area: "Trafik",
        title: `Ziyaret ${pctTxt(-wCh)} düştü (${n(Wp!)} → ${n(W)})`,
        why: "Google sıralaması kaymış, bir paylaşımın etkisi bitmiş ya da reklam kapanmış olabilir.",
        fix: "Search Console'da tıklama ve sıralamaya bak; düşen sayfayı bul. Düzenli içerik ve paylaşım planı kur.",
      });
    else if (wCh !== null && wCh >= 30)
      add({ sev: "good", area: "Trafik", title: `Ziyaret ${pctTxt(wCh)} arttı (${n(W)})`, why: "Yeni bir kanal ya da sıralama işe yaradı.", fix: "Nereden geldiğini bul, o kanala daha çok içerik koy." });
    if (W >= 200 && pv / W < 1.4)
      add({
        sev: "meh", area: "Etkileşim",
        title: `Gelen kişi ortalama ${r1(pv / W)} sayfa bakıp çıkıyor`,
        why: "İlk ekran ne sunduğunu hemen anlatmıyor ya da devamına götüren bağlantı yok.",
        fix: "Üst bölümde tek cümle değer + tek belirgin buton koy; sayfa sonuna ilgili ürün/örnek bağlantıları ekle.",
      });
    if (i.hasStripe) {
      const sales = cur("sales");
      const rev = cur("revenue_usd");
      funnel.push({ label: "Satış", now: sales, prev: prv("sales"), ...pctStep(sales, W, "ziyaretçinin", 1) });
      funnel.push({ label: "Gelir", now: rev, prev: prv("revenue_usd"), money: true });
      if (W >= 300 && sales === 0)
        add({
          sev: "bad", area: "Dönüşüm",
          title: `${n(W)} ziyaret, 0 satış`,
          why: "Ziyaretçi ödeme adımına gelmiyor ya da fiyat/güven yüzünden vazgeçiyor. Ücretsiz deneme yoksa insanlar sonucu görmeden para vermiyor.",
          fix: "İlk dönüşümü ücretsiz (filigranlı) ver, sonra ödeme iste. Ödeme butonunu ilk ekrana al, örnek çıktıları ve gerçek kullanıcı sayısını göster.",
        });
      else if (W >= 300 && sales / W < 0.005)
        add({ sev: "meh", area: "Dönüşüm", title: `Dönüşüm ${r1((sales / W) * 100)}%, ölçüt %1`, why: "Ziyaretçiler ürünü anlıyor ama ödemeye ikna olmuyor.", fix: "Fiyat sayfasında tek paket öne çıkar, para iade garantisi yaz." });
      else if (sales > 0) add({ sev: "good", area: "Dönüşüm", title: `Bu hafta ${sales} satış (${money(rev)})`, why: "Ödeme akışı çalışıyor.", fix: "Satış gelen kaynağa yüklen." });
    }
    const req = cur("web_requests");
    const thr = cur("web_threats");
    if (req >= 1000 && thr / req > 0.05)
      add({ sev: "meh", area: "Güvenlik", title: `İsteklerin ${pctTxt((thr / req) * 100)}'i tehdit`, why: "Bot ya da tarayıcı saldırısı geliyor.", fix: "Cloudflare'de Bot Fight Mode'u aç, şüpheli ülkelere challenge koy." });
    if (!i.hasGa4) gaps.push({ title: "Hangi sayfada çıktıklarını göremiyorum", how: "Siteye GA4 ya da Cloudflare Web Analytics ekle; sayfa bazlı çıkış ve kaynak gelsin." });
  } else {
    const I = cur("installs");
    const Ip = prv("installs");
    const T = cur("trials_new");
    const S = cur("subs_new");
    const R = cur("revenue_usd");
    const G = cur("revenue_gross_usd");
    const iCh = change(I, Ip, 20);
    if (i.hasSite && W > 0) funnel.push({ label: "Site ziyaretçisi", now: W, prev: Wp });
    if (has("installs")) funnel.push({ label: "Kurulum", now: I, prev: Ip });
    if (i.hasRc && !i.prelaunch) {
      const game = i.segment === "game";
      if (!game || T > 0) funnel.push({ label: "Deneme başlatan", now: T, prev: prv("trials_new"), ...pctStep(T, I, "kurulanların", 5) });
      if (!game || S > 0 || (prv("subs_new") ?? 0) > 0) funnel.push({ label: "Yeni abone", now: S, prev: prv("subs_new"), ...pctStep(S, I, "kurulanların", 2) });
      funnel.push({ label: "Net gelir", now: R, prev: prv("revenue_usd"), money: true, ...(I ? { rateTxt: `kurulum başı ${money(R / I)}`, ...(game ? {} : { targetTxt: "ölçüt $0,10", ok: R / I >= 0.1 }) } : {}) });
    }

    if (i.prelaunch) {
      issues.push({ sev: "meh", area: "Yayın", title: "Henüz yayında değil", why: "Mağazada olmadığı için kurulum ve gelir yok.", fix: "Yayın öncesi bekleme listesi ve TestFlight topluluğu topla; açılış günü için hazır kitle olsun." });
    } else {
      if (iCh !== null && iCh <= -35) {
        const b = breakDay("installs");
        const siteHolds = wCh !== null && wCh > -20;
        add({
          sev: iCh <= -60 ? "critical" : "bad", area: "Kurulum",
          title: `Kurulumlar ${pctTxt(-iCh)} düştü (${n(Ip!)} → ${n(I)})` + (b ? `, en sert kırılma ${dayTr(b.day)} (${n(b.from)} → ${n(b.to)})` : ""),
          why: siteHolds
            ? "Site trafiği yerinde ama mağazadan gelen azaldı: öne çıkarma/kategori sıralaması bitti, anahtar kelime sıralaması kaydı ya da reklam kapandı."
            : "Site ve mağaza birlikte düştü: bir kampanyanın ya da viral paylaşımın etkisi bitmiş, genel ilgi azalmış.",
          fix: "Kırılma gününde ne değişti bak (sürüm, fiyat, reklam bütçesi, mağaza görselleri). ASC'de kaynak kırılımına (arama/göz atma/yönlendiren) bak, düşen kanalı geri besle. Ekran görüntüleri ve alt başlıkla yeni bir ASO denemesi aç.",
        });
      } else if (iCh !== null && iCh >= 40)
        add({ sev: "good", area: "Kurulum", title: `Kurulumlar ${pctTxt(iCh)} arttı (${n(I)})`, why: "Yeni bir kanal, sıralama ya da paylaşım çalıştı.", fix: "Hangi ülke/kanaldan geldiğini bul ve oraya yüklen." });
      if (I <= 7 && has("installs"))
        add({
          sev: "meh", area: "Görünürlük",
          title: `Haftada sadece ${n(I)} kurulum`,
          why: "Mağazada aramada çıkmıyor; dışarıdan trafik de yok.",
          fix: "Başlık/alt başlıkta aranan kelimeyi kullan, 3 ekran görüntüsünü fayda anlatan metinle yenile, sitedeki trafiği mağaza bağlantısına yönlendir.",
        });

      if (i.hasSite && W >= 300 && I / W < 0.02)
        add({
          sev: "bad", area: "Site",
          title: `Site ${n(W)} ziyaret aldı ama sadece ${n(I)} kurulum`,
          why: "Siteden mağazaya geçiş yok: indirme butonu görünmüyor, ya da gelenler hedef kitle değil (bot, alakasız arama).",
          fix: "Ana sayfanın en üstüne App Store/Play rozeti koy, iOS'ta Smart App Banner ekle, mağaza bağlantısına UTM/kampanya kodu koyup tıklamayı ölç.",
        });
      if (i.hasRc && i.segment !== "game" && I >= 10 && I < 50 && T === 0 && S === 0)
        add({
          sev: "meh", area: "Dönüşüm",
          title: `${n(I)} kurulum, ama kimse deneme ya da abonelik başlatmadı`,
          why: "Paywall'a ulaşılmıyor ya da teklif çekici değil; az sayıda kurulumla bu normal de olabilir.",
          fix: "Paywall'un yeni kullanıcıya gösterildiğini kendin sıfırdan kurarak dene; ücretsiz deneme ekle.",
        });
      if (i.hasRc && I >= 50) {
        const tr = (T / I) * 100;
        const sr = (S / I) * 100;
        if (i.segment !== "game") {
          if (tr < 3 && sr < 1)
            add({
              sev: "bad", area: "Dönüşüm",
              title: `Kurulanların sadece ${r1(tr)}%'i deneme başlatıyor (ölçüt %5+)`,
              why: "Paywall'a ulaşan az, ya da deneme teklifi görünmüyor/çekici değil.",
              fix: "Onboarding'in sonunda paywall'u mutlaka göster, deneme süresini büyük yaz ('3 gün ücretsiz'), kapatma tuşunu gecikmeli göster.",
            });
          if (sr < 1)
            add({
              sev: "bad", area: "Dönüşüm",
              title: `Kurulanların ${r1(sr)}%'i abone oluyor (ölçüt %2)`,
              why: "Ödeme duvarı değer anlatmadan geliyor ya da fiyat bu pazara pahalı.",
              fix: "Paywall'dan önce bir 'aha' anı yaşat (ilk sonuç/ilk kombin). Yıllık paketi aylık karşılığıyla göster, ülkeye göre fiyat dene.",
            });
          else if (sr >= 2.5) add({ sev: "good", area: "Dönüşüm", title: `Kurulanların ${r1(sr)}%'i abone oluyor`, why: "Paywall ve fiyat bu kitleye oturmuş.", fix: "Aynı akışı bozmadan kurulum sayısını artırmaya odaklan." });
        }
        const arpi = R / I;
        if (i.segment !== "game" && arpi > 0 && arpi < 0.05)
          add({ sev: "meh", area: "Gelir", title: `Kurulum başı net gelir ${money(arpi)}`, why: "Çok kurulum var ama kişi başı para düşük; reklama para basarsan geri dönmez.", fix: "Kurulum başı $0,10'u geçmeden ücretli reklam açma. Önce dönüşümü yükselt." });
      }

      const Sp = prv("subs_new");
      const sCh = change(S, Sp, 5);
      if (sCh !== null && sCh >= 50) add({ sev: "good", area: "Abonelik", title: `Yeni abone ${pctTxt(sCh)} arttı (${n(Sp!)} → ${n(S)})`, why: "Fiyat/paywall değişikliği ya da daha kaliteli trafik işe yaradı.", fix: "Neyi değiştirdiysen not al ve sabitle." });
      else if (sCh !== null && sCh <= -40)
        add({ sev: "bad", area: "Abonelik", title: `Yeni abone ${pctTxt(-sCh)} düştü (${n(Sp!)} → ${n(S)})`, why: iCh !== null && iCh < -30 ? "Kurulum düştüğü için abone de düştü." : "Kurulum yerinde ama satın alan azaldı: paywall, fiyat ya da son sürümde bir şey bozulmuş olabilir.", fix: "Son sürümde satın alma akışını kendin dene; RevenueCat'te ürünlerin 'aktif' olduğunu kontrol et." });
      const Tp = prv("trials_new");
      const tCh = change(T, Tp, 10);
      if (tCh !== null && tCh <= -50)
        add({ sev: "meh", area: "Deneme", title: `Yeni deneme ${pctTxt(-tCh)} düştü (${n(Tp!)} → ${n(T)})`, why: S > (Sp ?? 0) ? "Deneme azalırken doğrudan satın alma artmış: fiyat testi deneme yerine direkt ödemeye itiyor olabilir." : "Deneme teklifi görünmüyor ya da kurulum azaldı.", fix: "A/B test gruplarına ayrı ayrı bak: hangi grup daha çok net gelir getiriyor, onu herkese aç." });

      const Rp = prv("revenue_usd");
      const rCh = change(R, Rp, 15);
      if (rCh !== null && rCh <= -40) add({ sev: "bad", area: "Gelir", title: `Net gelir ${pctTxt(-rCh)} düştü (${money(Rp!)} → ${money(R)})`, why: "Daha az yeni abone ya da yenilemeler azaldı.", fix: "Abone ve yenileme kırılımına bak; iptal edenlere geri kazanım teklifi kur." });
      else if (rCh !== null && rCh >= 40) add({ sev: "good", area: "Gelir", title: `Net gelir ${pctTxt(rCh)} arttı (${money(Rp!)} → ${money(R)})`, why: "Daha çok satış ya da daha yüksek fiyat tuttu.", fix: "Bu fiyatı/paketi koru, kurulumu büyüt." });
      if (G >= 20 && R / G < 0.65)
        add({ sev: "meh", area: "Gelir", title: `Brütün sadece ${pctTxt((R / G) * 100)}'i sana kalıyor (${money(G)} → ${money(R)})`, why: "Mağaza payı (%15-30) ve KDV (TR'de %20) düşülüyor. %30 kesiliyorsa Small Business Program kaydı eksik olabilir.", fix: "Apple Small Business Program ve Play %15 kademesine kayıtlı olduğunu doğrula; web'den ödeme seçeneği düşün." });

      const ref = cur("refunded_usd");
      if (G >= 20 && ref / G > 0.05) add({ sev: "bad", area: "Gelir", title: `İade oranı ${pctTxt((ref / G) * 100)} (${money(ref)})`, why: "Kullanıcı aldığını beğenmiyor ya da yanlışlıkla satın alıyor.", fix: "Paywall'da ne alacağını net yaz, ilk günlerde değer gösteren bildirim gönder." });
      const ch = cur("subs_churned");
      const subs = last("active_subs") ?? 0;
      if (ch >= Math.max(3, subs * 0.1)) add({ sev: "bad", area: "Abonelik", title: `Bu hafta ${n(ch)} abone ayrıldı (aktif ${subs})`, why: "Uygulama aboneliği hak edecek kadar sık kullanılmıyor ya da son sürüm bir şeyi bozdu.", fix: "İptal anında kısa anket + indirimli teklif koy; haftalık değer bildirimi gönder." });

      const U = cur("users");
      const Up = prv("users");
      const uCh = change(U, Up, 50);
      if (uCh !== null && uCh <= -35)
        add({ sev: "bad", area: "Kullanıcı", title: `Günlük aktif kullanıcı ${pctTxt(-uCh)} düştü`, why: iCh !== null && iCh < -30 ? "Yeni gelen azaldığı için toplam aktif de düştü; mevcut kullanıcı kaybı ayrıca ölçülemiyor." : "Yeni gelen yerinde ama mevcut kullanıcı bırakıyor: son sürüm, bildirimler ya da sunucu sorunu olabilir.", fix: "Geri dönüş bildirimi (sabah özeti vb.) kur, son sürümün çökme raporlarına bak." });
      if (I >= 30 && U > 0) {
        const stick = U / 7 / Math.max(1, I / 7);
        if (stick < 1.2 && i.segment !== "web")
          add({ sev: "meh", area: "Kullanıcı", title: "Gelen kalmıyor", why: `Günlük aktif kullanıcı, günlük kurulumun sadece ${r1(stick)} katı; insanlar ilk günden sonra dönmüyor.`, fix: "İlk 3 günde geri çağıran bildirim ve günlük alışkanlık yaratan bir özellik (widget, seri) ekle." });
      }

      const rv = i.reviews ?? [];
      if (rv.length >= 3) {
        const avg = rv.reduce((t, x) => t + x.rating, 0) / rv.length;
        const low = rv.filter((x) => x.rating <= 2);
        if (avg < 3.8 || low.length >= 3)
          add({ sev: "bad", area: "Mağaza", title: `Son ${rv.length} yorum ortalaması ${avg.toFixed(1)} (${low.length} kötü)`, why: low[0]?.title ? `Örnek şikayet: "${low[0].title}"` : "Kullanıcılar bir şeyden şikayetçi.", fix: "Kötü yorumlara mağazadan cevap ver, en çok geçen şikayeti sonraki sürümde düzelt ve cevaba yaz." });
        else if (avg >= 4.5) add({ sev: "good", area: "Mağaza", title: `Yorum ortalaması ${avg.toFixed(1)}`, why: "Kullanıcı memnun.", fix: "Mutlu anlarda puanlama isteği (SKStoreReview) göster, puan sayısını büyüt." });
      }

      const c = i.countries ?? {};
      const tot = Object.values(c).reduce((t, x) => t + x, 0);
      const top = Object.entries(c).sort((a, b) => b[1] - a[1])[0];
      if (tot >= 20 && top && top[1] / tot >= 0.85)
        add({ sev: "meh", area: "Pazar", title: `İndirmelerin ${pctTxt((top[1] / tot) * 100)}'i tek ülkeden (${top[0]})`, why: "Diğer ülkelerde mağaza sayfası görünmüyor ya da yerelleştirme zayıf.", fix: "İngilizce, Almanca, İspanyolca mağaza metni ve ekran görüntüsü ekle; ülke bazlı fiyatı kontrol et." });
    }

    if (!i.hasRc && !i.prelaunch) gaps.push({ title: "Abonelik/gelir verisi yok", how: "Bu ürün RevenueCat'e bağlı değil." });
    if (i.hasRc && !i.prelaunch && i.segment !== "game" && sum("paywall_views", pFrom, end) === 0)
      gaps.push({ title: "Paywall'u kaç kişinin gördüğünü bilmiyorum", how: "RevenueCat Paywalls kullanılmıyor. Paywall gösterilince RevenueCat'e ya da Firebase Analytics'e olay gönder, gör/al oranı çıksın." });
    if (!i.hasGa4) gaps.push({ title: "Hangi ekranda takılıp çıktıklarını göremiyorum", how: "Firebase projesinde Google Analytics'i bağla; ekran bazlı çıkış ve D1/D7 tutma gelsin." });
    if (i.segment === "game" && sum("ad_revenue_usd", pFrom, end) === 0) gaps.push({ title: "Reklam geliri görünmüyor", how: "AdMob'u RevenueCat'e bağla ya da AdMob API'yi panele ekle." });
  }

  let score = 75;
  for (const f of issues) score -= { critical: 30, bad: 14, meh: 6, good: 0 }[f.sev];
  score += Math.min(20, wins.length * 6);
  score = Math.max(0, Math.min(100, score));
  if (i.prelaunch) score = 50;
  const verdict = i.prelaunch
    ? "Yayın öncesi"
    : score >= 80 ? "İyi gidiyor" : score >= 60 ? "İdare eder" : score >= 40 ? "Aksıyor" : "Kötü gidiyor";
  const order: Record<Sev, number> = { critical: 0, bad: 1, meh: 2, good: 3 };
  issues.sort((a, b) => order[a.sev] - order[b.sev]);
  return { score, verdict, funnel, issues, wins, gaps, window: `${dayTr(from)} - ${dayTr(end)}` };
}
