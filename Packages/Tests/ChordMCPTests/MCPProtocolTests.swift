import Foundation
import Testing

@testable import ChordMCP

/// A provider with one echo tool, so the protocol can be tested without a browser.
struct EchoProvider: MCPToolProvider {
    func listTools() async -> [MCPTool] {
        [MCPTool(
            name: "echo", title: "Echo", description: "Says it back",
            inputSchema: ["type": "object", "properties": ["text": ["type": "string"]]],
            readOnly: true
        )]
    }

    func callTool(name: String, arguments: [String: JSONValue]) async -> MCPToolResult {
        guard let text = arguments["text"]?.stringValue else { return .error("text is required") }
        return .text(text)
    }
}

func decode(_ data: Data?) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: try #require(data))
}

@Suite("MCP protocol handler")
struct MCPProtocolTests {
    let handler = MCPProtocolHandler(
        provider: EchoProvider(), serverName: "chord", serverVersion: "1.0",
        instructions: "be nice"
    )

    private func send(_ json: String) async throws -> JSONValue? {
        guard let reply = await handler.handle(Data(json.utf8)) else { return nil }
        return try decode(reply)
    }

    @Test("initialize echoes a supported protocol version and names the server")
    func initializeNegotiates() async throws {
        let reply = try #require(try await send(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}"#
        ))
        #expect(reply["id"] == 1)
        #expect(reply["result"]?["protocolVersion"] == "2025-06-18")
        #expect(reply["result"]?["serverInfo"]?["name"] == "chord")
        #expect(reply["result"]?["capabilities"]?["tools"] != nil)
        #expect(reply["result"]?["instructions"] == "be nice")
    }

    @Test("An unknown protocol version gets the newest one")
    func initializeFallsBack() async throws {
        let reply = try #require(try await send(
            #"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#
        ))
        #expect(reply["id"] == "a")
        #expect(reply["result"]?["protocolVersion"]
            == .string(MCPProtocolHandler.supportedProtocolVersions[0]))
    }

    @Test("Notifications and client responses get no reply")
    func notificationsAreSilent() async throws {
        #expect(try await send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(try await send(#"{"jsonrpc":"2.0","id":7,"result":{}}"#) == nil)
    }

    @Test("tools/list describes each tool with its read-only hint")
    func listsTools() async throws {
        let reply = try #require(try await send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        guard case .array(let tools) = reply["result"]?["tools"] else {
            Issue.record("no tools array")
            return
        }
        #expect(tools.count == 1)
        #expect(tools[0]["name"] == "echo")
        #expect(tools[0]["annotations"]?["readOnlyHint"] == true)
        #expect(tools[0]["inputSchema"]?["type"] == "object")
    }

    @Test("tools/call routes to the provider and wraps its content")
    func callsTool() async throws {
        let reply = try #require(try await send(
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}"#
        ))
        #expect(reply["result"]?["isError"] == false)
        #expect(reply["result"]?["content"] == [["type": "text", "text": "hi"]])
    }

    @Test("A tool failure is a result with isError, not a JSON-RPC error")
    func toolErrorIsAResult() async throws {
        let reply = try #require(try await send(
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"echo","arguments":{}}}"#
        ))
        #expect(reply["error"] == nil)
        #expect(reply["result"]?["isError"] == true)
    }

    @Test("Unknown tools, unknown methods and junk are JSON-RPC errors")
    func errors() async throws {
        let unknownTool = try #require(try await send(
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"rm_rf"}}"#
        ))
        #expect(unknownTool["error"]?["code"] == -32602)

        let unknownMethod = try #require(try await send(#"{"jsonrpc":"2.0","id":6,"method":"resources/list"}"#))
        #expect(unknownMethod["error"]?["code"] == -32601)

        let junk = try #require(try await send("not json"))
        #expect(junk["error"]?["code"] == -32700)
        #expect(junk["id"] == .null)

        let noVersion = try #require(try await send(#"{"id":8,"method":"ping"}"#))
        #expect(noVersion["error"]?["code"] == -32600)
    }

    @Test("Image content is base64 with its MIME type")
    func imageContent() {
        let json = MCPContent.image(Data([1, 2, 3]), mimeType: "image/png").json
        #expect(json["data"] == "AQID")
        #expect(json["mimeType"] == "image/png")
    }

    @Test("Whole-number ids encode as integers")
    func integerIDs() throws {
        let data = try JSONEncoder().encode(JSONValue.number(42))
        #expect(String(decoding: data, as: UTF8.self) == "42")
    }
}
