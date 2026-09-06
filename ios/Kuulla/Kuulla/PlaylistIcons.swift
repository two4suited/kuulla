import Foundation
import SwiftUI

// iOS mirror of Kuulla.Api.Models.PlaylistIcons.Curated and the Web accent palette (#439). Must
// stay identical to src/Kuulla.Api/Models/PlaylistIcons.cs and
// src/Kuulla.Web/Models/PlaylistIcons.cs so the picker offers the same grid on every client. The
// API is the source of truth and rejects any icon outside its own copy.
enum PlaylistIcons {
    static let curated: [String] = [
        "🎧", "🎵", "🔥", "⭐", "❤️", "🎯", "💪", "🏃",
        "🚗", "🛏️", "☕", "🌙", "☀️", "🧠", "📚", "💼",
        "🎙️", "😂", "📰", "🏛️", "⚽", "🍿", "✈️", "🧘",
    ]

    // Convenience swatches for the accent-colour picker. The server only checks #RRGGBB format,
    // so this is a UI aid rather than an enforced set.
    static let accentPalette: [String] = [
        "#EF4444", "#F97316", "#EAB308", "#22C55E", "#14B8A6",
        "#3B82F6", "#6366F1", "#A855F7", "#EC4899", "#78716C",
    ]
}

// Curated icon + accent-colour picker shared by the create-playlist and edit-playlist flows
// (#439). The grid comes from PlaylistIcons.curated so every client offers the same set; the
// server rejects anything outside it. Both selections are optional — the "None" chip clears them
// and the playlist falls back to its default glyph.
struct PlaylistAppearancePicker: View {
    @Binding var icon: String?
    @Binding var accentColor: String?

    private let columns = [GridItem(.adaptive(minimum: 44), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Icon")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 8) {
                chip(isSelected: icon == nil, label: "None") { icon = nil }
                ForEach(PlaylistIcons.curated, id: \.self) { option in
                    chip(isSelected: icon == option, label: option) {
                        icon = (icon == option) ? nil : option
                    }
                }
            }

            Text("Accent colour")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 8) {
                chip(isSelected: accentColor == nil, label: "None") { accentColor = nil }
                ForEach(PlaylistIcons.accentPalette, id: \.self) { hex in
                    Button {
                        accentColor = (accentColor?.caseInsensitiveCompare(hex) == .orderedSame) ? nil : hex
                    } label: {
                        Circle()
                            .fill(Color(playlistAccentHex: hex) ?? .secondary)
                            .frame(width: 30, height: 30)
                            .overlay(
                                Circle().strokeBorder(
                                    .primary,
                                    lineWidth: accentColor?.caseInsensitiveCompare(hex) == .orderedSame ? 3 : 0))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(hex)
                }
            }
        }
    }

    private func chip(isSelected: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(label.count <= 2 ? .title3 : .caption)
                .frame(minWidth: 40, minHeight: 32)
                .padding(.horizontal, 4)
                .background(isSelected ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

extension Color {
    // Parses a playlist accent colour ("#RRGGBB", the only shape the API stores). Returns nil for
    // a nil/malformed value so callers can fall back to the default tint.
    init?(playlistAccentHex hex: String?) {
        guard let hex, hex.hasPrefix("#"), hex.count == 7,
              let value = Int(hex.dropFirst(), radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
}
