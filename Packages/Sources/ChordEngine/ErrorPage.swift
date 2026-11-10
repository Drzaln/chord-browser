import Foundation
import WebKit

/// The page shown when a navigation fails before anything of the site loaded:
/// a wrong domain, a refused connection, a timeout, a certificate that does
/// not hold.
///
/// Served through a private `chord-error://` scheme, like the offline game
/// (`OfflineGamePage`), so it never touches the failed site's origin. Unlike
/// the game, the engine reports the pane as being *at the failed URL*
/// (`WebKitEngine.handleSnapshot`): the address field keeps what the user
/// asked for, the session saves that and not this page, and a reload retries
/// it. The snapshot is marked `loadFailed` so nothing is written to history.
enum ErrorPage {
    static let scheme = "chord-error"
    static let host = "load-failed"

    /// What went wrong, as far as the page words it.
    enum Kind: Equatable {
        case cannotFindHost
        case cannotConnect
        case timedOut
        case notSecure
        case tooManyRedirects
        case other
    }

    // MARK: - Which failures get the page

    /// The failed URL to show the page for, or nil when this failure is not
    /// one to put a page in front of the user for.
    ///
    /// Only `NSURLErrorDomain`, and only for an http(s) address. WebKit's own
    /// domain reports things that are not failures to the user (102 "Frame
    /// load interrupted" is a navigation that became a download), a cancelled
    /// load is the user clicking something else, and a failed `zoommtg:` or
    /// `mailto:` link must leave the page it was clicked on alone.
    static func failedURL(for error: Error, webViewURL: URL?) -> URL? {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain, nsError.code != NSURLErrorCancelled else { return nil }
        // The error's own failing URL first: for a load that never committed,
        // the web view is still at the previous page.
        let failed = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webViewURL
        guard let failed, isWebURL(failed) else { return nil }
        return failed
    }

    static func kind(forCode code: Int) -> Kind {
        switch code {
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return .cannotFindHost
        case NSURLErrorCannotConnectToHost:
            return .cannotConnect
        case NSURLErrorTimedOut:
            return .timedOut
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
            NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
            NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
            NSURLErrorClientCertificateRequired:
            return .notSecure
        case NSURLErrorHTTPTooManyRedirects:
            return .tooManyRedirects
        default:
            return .other
        }
    }

    // MARK: - URL

    static func url(target: URL, code: Int) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [
            URLQueryItem(name: "url", value: target.absoluteString),
            URLQueryItem(name: "code", value: String(code)),
        ]
        // scheme + host are both set, so `url` is always non-nil.
        return components.url!
    }

    static func isErrorPage(_ url: URL?) -> Bool {
        url?.scheme == scheme
    }

    /// The failed URL an error-page URL stands in for. Only ever an http(s)
    /// address: a page that navigates itself to `chord-error://` cannot make
    /// Retry open anything else.
    static func targetURL(from url: URL) -> URL? {
        guard url.scheme == scheme else { return nil }
        let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "url" }?
            .value
            .flatMap(URL.init(string:))
        guard let target, isWebURL(target) else { return nil }
        return target
    }

    static func code(from url: URL) -> Int {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "code" }?
            .value
            .flatMap(Int.init) ?? NSURLErrorUnknown
    }

    private static func isWebURL(_ url: URL) -> Bool {
        url.scheme == "http" || url.scheme == "https"
    }

    // MARK: - Page

    static func headline(for kind: Kind, host: String) -> String {
        switch kind {
        case .cannotFindHost: return "Chord can’t find \(host)"
        case .cannotConnect: return "Chord can’t connect to \(host)"
        case .timedOut: return "\(host) took too long to respond"
        case .notSecure: return "This connection is not private"
        case .tooManyRedirects: return "\(host) redirected too many times"
        case .other: return "Chord can’t open this page"
        }
    }

    static func detail(for kind: Kind, host: String) -> String {
        switch kind {
        case .cannotFindHost:
            return "No server answers to that name. Check the address for a typing mistake."
        case .cannotConnect:
            return "The server refused the connection or is not running."
        case .timedOut:
            return "The server may be busy or down, or your connection may be slow."
        case .notSecure:
            return "Chord could not make a secure connection to \(host), or could not confirm that "
                + "the site is really \(host). Nothing was sent."
        case .tooManyRedirects:
            return "The site keeps sending the browser somewhere else. Clearing its cookies in "
                + "Settings can fix this."
        case .other:
            return "Something went wrong while loading \(host)."
        }
    }

    /// The self-contained page: no external resources, no storage, one script
    /// for the Retry button. The page's title is the host, which is what the
    /// tab then shows.
    static func html(target: URL?, code: Int) -> String {
        let kind = kind(forCode: code)
        let host = target?.host() ?? "this page"
        return template
            .replacingOccurrences(of: "__TITLE__", with: escape(host))
            .replacingOccurrences(of: "__HEADLINE__", with: escape(headline(for: kind, host: host)))
            .replacingOccurrences(of: "__DETAIL__", with: escape(detail(for: kind, host: host)))
            .replacingOccurrences(of: "__CODE__", with: String(code))
            // Last, so nothing in the URL can be mistaken for a placeholder.
            .replacingOccurrences(
                of: "__TARGET__", with: target.map { jsonString($0.absoluteString) } ?? "null")
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// A JSON string literal, safe inside `<script>`: `JSONEncoder` writes `/`
    /// as `\/`, so the text can never close the element.
    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
            let encoded = String(data: data, encoding: .utf8)
        else { return "null" }
        return encoded
    }

    private static let template = #"""
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>__TITLE__</title>
        <style>
          :root {
            color-scheme: light dark;
            --bg: #f7f7f7; --fg: #2c2c2e; --muted: #7c7c82; --line: #d9d9d9;
            --button: #2c2c2e; --button-fg: #ffffff;
          }
          @media (prefers-color-scheme: dark) {
            :root {
              --bg: #1b1b1f; --fg: #e6e6ea; --muted: #9a9aa2; --line: #33333a;
              --button: #e6e6ea; --button-fg: #1b1b1f;
            }
          }
          html, body { height: 100%; margin: 0; }
          body {
            background: var(--bg); color: var(--fg);
            font: 15px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
            display: flex; align-items: center; justify-content: center;
          }
          main { max-width: 440px; padding: 32px; }
          h1 { font-size: 22px; line-height: 1.25; font-weight: 600; margin: 0 0 10px; overflow-wrap: anywhere; }
          p { margin: 0 0 22px; color: var(--muted); }
          button {
            font: inherit; font-weight: 500; padding: 7px 16px; border-radius: 8px; border: 0;
            background: var(--button); color: var(--button-fg); cursor: pointer;
          }
          button:focus-visible { outline: 3px solid Highlight; outline-offset: 2px; }
          small { display: block; margin-top: 26px; color: var(--muted); font-size: 11px; }
        </style>
        </head>
        <body>
        <main>
          <h1>__HEADLINE__</h1>
          <p>__DETAIL__</p>
          <button id="retry" type="button" hidden>Try Again</button>
          <small>NSURLErrorDomain __CODE__</small>
        </main>
        <script>
          (function () {
            var TARGET = __TARGET__;
            var retry = document.getElementById("retry");
            if (!TARGET) return;
            retry.hidden = false;
            // replace(), so this page does not stay behind in the back list.
            retry.addEventListener("click", function () { location.replace(TARGET); });
            retry.focus();
          })();
        </script>
        </body>
        </html>
        """#
}

/// Serves the error page for `chord-error://` requests. Stateless, shared by
/// every web view, like `OfflineGameSchemeHandler`.
@MainActor
final class ErrorPageSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL))
            return
        }
        let data = Data(
            ErrorPage.html(target: ErrorPage.targetURL(from: url), code: ErrorPage.code(from: url)).utf8)
        let response = URLResponse(
            url: url, mimeType: "text/html",
            expectedContentLength: data.count, textEncodingName: "utf-8"
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
