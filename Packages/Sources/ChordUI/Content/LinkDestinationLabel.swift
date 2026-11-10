import ChordCore
import ChordStore
import SwiftUI

/// Where the link under the pointer goes, at the bottom-left corner of its
/// pane (non-spec: user-requested).
///
/// Its own view, reading only `PaneRuntime.hoveredLink`, so a pointer crossing
/// a page full of links redraws this label and nothing around it. It never
/// takes a click: a layer that did would sit above the web view and swallow
/// the click meant for the link.
struct LinkDestinationLabel: View {
    let runtime: PaneRuntime
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let link = runtime.hoveredLink
        ZStack(alignment: .bottomLeading) {
            if let link {
                Text(LinkDestination.display(link))
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(.separator, lineWidth: 0.5)
                    )
                    .padding(6)
                    .frame(maxWidth: 560, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .animation(
            Motion.respectingReduceMotion(Motion.sidebarHover, reduceMotion: reduceMotion),
            value: link
        )
        .allowsHitTesting(false)
        // The page already says where its links go to assistive technology.
        .accessibilityHidden(true)
    }
}
