import ChordCore
import Foundation
import Testing

/// Arc's `StorableSidebar.json` is undocumented, so these tests build the
/// shapes Arc writes and the damaged shapes a real file can arrive in: missing
/// arrays, unknown keys, cycles, and non-web URLs.
@Suite("Arc import parser")
struct ArcImportTests {

    // MARK: - Fixture

    private struct Fixture {
        var items: [[String: Any]] = []

        mutating func tab(_ id: String, _ url: String, title: String? = nil) {
            items.append([
                "id": id,
                "title": title ?? "",
                "data": [
                    "tab": ["savedURL": url, "savedTitle": title ?? ""]
                ],
            ])
        }

        mutating func tabWithoutURL(_ id: String, title: String) {
            items.append([
                "id": id,
                "title": title,
                "data": ["tab": ["savedTitle": title]],
            ])
        }

        mutating func folder(_ id: String, _ title: String, children: [String]) {
            items.append([
                "id": id,
                "title": title,
                "childrenIds": children,
                "data": ["list": [String: Any]()],
            ])
        }

        /// A container whose `data` carries no `list` marker — Arc has written
        /// both, so the parser must key on `childrenIds` instead.
        mutating func container(_ id: String, children: [String]) {
            items.append([
                "id": id,
                "childrenIds": children,
                "data": [String: Any](),
            ])
        }

        func json(spaces: [Any], topApps: [[Any]] = []) -> Data {
            let main: [String: Any] = [
                "items": items,
                "spaces": spaces,
                "topAppsContainerIDs": topApps.flatMap { $0 },
                "unknownFutureKey": ["ignored": true],
            ]
            let top: [String: Any] = [
                "sidebar": ["containers": [main]],
                "version": 12345,
            ]
            return (try? JSONSerialization.data(withJSONObject: top)) ?? Data()
        }
    }

    private func space(
        id: String,
        title: String,
        pinned: String,
        profile: [String: Any] = ["default": [String: Any]()],
        emoji: String? = nil,
        stringLabels: Bool = false
    ) -> [String: Any] {
        let newContainers: [Any] = stringLabels
            ? ["pinned", pinned, "unpinned", "unpinned-\(id)"]
            : [
                ["pinned": [String: Any]()],
                pinned,
                ["unpinned": [String: Any]()],
                "unpinned-\(id)",
            ]
        var value: [String: Any] = [
            "id": id,
            "title": title,
            "profile": profile,
            "newContainerIDs": newContainers,
        ]
        if let emoji {
            value["customInfo"] = ["iconType": ["emoji_v2": emoji]]
        }
        return value
    }

    private func customProfile(_ name: String) -> [String: Any] {
        ["custom": ["_0": ["directoryBasename": name]]]
    }

    private func topApps(profile: String?, container: String) -> [Any] {
        guard let profile else {
            return [["default": [String: Any]()], container]
        }
        return [
            ["custom": ["_0": ["directoryBasename": profile]]] as [String: Any],
            container,
        ]
    }

    // MARK: - The happy path

    @Test("Spaces, pins, folders and favourites come through in order")
    func parsesRealSidebarShape() throws {
        var fixture = Fixture()
        fixture.container("work-pinned", children: [
            "pin-docs", "reading-folder", "empty-folder",
        ])
        fixture.tab("pin-docs", "https://docs.example/start", title: "Docs")
        fixture.folder("reading-folder", "Reading", children: [
            "pin-article", "deep-folder",
        ])
        fixture.folder("deep-folder", "Deep", children: ["pin-deep"])
        fixture.folder("empty-folder", "Empty", children: [])
        fixture.tab("pin-article", "https://articles.example/one", title: "An Article")
        fixture.tab("pin-deep", "https://deep.example/", title: "Deep Page")

        fixture.container("personal-pinned", children: ["pin-news"])
        fixture.tab("pin-news", "https://news.example/", title: "News")

        fixture.container("favs", children: ["fav-gmail", "fav-folder"])
        fixture.tab("fav-gmail", "https://mail.example/", title: "Mail")
        fixture.folder("fav-folder", "Tools", children: ["fav-figma"])
        fixture.tab("fav-figma", "https://figma.example/", title: "Figma")

        let data = fixture.json(
            spaces: [
                space(id: "work", title: "Work", pinned: "work-pinned", emoji: "💼"),
                space(id: "personal", title: "Personal", pinned: "personal-pinned"),
            ],
            topApps: [topApps(profile: nil, container: "favs")]
        )

        let plan = try #require(ArcSidebarParser.parse(data))
        #expect(plan.spaceCount == 2)
        #expect(plan.spaces.map(\.name) == ["Work", "Personal"])
        #expect(plan.spaces[0].icon == "💼")
        #expect(plan.spaces[1].icon == nil)

        let work = plan.spaces[0]
        #expect(work.pinned.map(\.url.absoluteString) == [
            "https://docs.example/start",
            "https://articles.example/one",
            "https://deep.example/",
        ])
        #expect(work.pinned.map(\.title) == ["Docs", "An Article", "Deep Page"])
        #expect(work.pinned[0].folderPath.isEmpty)
        #expect(work.pinned[1].folderPath == ["Reading"])
        #expect(work.pinned[2].folderPath == ["Reading", "Deep"])
        #expect(work.folders.map(\.displayName) == [
            "Reading", "Reading / Deep", "Empty",
        ])
        #expect(work.itemCount == 5)
        #expect(work.flattenedFolderCount == 1)

        // Top apps share Arc's profile, so both Spaces get them; a folder in
        // the top-apps container is flattened into the favourites grid.
        #expect(work.favourites.map(\.title) == ["Mail", "Figma"])
        #expect(work.favourites.allSatisfy { $0.folderPath.isEmpty })
        #expect(plan.spaces[1].favourites.count == 2)

        #expect(plan.pinnedCount == 4)
        #expect(plan.favouriteCount == 4)
        #expect(plan.folderCount == 3)
        #expect(plan.skippedCount == 0)
        #expect(!plan.depthLimitReached)
        #expect(!plan.itemLimitReached)
    }

    @Test("A Space with only a title still imports, with no tabs or folders")
    func toleratesMissingContainers() throws {
        var fixture = Fixture()
        fixture.tab("orphan", "https://orphan.example/")

        let data = fixture.json(spaces: [
            ["id": "bare", "title": "Bare"],
            ["id": "bad-types", "title": "Bad", "newContainerIDs": 42],
        ])
        let plan = try #require(ArcSidebarParser.parse(data))
        #expect(plan.spaces.map(\.name) == ["Bare", "Bad"])
        #expect(plan.spaces.allSatisfy { $0.pinned.isEmpty && $0.folders.isEmpty })
        #expect(plan.spaces.allSatisfy { $0.favourites.isEmpty })
    }

    @Test("Unreadable and non-Arc files are refused, never half-parsed")
    func refusesNonArcFiles() {
        #expect(ArcSidebarParser.parse(Data("not json".utf8)) == nil)
        #expect(ArcSidebarParser.parse(Data()) == nil)
        #expect(ArcSidebarParser.parse(Data("{}".utf8)) == nil)
        #expect(ArcSidebarParser.parse(Data(#"{"sidebar":{}}"#.utf8)) == nil)
        #expect(ArcSidebarParser.parse(
            Data(#"{"sidebar":{"containers":[]}}"#.utf8)
        ) == nil)
        #expect(ArcSidebarParser.parse(
            Data(#"{"sidebar":{"containers":[{"items":[]}]}}"#.utf8)
        ) != nil)
    }

    @Test("JSON with arrays of the wrong type is tolerated")
    func toleratesWrongArrayTypes() throws {
        let data = Data(#"""
        {
          "sidebar": {
            "containers": [
              {
                "items": "not an array",
                "spaces": [
                  {
                    "id": "s1",
                    "title": "Odd",
                    "newContainerIDs": {"pinned": "not-an-array"}
                  }
                ],
                "topAppsContainerIDs": 7
              }
            ]
          }
        }
        """#.utf8)
        let plan = try #require(ArcSidebarParser.parse(data))
        #expect(plan.spaceCount == 1)
        #expect(plan.spaces[0].name == "Odd")
        #expect(plan.spaces[0].itemCount == 0)
    }

    // MARK: - URL filtering

    @Test("Only http(s) pages import; every other scheme is reported")
    func dropsNonWebSchemes() throws {
        var fixture = Fixture()
        fixture.container("pinned", children: [
            "ok", "arc", "extension", "file", "script", "data", "broken", "missing",
        ])
        fixture.tab("ok", "https://kept.example/", title: "Kept")
        fixture.tab("arc", "arc://space/123")
        fixture.tab("extension", "chrome-extension://abcdef/page.html")
        fixture.tab("file", "file:///etc/passwd")
        fixture.tab("script", "javascript:alert(1)")
        fixture.tab("data", "data:text/html,hello")
        fixture.tab("broken", "http://")
        fixture.tabWithoutURL("missing", title: "No URL")

        let data = fixture.json(spaces: [
            space(id: "s", title: "S", pinned: "pinned"),
        ])
        let plan = try #require(ArcSidebarParser.parse(data))
        #expect(plan.pinnedCount == 1)
        #expect(plan.spaces[0].pinned[0].url.absoluteString == "https://kept.example/")
        #expect(plan.skippedCount(for: .unsupportedScheme) == 5)
        #expect(plan.skippedCount(for: .invalidURL) == 1)
        #expect(plan.skippedCount(for: .missingURL) == 1)
        #expect(plan.skippedCount == 7)
        #expect(plan.spaces[0].pinned.count == 1)
    }

    @Test("Credentials embedded in an Arc URL are stripped")
    func stripsCredentials() throws {
        var fixture = Fixture()
        fixture.container("pinned", children: ["one", "two"])
        fixture.tab("one", "https://alice:secret@example.com/inbox")
        fixture.tab("two", "https://example.com/clean")

        let data = fixture.json(spaces: [
            space(id: "s", title: "S", pinned: "pinned"),
        ])
        let plan = try #require(ArcSidebarParser.parse(data))
        #expect(plan.spaces[0].pinned.map(\.url.absoluteString) == [
            "https://example.com/inbox",
            "https://example.com/clean",
        ])
        #expect(plan.credentialsStripped == 1)
    }

    @Test("Folders that flatten to the same name are counted as merged")
    func reportsMergedFolders() throws {
        var fixture = Fixture()
        fixture.container("pinned", children: ["a", "b", "other"])
        fixture.folder("a", "Folder", children: ["t1"])
        fixture.folder("b", "Folder", children: ["t2"])
        fixture.folder("other", "Other", children: ["nested"])
        fixture.folder("nested", "Folder", children: ["t3"])
        fixture.tab("t1", "https://one.example/")
        fixture.tab("t2", "https://two.example/")
        fixture.tab("t3", "https://three.example/")

        let data = fixture.json(spaces: [
            space(id: "s", title: "S", pinned: "pinned"),
        ])
        let plan = try #require(ArcSidebarParser.parse(data))
        #expect(plan.spaces[0].folders.map(\.displayName) == [
            "Folder", "Folder", "Other", "Other / Folder",
        ])
        #expect(plan.mergedFolderCount == 1)
        #expect(plan.flattenedFolderCount == 1)
    }

    // MARK: - Damaged graphs

    @Test("Folder nesting is capped, and hitting the cap is reported")
    func capsFolderDepth() throws {
        var fixture = Fixture()
        fixture.container("pinned", children: ["f0"])
        for index in 0..<70 {
            let child = index == 69 ? "leaf" : "f\(index + 1)"
            fixture.folder("f\(index)", "F\(index)", children: [child])
        }
        fixture.tab("leaf", "https://too-deep.example/")

        let data = fixture.json(spaces: [
            space(id: "s", title: "S", pinned: "pinned"),
        ])
        let plan = try #require(ArcSidebarParser.parse(data))
        let imported = plan.spaces[0]
        #expect(imported.folders.count == ArcSidebarParser.maximumFolderDepth)
        #expect(imported.folders.last?.displayName.hasSuffix("/ F63") == true)
        #expect(imported.pinned.isEmpty)
        #expect(plan.depthLimitReached)
    }

    @Test("A cyclic childrenIds graph terminates and imports each item once")
    func survivesCycles() throws {
        var fixture = Fixture()
        fixture.container("pinned", children: ["folder-a", "tab-1"])
        fixture.folder("folder-a", "Folder A", children: [
            "folder-a", "tab-1", "folder-b",
        ])
        fixture.folder("folder-b", "Folder B", children: ["folder-a", "tab-2"])
        fixture.tab("tab-1", "https://one.example/")
        fixture.tab("tab-2", "https://two.example/")

        let data = fixture.json(spaces: [
            space(id: "s", title: "S", pinned: "pinned"),
        ])
        let plan = try #require(ArcSidebarParser.parse(data))
        let imported = plan.spaces[0]
        #expect(imported.folders.map(\.displayName) == [
            "Folder A", "Folder A / Folder B",
        ])
        #expect(imported.pinned.map(\.url.absoluteString) == [
            "https://one.example/", "https://two.example/",
        ])
        #expect(!plan.itemLimitReached)
    }

    @Test("A pathological item list stops at the ceiling instead of growing")
    func capsItemCount() throws {
        var fixture = Fixture()
        let ids = (0...ArcSidebarParser.maximumItemCount).map { "t\($0)" }
        fixture.container("pinned", children: ids)
        for (index, id) in ids.enumerated() {
            fixture.tab(id, "https://item\(index).example/")
        }

        let data = fixture.json(spaces: [
            space(id: "s", title: "S", pinned: "pinned"),
        ])
        let plan = try #require(ArcSidebarParser.parse(data))
        #expect(plan.spaces[0].pinned.count == ArcSidebarParser.maximumItemCount)
        #expect(plan.itemLimitReached)
    }

    // MARK: - Profiles and container spellings

    @Test("Each Space gets the top apps of its own Arc profile")
    func mapsFavouritesByProfile() throws {
        var fixture = Fixture()
        fixture.container("work-pinned", children: [])
        fixture.container("personal-pinned", children: [])
        fixture.container("fav-default", children: ["fav-personal"])
        fixture.tab("fav-personal", "https://personal.example/", title: "Personal App")
        fixture.container("fav-profile", children: ["fav-work"])
        fixture.tab("fav-work", "https://work.example/", title: "Work App")

        let data = fixture.json(
            spaces: [
                space(
                    id: "work", title: "Work", pinned: "work-pinned",
                    profile: customProfile("Profile 1")
                ),
                space(id: "personal", title: "Personal", pinned: "personal-pinned"),
            ],
            topApps: [
                topApps(profile: nil, container: "fav-default"),
                topApps(profile: "Profile 1", container: "fav-profile"),
            ]
        )
        let plan = try #require(ArcSidebarParser.parse(data))
        #expect(plan.spaces[0].favourites.map(\.title) == ["Work App"])
        #expect(plan.spaces[1].favourites.map(\.title) == ["Personal App"])
    }

    @Test("A bare favicon container id is treated as Default's top apps")
    func acceptsBareTopAppsContainer() throws {
        var fixture = Fixture()
        fixture.container("pinned", children: [])
        fixture.container("favs", children: ["fav"])
        fixture.tab("fav", "https://app.example/", title: "App")

        let data = fixture.json(
            spaces: [space(id: "s", title: "S", pinned: "pinned")],
            topApps: [["favs"]]
        )
        let plan = try #require(ArcSidebarParser.parse(data))
        #expect(plan.spaces[0].favourites.map(\.title) == ["App"])
    }

    @Test("Old string labels and new object labels for containers both work")
    func acceptsBothContainerLabelSpellings() throws {
        var fixture = Fixture()
        fixture.container("old-pinned", children: ["old-tab"])
        fixture.container("new-pinned", children: ["new-tab"])
        fixture.tab("old-tab", "https://old.example/")
        fixture.tab("new-tab", "https://new.example/")

        let data = fixture.json(spaces: [
            space(
                id: "old", title: "Old", pinned: "old-pinned", stringLabels: true
            ),
            space(id: "new", title: "New", pinned: "new-pinned"),
        ])
        let plan = try #require(ArcSidebarParser.parse(data))
        #expect(plan.spaces[0].pinned.map(\.url.absoluteString) == [
            "https://old.example/",
        ])
        #expect(plan.spaces[1].pinned.map(\.url.absoluteString) == [
            "https://new.example/",
        ])
    }

    @Test("An item's id may come from the string before it, not only its body")
    func acceptsAlternatingItemIDs() throws {
        let data = Data(#"""
        {
          "sidebar": {
            "containers": [
              {
                "items": [
                  "pinned-container",
                  { "childrenIds": ["group", "tab"] },
                  "group",
                  { "title": "Group", "childrenIds": ["tab"] },
                  "tab",
                  {
                    "title": "Alt",
                    "data": { "tab": { "savedURL": "https://alt.example/" } }
                  }
                ],
                "spaces": [
                  "space-id",
                  {
                    "id": "space-id",
                    "title": "Alt Space",
                    "newContainerIDs": ["pinned", "pinned-container"]
                  }
                ]
              }
            ]
          }
        }
        """#.utf8)

        let plan = try #require(ArcSidebarParser.parse(data))
        #expect(plan.spaces[0].name == "Alt Space")
        #expect(plan.spaces[0].folders.map(\.displayName) == ["Group"])
        #expect(plan.spaces[0].pinned.map(\.url.absoluteString) == [
            "https://alt.example/",
        ])
        #expect(plan.spaces[0].pinned[0].folderPath == ["Group"])
    }
}
