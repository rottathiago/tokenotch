import AppKit
import SwiftUI

/// Brand images bundled from sources/Resources/Brand (regenerate with scripts/make-brand-assets.py).
/// Unbundled builds fall back to a system symbol when the images aren't next to the executable.
enum TokenotchBrand {
    private static var cache: [String: NSImage] = [:]

    static func image(_ name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache[name] = image
        return image
    }

    static var menuBarImage: NSImage? {
        guard let copy = image("TokenotchMenuBar")?.copy() as? NSImage else { return nil }
        copy.size = NSSize(width: 18, height: 18)
        copy.isTemplate = true
        return copy
    }
}

/// The Tokenotch mark, with light strokes in dark mode.
struct TokenotchMarkView: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if let image = TokenotchBrand.image(scheme == .dark ? "TokenotchMarkDark" : "TokenotchMark") {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "sparkle").resizable().aspectRatio(contentMode: .fit)
                    .foregroundStyle(.blue).padding(4)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The mark above the Tokenotch name, set as text so it adapts to light and dark mode.
struct TokenotchLogoView: View {
    var markHeight: CGFloat = 104

    var body: some View {
        VStack(spacing: 8) {
            TokenotchMarkView().frame(height: markHeight)
            Text("Tokenotch").font(.system(size: markHeight * 0.34, weight: .bold, design: .rounded))
        }
        .accessibilityElement()
        .accessibilityLabel("Tokenotch")
    }
}
