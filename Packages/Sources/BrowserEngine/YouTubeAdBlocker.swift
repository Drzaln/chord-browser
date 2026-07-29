import Foundation
import WebKit

/// Skips and hides ads on YouTube and YouTube Music (non-spec: user-requested).
///
/// The native content blocker (`ContentBlocker`, §4.8) cannot do this: it matches
/// on URLs, and YouTube serves ads from the *same* host and the *same* video
/// player as real content (`*.googlevideo.com`), so there is no request to block.
/// That is why uBlock Origin ships a *script* for YouTube rather than a filter
/// list, and why this does too — the same in-page tactic the other monitors use.
///
/// Two moves, both page-side:
///
/// 1. **Video ads.** A poll watches the player's `ad-showing` state. When an ad
///    is up it clicks the Skip button if one exists, and otherwise seeks the ad
///    to its end — which ends even "unskippable" ads in a fraction of a second,
///    because the ad and the content share one `<video>` element. It deliberately
///    does *not* mute: mute is owned by `AudioMuteController`, and touching it
///    here would fight that.
///
/// 2. **Static ads.** Injected CSS hides mastheads, promoted rows, in-feed ad
///    slots, and YouTube Music's ad slots.
///
/// YouTube is a single-page app, so the poll (not a one-shot) is what keeps it
/// working as the user moves between videos without a document load.
///
/// This is cat-and-mouse by nature — YouTube changes class names and adds
/// anti-adblock walls — so the selectors here are a best effort, not a guarantee,
/// and are the thing most likely to need a touch-up over time.
enum YouTubeAdBlocker {

    /// Injected at document start into every frame — `youtube.com/embed/…` ads
    /// live in iframes too, and `music.youtube.com` is a separate document.
    @MainActor
    static func makeUserScript() -> WKUserScript {
        WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

    private static let source = """
    (function () {
        var host = location.hostname;
        // youtube.com, www./m./music.youtube.com, and the no-cookie embed host.
        if (!/(^|\\.)youtube\\.com$/.test(host)
            && !/(^|\\.)youtube-nocookie\\.com$/.test(host)) { return; }
        if (window.__chordYTAdBlock) { return; }
        window.__chordYTAdBlock = true;

        // 1. Hide static/overlay ad surfaces. `:has()` guards the anti-adblock
        //    dialog; harmless where unsupported.
        var css = [
            '.video-ads', '.ytp-ad-module', '.ytp-ad-overlay-container',
            '.ytp-ad-overlay-slot', '.ytp-suggested-action',
            '#masthead-ad', 'ytd-ad-slot-renderer', 'ytd-display-ad-renderer',
            'ytd-promoted-sparkles-web-renderer', 'ytd-promoted-video-renderer',
            'ytd-in-feed-ad-layout-renderer', 'ytd-banner-promo-renderer',
            'ytmusic-ad-slot-renderer', '.ytmusic-ad-slot-renderer',
            'tp-yt-paper-dialog:has(ytd-enforcement-message-view-model)'
        ].join(',') + '{display:none !important;}';

        function installCSS() {
            if (document.getElementById('__chord-yt-adblock')) { return; }
            var style = document.createElement('style');
            style.id = '__chord-yt-adblock';
            style.textContent = css;
            (document.head || document.documentElement).appendChild(style);
        }
        installCSS();
        // head may not exist yet at document-start.
        document.addEventListener('DOMContentLoaded', installCSS);

        // 2. Skip video ads.
        var SKIP = [
            '.ytp-ad-skip-button', '.ytp-ad-skip-button-modern',
            '.ytp-skip-ad-button', '.ytp-ad-skip-button-container button'
        ].join(',');

        function tick() {
            var player = document.querySelector('.html5-video-player');
            var video = document.querySelector('video');
            if (!player || !video) { return; }

            var adShowing = player.classList.contains('ad-showing')
                || player.classList.contains('ad-interrupting');
            if (!adShowing) { return; }

            var btn = document.querySelector(SKIP);
            if (btn) { try { btn.click(); } catch (e) {} return; }

            // No skip button: jump the ad to its end. Same <video> element as the
            // content, so this only fast-forwards the ad, not the video.
            if (isFinite(video.duration) && video.duration > 0) {
                try { video.currentTime = video.duration; } catch (e) {}
            }
        }

        setInterval(tick, 300);
    })();
    """
}
