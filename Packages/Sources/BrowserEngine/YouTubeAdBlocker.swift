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
///    is up it clicks the Skip button if one exists, and always blasts the
///    playback rate so the ad drains in a fraction of a second — even
///    "unskippable" ads, because the ad and the content share one `<video>`
///    element. The rate is re-asserted every tick (the player syncs its own
///    rate back to 1x) and restored the instant the ad ends. The video is also
///    force-muted while an ad is up — at 10x the ad's audio would blast — and
///    the *previous* muted value (which is `AudioMuteController`'s applied
///    state) is restored with the rate: a muted tab stays muted, an unmuted tab
///    returns to unmuted. The ad blocker never overrides the user's own mute
///    choice; it only hides the ad's sound.
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
        // How fast to run an unskippable ad. Its own progress timer is tied to
        // media playback, so a high rate makes even a "non-seekable" ad finish
        // in a blink — a seek alone gets clamped/ignored on many ads, which is
        // why fast-forwarding by itself did not remove unskippable ads.
        var AD_RATE = 10;

        // The ad and the real video are ONE <video> element, so a bumped rate or
        // a forced mute must never survive into content. Restore to 1x and the
        // prior mute state whenever we are not in an ad, and also the instant the
        // current media ends.
        function restoreRate(video) {
            if (video.__chordBumped) {
                try { video.playbackRate = 1; } catch (e) {}
                video.__chordBumped = false;
            }
            if (video.__chordAdMuted) {
                try { video.muted = video.__chordPrevMuted; } catch (e) {}
                video.__chordAdMuted = false;
                video.__chordPrevMuted = undefined;
            }
        }

        // Force-mute the video while an ad is up so the 10x blast never blasts
        // audio. The saved `__chordPrevMuted` IS AudioMuteController's applied
        // state on this element, so restoring it brings the user's own mute
        // choice back: a muted tab stays muted, an unmuted tab returns.
        function muteForAd(video) {
            if (!video.__chordAdMuted) {
                video.__chordAdMuted = true;
                video.__chordPrevMuted = video.muted;
            }
            try { video.muted = true; } catch (e) {}
        }

        function tick() {
            var player = document.querySelector('.html5-video-player');
            if (!player) { return; }

            // Ads also light up the overlay slot on some player versions even
            // when `ad-showing` is not set; treat either as "an ad is up".
            var overlay = player.querySelector('.ytp-ad-player-overlay');
            var adShowing = player.classList.contains('ad-showing')
                || player.classList.contains('ad-interrupting')
                || (overlay && overlay.getClientRects().length > 0);

            // Target EVERY <video>, not just the first: YouTube A/B-tests ads on
            // a separate element, and the watch page can carry an ambient
            // background video that the ad is not. Never early-return after
            // clicking skip — a disabled/custom button swallows the click, so
            // the seek/blast below must still run as the fallback.
            var videos = document.querySelectorAll('video');

            if (!adShowing) {
                for (var i = 0; i < videos.length; i++) { restoreRate(videos[i]); }
                return;
            }

            var btn = player.querySelector(SKIP) || document.querySelector(SKIP);
            if (btn) { try { btn.click(); } catch (e) {} }

            for (var i = 0; i < videos.length; i++) {
                var video = videos[i];
                try {
                    // End the ad by seeking to the end of the AD's media. Only
                    // trust `duration` when it is short enough to BE the ad —
                    // stitched/SSAI ads report the whole content's duration, and
                    // seeking there would skip the content instead. The seek is
                    // clamped/ignored on many ads, so the rate blast below is
                    // the real fix; this is just the fast path when it works.
                    if (isFinite(video.duration) && video.duration > 0
                        && video.duration <= 60) {
                        video.currentTime = video.duration;
                    }
                    // Re-assert the rate on EVERY tick. The player syncs its own
                    // rate back to 1x shortly after we bump it, so a once-only
                    // bump silently dies and the ad runs to completion — the
                    // per-tick blast keeps its timer draining until it ends. The
                    // mute is re-asserted the same way, so the user's unmute
                    // mid-ad is re-hidden for the (fraction of a second) it
                    // takes the ad to end.
                    video.playbackRate = AD_RATE;
                    muteForAd(video);
                    if (!video.__chordBumped) {
                        video.__chordBumped = true;
                        // When this ad's media ends, restore before content plays —
                        // the `!adShowing` tick is the backstop, this is the fast path.
                        video.addEventListener('ended', function () {
                            restoreRate(video);
                        }, { once: true });
                    }
                } catch (e) {}
            }
        }

        setInterval(tick, 250);
    })();
    """
}
