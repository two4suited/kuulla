import SwiftUI

struct ShowRow: View {
    let show: Show

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: show.artworkUrl.flatMap(URL.init)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.secondary.opacity(0.2)
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(show.title)
                    .font(.body)
                    .lineLimit(1)
                Text(show.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
