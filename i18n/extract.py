#!/usr/bin/env python3
"""Uygulama (Swift) ve motordaki (TS) Türkçe metinleri şablon olarak çıkarır.
İçerideki değişkenler {} olur. Çıktı: i18n/strings.json (benzersiz, kaynak dosyalarıyla)."""
import re, glob, json, os, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TR = re.compile(r"[çğıöşüÇĞİÖŞÜ]|\b(ve|bir|yok|bugün|dün|gün|kurulum|gelir|bağla|abone|yorum|ürün|site|ziyaret|aktif|değil|hafta|saat|kaynak|uyarı|veri|son|Teşhis|Rakamlar|Geçmiş|Reklam|Tümü|Bitir|Geri|Devam|Kaydet|Dene|Kopyala|Kapat|Yenile|Hazır|Ürünlerin|Daha|Uygulama|Oyun|Altyapı|Web|Uyarılar|yeni|satış|deneme|iptal|kaldırma|indirme|cihaz|harcama|kampanya|gösterim|tıklama|ort|normal|tahmini|bağlı|bekleniyor|hata|dk|sa|g)\b")
SKIP_SWIFT = {"SelfTest.swift", "Render.swift"}

def swift_templates(s):
    # \( ... ) iç içe parantezleri dengeleyerek {} yap
    out, i = "", 0
    while i < len(s):
        if s.startswith("\\(", i):
            depth, j = 1, i + 2
            while j < len(s) and depth:
                depth += {"(": 1, ")": -1}.get(s[j], 0); j += 1
            out += "{}"; i = j
        else:
            out += s[i]; i += 1
    return out

def ts_templates(s):
    out, i = "", 0
    while i < len(s):
        if s.startswith("${", i):
            depth, j = 1, i + 2
            while j < len(s) and depth:
                depth += {"{": 1, "}": -1}.get(s[j], 0); j += 1
            out += "{}"; i = j
        else:
            out += s[i]; i += 1
    return out

found = {}
def add(t, src):
    t = t.replace('\\"', '"').replace("\\n", "\n").replace("\\'", "'")
    if not TR.search(t) or t.startswith("http") or len(t.strip()) < 2: return
    found.setdefault(t, set()).add(src)

for f in glob.glob(f"{ROOT}/mac/Sources/Pulse/*.swift"):
    if os.path.basename(f) in SKIP_SWIFT: continue
    for n, line in enumerate(open(f), 1):
        st = line.strip()
        if st.startswith("//") or st.startswith("///") or st.startswith("print("): continue
        for m in re.finditer(r'"((?:[^"\\]|\\.)*)"', line):
            add(swift_templates(m.group(1)), f"{os.path.basename(f)}:{n}")

for f in glob.glob(f"{ROOT}/engine/src/**/*.ts", recursive=True) + glob.glob(f"{ROOT}/engine/local/*.ts"):
    txt = open(f).read()
    txt = re.sub(r"/\*.*?\*/", "", txt, flags=re.S)
    for n, line in enumerate(txt.split("\n"), 1):
        st = line.strip()
        if st.startswith("//"): continue
        line = re.sub(r"\s//.*$", "", line)
        for m in re.finditer(r'"((?:[^"\\]|\\.)*)"|`((?:[^`\\]|\\.)*)`|\'((?:[^\'\\]|\\.)*)\'', line):
            g = next(x for x in m.groups() if x is not None)
            if "console.log" in line or "log(" in line and "markSource" not in line and "raise" not in line: continue
            add(ts_templates(g), f"engine/{os.path.relpath(f, ROOT+'/engine')}:{n}")

out = [{"tr": k, "src": sorted(v)[:3]} for k, v in sorted(found.items())]
json.dump(out, open(f"{ROOT}/i18n/strings.json", "w"), ensure_ascii=False, indent=1)
print(len(out), "metin")
