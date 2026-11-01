import Foundation

/// An extension recording right now (1mm.15): Loom, Awesome Screenshot and the
/// like, through the capture bridge (`ExtensionCapture`). WebKit-free, for the
/// recording pill.
public struct ExtensionRecording: Sendable, Equatable, Identifiable {
    /// The extension's Chrome id.
    public let id: String
    public let name: String
    public let screen: Bool
    public let camera: Bool
    public let microphone: Bool

    public init(id: String, name: String, screen: Bool, camera: Bool, microphone: Bool) {
        self.id = id
        self.name = name
        self.screen = screen
        self.camera = camera
        self.microphone = microphone
    }

    /// "is recording your screen", "is using your camera and microphone"…
    public var what: String {
        if screen { return "is recording your screen" }
        if camera && microphone { return "is using your camera and microphone" }
        return camera ? "is using your camera" : "is using your microphone"
    }
}
