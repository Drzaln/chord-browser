import ChordMCP
import Foundation

/// How much of a Space an agent gets (0mu.2).
public enum AgentAccessLevel: String, CaseIterable, Identifiable, Sendable {
    case off, read, act
    public var id: String { rawValue }
}

/// The user's answer to an `AgentActionPrompt`.
public enum AgentConfirmationAnswer: Sendable, Equatable {
    case deny
    case allow
    /// Allow, and stop asking for this kind of action on this site until
    /// Chord quits. Offered only where the prompt says so (`eval_js`).
    case allowForSite
}

/// What the user is asked before an agent's action goes ahead.
public struct AgentActionPrompt: Sendable, Equatable {
    /// "click", "submit" or "script".
    public let action: String
    /// The element's label, as the page gives it.
    public let target: String
    public let host: String
    public let spaceName: String
    /// Why Chord is asking, in a few words: "submits a sign-in form".
    public let reason: String

    /// The JavaScript an `eval_js` run would execute, shown in full.
    public let script: String?
    /// Whether "Allow on this site until Chord quits" is offered.
    public let offersAllowForSite: Bool

    public init(
        action: String, target: String, host: String, spaceName: String, reason: String,
        script: String? = nil, offersAllowForSite: Bool = false
    ) {
        self.action = action
        self.target = target
        self.host = host
        self.spaceName = spaceName
        self.reason = reason
        self.script = script
        self.offersAllowForSite = offersAllowForSite
    }
}

/// Decides which agent actions need the user's yes (0mu.2).
///
/// Best effort, from what the page says about the element: the user is asked
/// before a sign-in form or a form that posts data is submitted, and before
/// anything whose label reads like buying, paying, sending or deleting. A
/// search box, a link or a plain button goes ahead. The page writes those
/// labels, so a hostile page can dodge the word list. The rule that holds
/// regardless is that a POST form always asks, so a site cannot have data
/// sent without the user seeing it.
enum AgentActionPolicy {
    /// Matched as whole words (or phrases) in lowercased labels. Indonesian
    /// alongside English, for the sites this browser's user actually visits.
    static let riskyPhrases: [String] = [
        "buy", "purchase", "pay", "payment", "checkout", "check out", "place order", "order now",
        "send", "submit", "delete", "remove", "confirm", "transfer", "publish", "post",
        "subscribe", "unsubscribe", "sign up", "register", "book", "reserve", "donate", "sell",
        "withdraw", "accept", "authorize", "authorise",
        "beli", "bayar", "kirim", "hapus", "pesan", "daftar", "konfirmasi", "setuju",
    ]

    /// The phrase in `label` that makes it risky, if any.
    static func riskyPhrase(in label: String) -> String? {
        let words = label.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let padded = " " + words.joined(separator: " ") + " "
        return riskyPhrases.first { padded.contains(" " + $0 + " ") }
    }

    /// Why submitting `form` needs a yes, or nil.
    static func reason(submitting form: JSONValue?) -> String? {
        guard let form, form.objectValue != nil else { return nil }
        if form["has_password"]?.boolValue == true { return "submits a sign-in form" }
        if let text = form["submit_text"]?.stringValue, let phrase = riskyPhrase(in: text) {
            return "submits a form whose button says “\(phrase)”"
        }
        if form["method"]?.stringValue == "post", form["is_search"]?.boolValue != true {
            return "submits a form that sends data to the site"
        }
        return nil
    }

    /// Why clicking the described element needs a yes, or nil.
    static func reason(clicking element: JSONValue) -> String? {
        if element["password_filled"]?.boolValue == true {
            return "the page has a password filled in, which this could send"
        }
        if element["is_submit"]?.boolValue == true, let why = reason(submitting: element["form"]) {
            return why
        }
        if let name = element["name"]?.stringValue, let phrase = riskyPhrase(in: name) {
            return "its label says “\(phrase)”"
        }
        return nil
    }

    /// Why typing with `submit: true` into the described field needs a yes.
    static func reason(typingAndSubmitting element: JSONValue) -> String? {
        if element["password_filled"]?.boolValue == true {
            return "the page has a password filled in, which this could send"
        }
        return reason(submitting: element["form"])
    }
}
