import Foundation

/// How a link's destination is written out when the pointer is over it
/// (non-spec: user-requested).
public enum LinkDestination {
    /// What the pane shows for `url`. A `javascript:` link shows its scheme
    /// only: the code is not an address, and can be made to look like one.
    /// Bounded, because the label truncates on screen but still has to lay
    /// the text out.
    public static func display(_ url: URL) -> String {
        if url.scheme?.lowercased() == "javascript" { return "javascript:" }
        return String(url.absoluteString.prefix(512))
    }
}
