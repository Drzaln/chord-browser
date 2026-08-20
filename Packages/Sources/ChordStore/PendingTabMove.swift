import ChordCore
import Foundation

/// A drag that would carry a tab into a different Space, waiting on the user.
///
/// Dropping a tab into another window is a *Space* change, not a window
/// primitive — a window is only ever looking at one Space, so a tab arriving
/// from elsewhere has to change Spaces to be visible there. That matters because
/// each Space has its own `WKWebsiteDataStore`: the page is torn down and
/// rebuilt against different cookies, so a signed-in session does not survive.
/// Arc prompts for exactly this, and so do we.
///
/// Held on the destination `WindowState` because it is that window's dialog.
public struct PendingTabMove: Identifiable, Equatable, Sendable {

    /// What the drop was aiming at, so the confirmation completes the gesture the
    /// user actually made rather than a generic "move".
    public enum Destination: Equatable, Sendable {
        /// A sidebar section, at an insertion index.
        case section(TabStore.PlacementSection, index: Int)
        /// The content area of an existing tab — a drag-to-split (4.5).
        case splitInto(tabID: UUID)
        /// A Space button in the switcher — move into that Space keeping the tab's
        /// placement kind, no particular slot aimed at.
        case space
    }

    /// The tab being moved. Doubles as the identity of the pending prompt.
    public let id: UUID
    public let toSpaceID: UUID
    public let destination: Destination
    /// Names, captured when the drop happened, for the dialog to read back. Held
    /// rather than looked up so a Space renamed mid-prompt cannot blank the text.
    public let fromSpaceName: String
    public let toSpaceName: String
    public let tabTitle: String

    public init(
        id: UUID,
        toSpaceID: UUID,
        destination: Destination,
        fromSpaceName: String,
        toSpaceName: String,
        tabTitle: String
    ) {
        self.id = id
        self.toSpaceID = toSpaceID
        self.destination = destination
        self.fromSpaceName = fromSpaceName
        self.toSpaceName = toSpaceName
        self.tabTitle = tabTitle
    }
}
