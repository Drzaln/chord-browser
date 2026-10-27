import Foundation

/// A website talking to an extension that lists it.
///
/// An extension's manifest can name websites under `externally_connectable`,
/// and those pages may send it messages: claude.ai hands Claude in Chrome its
/// sign-in that way, with `chrome.runtime.sendMessage(extensionId, …)`. WebKit
/// already does the work: it puts a `browser.runtime` in the page's own world,
/// and a listed page's message reaches the extension's
/// `runtime.onMessageExternal` with the page's origin and address as the
/// sender. What it does not do is name it `chrome`, the name every page
/// written for Chrome calls.
///
/// WebKit gives every page `browser` once any extension is loaded, so the name
/// cannot simply follow it: a `chrome` on every site would tell them all this
/// is Chrome. Only a page a loaded extension lists — by Chrome's match-pattern
/// rules — gets `chrome.runtime`, and only if it has no `chrome` of its own.
enum ExtensionExternal {
    /// The `externally_connectable` patterns of every loaded extension, those
    /// Chrome would take and no others, by Chrome id.
    nonisolated static func listings(
        from manifests: [(id: String, manifest: [String: Any])]
    ) -> [String: [String]] {
        var found: [String: [String]] = [:]
        for entry in manifests {
            guard let external = entry.manifest["externally_connectable"] as? [String: Any],
                  let matches = external["matches"] as? [String]
            else { continue }
            let patterns = matches.filter(allowed)
            if !patterns.isEmpty {
                found[entry.id] = Array(Set(patterns)).sorted()
            }
        }
        return found
    }

    /// Chrome refuses a pattern for every site (`*://*/*`) and a wildcard over
    /// a whole top-level domain (`*.com`): a wildcard needs a domain with a dot
    /// in it. Google's sites are left out too — a page there with a partial
    /// `chrome` and a Safari name is what its sign-in and reCAPTCHA look for to
    /// turn a browser away.
    nonisolated static func allowed(_ pattern: String) -> Bool {
        guard let start = pattern.range(of: "://") else { return false }
        let scheme = pattern[..<start.lowerBound]
        guard ["*", "http", "https"].contains(scheme) else { return false }
        let rest = pattern[start.upperBound...]
        var host = String(rest.prefix { $0 != "/" }).lowercased()
        guard rest.dropFirst(host.count).hasPrefix("/") else { return false }
        if let colon = host.lastIndex(of: ":"), !host.hasSuffix("]") {
            host = String(host[..<colon])
        }
        guard host != "*", !host.isEmpty else { return false }
        if host.hasPrefix("*.") {
            let base = host.dropFirst(2)
            guard base.contains("."), !base.contains("*") else { return false }
        } else if host.contains("*") {
            return false
        }
        let labels = host.split(separator: ".")
        return !labels.dropLast().contains("google")
    }

    /// The page-world bootstrap for the listings, or nil when nothing lists a
    /// page. Injected at document start so a page can call it from its first
    /// script.
    nonisolated static func script(for listings: [String: [String]]) -> String? {
        guard !listings.isEmpty,
              let data = try? JSONSerialization.data(
                withJSONObject: listings, options: .sortedKeys
              ),
              let list = String(data: data, encoding: .utf8)
        else { return nil }
        return """
            (function (listings) {
              var made = window.browser, runtime = made && made.runtime;
              if (typeof window.chrome !== 'undefined' || !runtime
                  || typeof runtime.sendMessage !== 'function') return;
              // Chrome's match patterns: scheme, host, then path. A host with
              // a port matches that port only; one without, any.
              var glob = function (text) {
                return new RegExp('^' + text.replace(/[.+?^${}()|[\\]\\\\]/g, '\\\\$&')
                  .replace(/\\*/g, '.*') + '$');
              };
              var listed = function (pattern) {
                var parts = /^(\\*|https?):\\/\\/([^\\/]+)(\\/.*)$/.exec(pattern);
                if (!parts) return false;
                var scheme = location.protocol.slice(0, -1);
                if (parts[1] === '*' ? scheme !== 'http' && scheme !== 'https'
                    : parts[1] !== scheme) return false;
                var host = parts[2], port = '';
                var colon = host.lastIndexOf(':');
                if (colon > 0 && host.indexOf(']') < colon) {
                  port = host.slice(colon + 1); host = host.slice(0, colon);
                }
                if (port && port !== '*' && port !== location.port) return false;
                var here = location.hostname;
                if (host.indexOf('*.') === 0) {
                  var base = host.slice(2);
                  if (base.indexOf('.') < 0) return false;
                  if (here !== base && here.slice(-base.length - 1) !== '.' + base) return false;
                } else if (host !== here) return false;
                return glob(parts[3]).test(location.pathname + location.search);
              };
              var reached = Object.keys(listings).filter(function (id) {
                return listings[id].some(listed);
              });
              if (!reached.length) return;
              var chromeRuntime = {
                sendMessage: function (id, message, options, callback) {
                  if (typeof options === 'function') {
                    callback = options; options = undefined;
                  }
                  var sent = reached.indexOf(id) < 0
                    ? Promise.reject(new Error(
                        'Could not establish connection. Receiving end does not exist.'))
                    : options === undefined
                      ? runtime.sendMessage(id, message)
                      : runtime.sendMessage(id, message, options);
                  if (typeof callback !== 'function') return sent;
                  Promise.resolve(sent).then(function (reply) {
                    callback(reply);
                  }, function (error) {
                    chromeRuntime.lastError = {
                      message: String(error && error.message || error)
                    };
                    try { callback(); } finally { delete chromeRuntime.lastError; }
                  });
                }
              };
              if (typeof runtime.connect === 'function') {
                chromeRuntime.connect = function () {
                  return runtime.connect.apply(runtime, arguments);
                };
              }
              try {
                Object.defineProperty(window, 'chrome', {
                  value: { runtime: chromeRuntime },
                  configurable: true, writable: true, enumerable: false
                });
              } catch (e) {}
            })(\(list));
            """
    }
}
