# Pulse

Your App Store and Google Play numbers in a side panel on your Mac: active users, installs, revenue, subscriptions, reviews and a short note on what needs your attention today.

**Download the signed app:** [egeyildizli.com](https://egeyildizli.com) (free, macOS 14 or later)

[Türkçe aşağıda](#türkçe)

## Privacy

- Everything runs on your Mac. Keys are stored in your Keychain, data in a local database.
- Pulse has no server that stores your data. Nothing from your connected accounts is sent to the authors.
- Pulse only talks to the services you connect (Apple, Google, RevenueCat, Stripe, Cloudflare, Meta, and an AI provider if you turn the AI note on), plus a public currency-rate service.
- The official build checks once a day whether a new version is out. Builds made from this source code never do.

The full list is in the app under **About**.

## What you need

- An App Store Connect API key or a Google Play service account. Everything else is optional.

## Build from source

Requirements: macOS 14+, Xcode 15.3+ (or its command line tools), [Bun](https://bun.sh).

```sh
git clone https://github.com/egeyildizli/pulse-mac.git
cd pulse-mac/mac
./build.sh
```

The app is installed to `~/Applications/Pulse.app`. Without a Developer ID certificate it is signed ad hoc, which is fine for your own Mac.

## Project layout

- `engine/`: TypeScript engine that talks to the stores and keeps the local database.
- `mac/Sources/Pulse/`: the SwiftUI side panel.
- `i18n/`: Turkish source strings and their English translations.

## License

[PolyForm Noncommercial 1.0.0](LICENSE.md): free to use, change and share for any noncommercial purpose. Selling it or using it in a commercial product needs permission. Bundled third-party components keep their own licenses, see [legal/THIRD_PARTY_NOTICES.md](legal/THIRD_PARTY_NOTICES.md).

---

## Türkçe

App Store ve Google Play rakamların Mac'inin kenarında bir panelde: aktif kullanıcı, kurulum, gelir, abonelik, yorumlar ve bugün neye bakman gerektiğini söyleyen kısa bir not.

**İmzalı uygulamayı indir:** [egeyildizli.com](https://egeyildizli.com) (ücretsiz, macOS 14 ve üstü)

### Gizlilik

- Her şey senin Mac'inde çalışır. Anahtarlar Keychain'de, veriler yerel bir veritabanında durur.
- Pulse'ın verilerini tutan bir sunucu yok. Bağladığın hesaplardan geliştiricilere hiçbir şey gitmez.
- Pulse yalnız senin bağladığın servislerle (Apple, Google, RevenueCat, Stripe, Cloudflare, Meta ve AI notunu açtıysan seçtiğin AI servisi) ve herkese açık bir döviz kuru servisiyle konuşur.
- Resmi sürüm günde bir kez yeni sürüm olup olmadığına bakar. Bu kaynak koddan derlenen kopyalar bunu hiç yapmaz.

### Kaynaktan derleme

Gerekenler: macOS 14+, Xcode 15.3+ (ya da komut satırı araçları), [Bun](https://bun.sh).

```sh
git clone https://github.com/egeyildizli/pulse-mac.git
cd pulse-mac/mac
./build.sh
```

### Lisans

[PolyForm Noncommercial 1.0.0](LICENSE.md): ticari olmayan her amaçla ücretsiz kullanılabilir, değiştirilebilir ve paylaşılabilir. Satmak ya da ücretli bir ürüne katmak için izin gerekir.
