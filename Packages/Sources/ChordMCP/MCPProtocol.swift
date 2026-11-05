import Foundation

/// A tool the server offers, as `tools/list` describes it.
public struct MCPTool: Sendable, Equatable {
    public let name: String
    public let title: String
    public let description: String
    /// A JSON Schema object for the tool's `arguments`.
    public let inputSchema: JSONValue
    /// True for a tool that only reads. Sent as the `readOnlyHint` annotation,
    /// which a client may use to skip asking before it runs.
    public let readOnly: Bool

    public init(
        name: String, title: String, description: String,
        inputSchema: JSONValue, readOnly: Bool
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.readOnly = readOnly
    }

    var json: JSONValue {
        [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": [
                "title": .string(title),
                "readOnlyHint": .bool(readOnly),
                "openWorldHint": true,
            ],
        ]
    }
}

/// One piece of a tool's result.
public enum MCPContent: Sendable, Equatable {
    case text(String)
    /// Base64 is done here, so callers pass the raw image bytes.
    case image(Data, mimeType: String)

    var json: JSONValue {
        switch self {
        case .text(let text):
            return ["type": "text", "text": .string(text)]
        case .image(let data, let mimeType):
            return [
                "type": "image",
                "data": .string(data.base64EncodedString()),
                "mimeType": .string(mimeType),
            ]
        }
    }
}

public struct MCPToolResult: Sendable, Equatable {
    public let content: [MCPContent]
    /// A tool-level failure: the call was understood but could not be done
    /// (no such tab, Space not shared). Reported inside a normal result, as MCP
    /// asks, so the model sees the reason and can recover — a JSON-RPC error is
    /// for a malformed request.
    public let isError: Bool

    public init(content: [MCPContent], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    public static func text(_ text: String) -> MCPToolResult {
        MCPToolResult(content: [.text(text)])
    }

    public static func error(_ text: String) -> MCPToolResult {
        MCPToolResult(content: [.text(text)], isError: true)
    }
}

/// What the server exposes. The browser side implements it; this package never
/// sees a tab, a Space or a web view, only names and JSON.
public protocol MCPToolProvider: Sendable {
    func listTools() async -> [MCPTool]
    func callTool(name: String, arguments: [String: JSONValue]) async -> MCPToolResult
}

/// Turns one JSON-RPC message into its reply, per the Model Context Protocol.
///
/// Transport-free: the socket server feeds it lines and writes back whatever it
/// returns, and tests call it directly. A notification (no `id`) gets no reply,
/// which is why the result is optional.
public struct MCPProtocolHandler: Sendable {
    /// Newest first. A client asking for one of these gets it back; anything
    /// else gets the newest, and the client decides whether it can live with it.
    public static let supportedProtocolVersions = [
        "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05",
    ]

    let provider: any MCPToolProvider
    let serverName: String
    let serverVersion: String
    let instructions: String?

    public init(
        provider: any MCPToolProvider, serverName: String, serverVersion: String,
        instructions: String? = nil
    ) {
        self.provider = provider
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.instructions = instructions
    }

    enum ErrorCode {
        static let parse = -32700
        static let invalidRequest = -32600
        static let methodNotFound = -32601
        static let invalidParams = -32602
    }

    public func handle(_ line: Data) async -> Data? {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: line) else {
            return encode(errorReply(id: .null, code: ErrorCode.parse, message: "Parse error"))
        }
        guard case .object(let fields) = message,
              fields["jsonrpc"]?.stringValue == "2.0",
              let method = fields["method"]?.stringValue
        else {
            // A response from the client (to a request this server never
            // makes) or junk. Answer only if it carried an id to answer.
            if message["method"] == nil, message["result"] != nil || message["error"] != nil {
                return nil
            }
            return encode(errorReply(
                id: message["id"] ?? .null, code: ErrorCode.invalidRequest,
                message: "Invalid request"
            ))
        }

        let params = fields["params"]?.objectValue ?? [:]
        guard let id = fields["id"] else {
            // Notifications: `notifications/initialized`, `notifications/cancelled`.
            // Nothing to say back to either.
            return nil
        }

        let reply: JSONValue
        switch method {
        case "initialize":
            reply = resultReply(id: id, result: initializeResult(params))
        case "ping":
            reply = resultReply(id: id, result: [:])
        case "tools/list":
            let tools = await provider.listTools()
            reply = resultReply(id: id, result: ["tools": .array(tools.map(\.json))])
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                reply = errorReply(id: id, code: ErrorCode.invalidParams, message: "Missing tool name")
                break
            }
            let tools = await provider.listTools()
            guard tools.contains(where: { $0.name == name }) else {
                reply = errorReply(id: id, code: ErrorCode.invalidParams, message: "Unknown tool: \(name)")
                break
            }
            let arguments = params["arguments"]?.objectValue ?? [:]
            let result = await provider.callTool(name: name, arguments: arguments)
            reply = resultReply(id: id, result: [
                "content": .array(result.content.map(\.json)),
                "isError": .bool(result.isError),
            ])
        default:
            reply = errorReply(id: id, code: ErrorCode.methodNotFound, message: "Method not found: \(method)")
        }
        return encode(reply)
    }

    private func initializeResult(_ params: [String: JSONValue]) -> JSONValue {
        let requested = params["protocolVersion"]?.stringValue
        let version = requested.flatMap {
            Self.supportedProtocolVersions.contains($0) ? $0 : nil
        } ?? Self.supportedProtocolVersions[0]
        var result: [String: JSONValue] = [
            "protocolVersion": .string(version),
            // Tools only, and a fixed list: no `listChanged`, no resources,
            // no prompts, no sampling.
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": .string(serverName), "version": .string(serverVersion)],
        ]
        if let instructions { result["instructions"] = .string(instructions) }
        return .object(result)
    }

    private func resultReply(id: JSONValue, result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func errorReply(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }

    private func encode(_ value: JSONValue) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(value)
    }
}
