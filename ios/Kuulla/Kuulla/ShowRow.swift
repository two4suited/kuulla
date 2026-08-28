import SwiftUI

struct ShowRow: View {
    let show: Show

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: show.artworkUrl.flatMap(URL.init)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                KuullaColor.surfaceRaised
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md))

            VStack(alignment: .leading, spacing: 2) {
                Text(show.title)
                    .font(.kuullaBody(15, weight: .semibold))
                    .lineLimit(1)
                Text(show.author)
                    .font(.kuullaBody(13))
                    .foregroundStyle(KuullaColor.textMuted)
                    .lineLimit(1)
            }
        }
    }
}
