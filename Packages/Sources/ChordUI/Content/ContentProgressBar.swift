import ChordStore
import SwiftUI

/// The web card's own loading bar, shown only while the sidebar's bar is off
/// screen (collapsed and not revealed) — so there is always exactly one loading
/// indicator on screen.
///
/// Same data and the same §6.4 perf rule as the sidebar's bar in
/// `NavigationBar`: it observes the focused pane's `PaneRuntime`, so a progress
/// tick redraws this bar and nothing else.
struct ContentProgressBar: View {
    @Bindable var store: TabStore
    @Bindable var windowState: WindowState
    /// The collapsed-and-not-revealed gate from `RootView`. Whenever this is
    /// false the sidebar (with its own bar) is on screen, so this bar is hidden.
    var visible: Bool
    /// The active Space's colour, matching the sidebar's bar.
    var tint: Color = .accentColor

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var runtime: PaneRuntime? {
        store.selectedTab(in: windowState).map { store.runtime(for: $0.focusedPaneID) }
    }

    var body: some View {
        let progress = runtime?.estimatedProgress ?? 0
        let shown = visible && runtime?.isLoading == true && progress > 0 && progress < 1
        let motion = Motion.respectingReduceMotion(Motion.progressBar, reduceMotion: reduceMotion)

        GeometryReader { geometry in
            Rectangle()
                .fill(tint)
                .frame(width: geometry.size.width * progress)
        }
        .frame(height: 2)
        .opacity(shown ? 1 : 0)
        .animation(motion, value: progress)
        .animation(motion, value: shown)
        // A bar under the cursor must never swallow a click or a drag into the
        // page, and it is purely decorative to a screen reader.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
