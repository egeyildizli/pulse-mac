import SwiftUI

struct ReviewsDetailView: View {
    @EnvironmentObject var store: Store
    let onBack: () -> Void
    @State private var app = ""

    private var cards: [Card] { store.snap?.cards ?? [] }
    private var all: [Review] { store.snap?.reviews ?? [] }
    private var shown: [Review] { app.isEmpty ? all : all.filter { $0.app == app } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold))
                }.buttonStyle(.plain).keyboardShortcut(.escape, modifiers: [])
                Image(systemName: "star.fill").font(.system(size: 18)).foregroundStyle(.yellow)
                Text("Yorumlar").font(.system(size: 20, weight: .bold))
                Spacer()
            }.padding(16)
            Divider().opacity(0.3)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            chip("Tümü", "")
                            ForEach(cards.filter { c in all.contains { $0.app == c.id } }) { c in chip(c.name, c.id) }
                        }
                    }
                    let rs = shown
                    if !rs.isEmpty {
                        let avg = Double(rs.map(\.rating).reduce(0, +)) / Double(rs.count)
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Loc.isTurkish ? String(format: "%.1f ★", avg).replacingOccurrences(of: ".", with: ",") : String(format: "%.1f ★", avg)).font(.system(size: 28, weight: .bold, design: .rounded))
                                Text("son \(rs.count) yorumun ortalaması").font(.system(size: 11)).foregroundStyle(Theme.dim)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                ForEach((1...5).reversed(), id: \.self) { s in
                                    HStack(spacing: 6) {
                                        Text("\(s)★").font(.system(size: 10)).foregroundStyle(Theme.dim)
                                        Text("\(rs.filter { $0.rating == s }.count)").font(.system(size: 10, weight: .semibold)).monospacedDigit().frame(width: 22, alignment: .trailing)
                                    }
                                }
                            }
                        }
                        .padding(12).background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
                        ReviewsBlock(reviews: rs, cards: cards)
                    } else {
                        Text("Henüz yorum yok.").font(.system(size: 12)).foregroundStyle(Theme.dim)
                    }
                }
                .padding(12)
            }
        }
    }

    private func chip(_ title: String, _ id: String) -> some View {
        Button { withAnimation(.snappy) { app = id } } label: {
            Text(title).font(.system(size: 12, weight: app == id ? .semibold : .medium))
                .foregroundStyle(app == id ? Color.black : .white.opacity(0.8))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(app == id ? Color.white : Color.white.opacity(0.07)))
        }.buttonStyle(.plain)
    }
}
