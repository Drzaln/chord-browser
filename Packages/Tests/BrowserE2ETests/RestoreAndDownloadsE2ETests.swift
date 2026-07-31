import BrowserCore
import BrowserStore
import BrowserTestSupport
import Foundation
import Testing

/// M4 end to end: real `WKWebView`, real SQLite, real HTTP.
///
/// These are the tests that catch wiring the unit tests cannot see — that the
/// blob WebKit actually produces survives a round trip through SQLite and
/// restores into a *different* web view in a *different* store.
@Suite("E2E: session restore")
@MainActor
struct SessionRestoreE2ETests {

    /// The M4 done-when: quit and relaunch restores everything.
    ///
    /// Back/forward history is the observable proof. A pane restored from
    /// `interactionState` can go back; one that merely reloaded its URL cannot,
    /// and no assertion about the URL alone could tell the two apart.
    @Test("A tab's history survives quit and relaunch")
    func historySurvivesRelaunch() async throws {
        let harness = try await E2EHarness.make(routes: [
            .page(path: "/one", title: "One"),
            .page(path: "/two", title: "Two"),
        ])
        defer { Task { await harness.tearDown() } }

        let store = harness.store
        await store.restore()
        #expect(await harness.openAndLoad(await harness.server.url("/one")))

        let tab = try #require(store.selectedTab)
        let paneID = tab.focusedPaneID

        // A second page, so there is a back entry to restore.
        store.navigate(to: await harness.server.url("/two"))
        #expect(
            await harness.wait {
                store.runtime(for: paneID).canGoBack
                    && !store.runtime(for: paneID).isLoading
            }
        )

        // Quit.
        await store.flushInteractionState()
        await store.flushSaveAndWait()

        // Relaunch: a brand-new store, engine, and web view over the same files.
        let relaunched = try harness.relaunch()
        await relaunched.restore()

        // Restore is lazy — the tabs are back in the model with nothing running.
        // (Two: the blank tab an empty profile opens with, plus ours.)
        #expect(relaunched.tabs.count == 2)
        #expect(relaunched.liveWebViewCount == 0)

        let restoredTab = try #require(
            relaunched.tabs.first { $0.focusedPane.url.path().hasSuffix("two") }
        )
        relaunched.select(restoredTab.id)

        // The surface is withheld until the stored blob has been read.
        var surface: AnyObject?
        _ = await harness.wait {
            if let made = relaunched.surface(for: restoredTab) {
                surface = made as AnyObject
                return true
            }
            return false
        }
        #expect(surface != nil)

        let restoredPaneID = restoredTab.focusedPaneID
        let cameBack = await harness.wait {
            relaunched.runtime(for: restoredPaneID).canGoBack
        }
        // Only a pane restored from interactionState has a back entry.
        #expect(cameBack)

        relaunched.stopSweep()
    }

    @Test("A tab switched away from is persisted, not just an evicted one")
    func capturesOnPlainSwitch() async throws {
        let harness = try await E2EHarness.make(routes: [
            .page(path: "/a", title: "A"),
            .page(path: "/b", title: "B"),
        ])
        defer { Task { await harness.tearDown() } }

        let store = harness.store
        await store.restore()
        #expect(await harness.openAndLoad(await harness.server.url("/a")))
        let first = try #require(store.selectedTab)

        #expect(await harness.openAndLoad(await harness.server.url("/b")))

        // Switching back and forth is the whole trigger — nothing is evicted
        // here, and before M4 that meant nothing was written.
        store.select(first.id)
        _ = await harness.wait { store.selectedTabID == first.id }

        let second = try #require(store.tabs.last)
        store.select(second.id)

        await store.flushSaveAndWait()

        let relaunched = try harness.relaunch()
        await relaunched.restore()
        // Three: the blank tab an empty profile opens with, plus both of ours.
        #expect(relaunched.tabs.count == 3)
        #expect(relaunched.liveWebViewCount == 0)

        relaunched.stopSweep()
    }
}

@Suite("E2E: downloads")
@MainActor
struct DownloadsE2ETests {

    /// Exercises the real `WKDownloadDelegate` path: response policy turns the
    /// navigation into a download, `didBecome` hands over the `WKDownload`, and
    /// the destination callback writes a real file.
    @Test("A non-renderable response downloads to disk")
    func downloadsAttachment() async throws {
        let payload = String(repeating: "browser", count: 500)
        let harness = try await E2EHarness.make(routes: [
            .page(path: "/", title: "Home"),
            TestHTTPServer.attachment(path: "/file.bin", filename: "file.bin", body: payload),
        ])
        defer { Task { await harness.tearDown() } }

        let store = harness.store
        await store.restore()
        #expect(await harness.openAndLoad(await harness.server.url("/")))

        store.navigate(to: await harness.server.url("/file.bin"))

        let finished = await harness.wait(timeout: .seconds(15)) {
            harness.downloads.downloads.contains { $0.state == .finished }
        }
        #expect(finished)

        let item = try #require(harness.downloads.downloads.first)
        #expect(item.filename == "file.bin")

        let destination = try #require(item.destination)
        #expect(FileManager.default.fileExists(atPath: destination.path))

        let written = try String(contentsOf: destination, encoding: .utf8)
        #expect(written == payload)

        store.stopSweep()
    }

    @Test("A second download of the same name does not overwrite the first")
    func doesNotOverwrite() async throws {
        let harness = try await E2EHarness.make(routes: [
            .page(path: "/", title: "Home"),
            TestHTTPServer.attachment(path: "/dup.bin", filename: "dup.bin", body: "first"),
        ])
        defer { Task { await harness.tearDown() } }

        let store = harness.store
        await store.restore()
        #expect(await harness.openAndLoad(await harness.server.url("/")))

        for _ in 0..<2 {
            store.navigate(to: await harness.server.url("/dup.bin"))
            _ = await harness.wait(timeout: .seconds(15)) {
                harness.downloads.downloads.filter { $0.state == .finished }.count
                    == harness.downloads.downloads.count
                    && !harness.downloads.downloads.isEmpty
            }
        }

        let finished = await harness.wait(timeout: .seconds(15)) {
            harness.downloads.downloads.filter { $0.state == .finished }.count == 2
        }
        #expect(finished)

        let names = Set(harness.downloads.downloads.compactMap(\.destination).map(\.lastPathComponent))
        // WebKit refuses a destination that already exists, so a collision that
        // was not resolved would fail the download outright.
        #expect(names == ["dup.bin", "dup-1.bin"])

        store.stopSweep()
    }

    /// The ⌘-hover Peek preview must never write a file.
    ///
    /// Found live before this test existed: hovering a link to a binary
    /// downloaded it — three hovers, three files in the container's Downloads
    /// folder, no click anywhere. A hover cannot consent to a download.
    @Test("A preview pane cancels a download instead of writing it")
    func previewPaneNeverDownloads() async throws {
        let harness = try await E2EHarness.make(routes: [
            .page(path: "/", title: "Home"),
            TestHTTPServer.attachment(path: "/peek.bin", filename: "peek.bin", body: "payload"),
        ])
        defer { Task { await harness.tearDown() } }

        let store = harness.store
        await store.restore()

        // Exactly what PeekController does: a pane in no tab, marked preview,
        // pointed at the link under the pointer.
        let pane = store.makeLittleArcPane(url: await harness.server.url("/peek.bin"))
        _ = store.peekSurface(for: pane)

        // Long enough that a 7-byte file would have finished several times over.
        let downloaded = await harness.wait(timeout: .seconds(6)) {
            !harness.downloads.downloads.isEmpty
        }
        #expect(downloaded == false, "a hover must not start a download")
        #expect(
            (try? FileManager.default.contentsOfDirectory(
                atPath: harness.downloadsDirectory.path
            ).isEmpty) ?? true,
            "and must not write a file"
        )

        store.discardLittleArc(pane)
        store.stopSweep()
    }

    @Test("A normal pane still downloads — the guard is not a blanket ban")
    func normalPaneStillDownloads() async throws {
        let harness = try await E2EHarness.make(routes: [
            .page(path: "/", title: "Home"),
            TestHTTPServer.attachment(path: "/keep.bin", filename: "keep.bin", body: "payload"),
        ])
        defer { Task { await harness.tearDown() } }

        let store = harness.store
        await store.restore()
        #expect(await harness.openAndLoad(await harness.server.url("/")))
        store.navigate(to: await harness.server.url("/keep.bin"))

        let finished = await harness.wait(timeout: .seconds(15)) {
            harness.downloads.downloads.contains { $0.state == .finished }
        }
        #expect(finished, "the preview guard must not have disabled downloads at large")

        store.stopSweep()
    }
}
