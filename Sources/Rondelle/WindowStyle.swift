import AppKit
import SwiftUI

/// The look of Rondelle's windows, from «Metadati → Leggi»: content under a transparent title bar, a header
/// with the tool's symbol on the accent colour, values in rounded cards.
extension NSWindow {
    /// For SwiftUI content: it keeps clear of the title bar by itself (safe area). AppKit content would slide under it.
    func rondelleStyle() {
        styleMask.insert(.fullSizeContentView)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
    }
}

/// Top of a window: the symbol on the accent colour, the tool's name and a line under it (file, count…).
struct RondelleHeader<Trailing: View>: View {
    let symbol: String
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    init(symbol: String, title: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(Color(nsColor: Settings.accentColor), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
    }
}

extension RondelleHeader where Trailing == EmptyView {
    init(symbol: String, title: String, subtitle: String? = nil) {
        self.init(symbol: symbol, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// The small uppercase caption over a card.
struct RondelleSectionTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
    }
}

extension View {
    /// A rounded card on the window's background.
    func rondelleCard(cornerRadius: CGFloat = 12) -> some View {
        background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
