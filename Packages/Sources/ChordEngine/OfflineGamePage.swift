import Foundation
import WebKit

/// The offline easter egg: a small side-scrolling shooter in the spirit of
/// Nokia's *Space Impact*, shown when a navigation fails because the machine
/// has no network (non-spec: user-requested).
///
/// Served through a private `chord-offline://` scheme rather than as a real
/// navigation, so it never enters history, never touches a site's origin, and
/// is trivially recognisable from the web view's URL when the engine has to
/// decide whether a reload should retry the real page. The failed URL rides
/// along as a query item so the page's "Try again" button can re-issue it.
enum OfflineGamePage {
    /// The private scheme registered on every web view's configuration. A
    /// hyphen is legal in a scheme and keeps this out of the reserved set
    /// (`http`, `https`, `file`, `about`, `data`) a `WKURLSchemeHandler` may not
    /// claim.
    static let scheme = "chord-offline"
    static let host = "no-internet"

    /// The URL to load for the game, carrying `target` (the page that failed)
    /// when there is one so the page can offer to retry it.
    static func url(target: URL?) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        if let target {
            components.queryItems = [URLQueryItem(name: "url", value: target.absoluteString)]
        }
        // scheme + host are both set, so `url` is always non-nil.
        return components.url!
    }

    /// The failed URL the game page was loaded for, if any.
    static func targetURL(from url: URL) -> URL? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "url" }?
            .value
            .flatMap(URL.init(string:))
    }

    /// Whether `error` is a "this machine is offline" failure, the only case the
    /// game stands in for. Deliberately narrow: a DNS error or a timeout can be
    /// a bad domain or a slow server while the network is fine, and turning
    /// those into a game would be wrong. `networkConnectionLost` covers the
    /// connection dropping mid-request, which is the other offline shape.
    static func isOfflineError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        return nsError.code == NSURLErrorNotConnectedToInternet
            || nsError.code == NSURLErrorNetworkConnectionLost
    }

    /// The self-contained page. No external resources, no storage assumptions
    /// (the high score write is best-effort — a private scheme may refuse
    /// `localStorage`). `__TARGET__` is replaced with a JSON string literal or
    /// `null`.
    static func html(target: URL?) -> String {
        let targetLiteral = target.map { jsonString($0.absoluteString) } ?? "null"
        return template.replacingOccurrences(of: "__TARGET__", with: targetLiteral)
    }

    /// A URL string as a JSON/JS string literal, so a quote or backslash in a
    /// URL cannot break out of the script.
    private static func jsonString(_ value: String) -> String {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(value),
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
        <title>No Internet</title>
        <style>
          :root {
            color-scheme: light dark;
            --bg: #f7f7f7;
            --fg: #3c3c3c;
            --muted: #8a8a8a;
            --accent: #6a5acd;
            --line: #d9d9d9;
          }
          @media (prefers-color-scheme: dark) {
            :root {
              --bg: #1b1b1f;
              --fg: #e6e6ea;
              --muted: #9a9aa2;
              --accent: #a99cff;
              --line: #33333a;
            }
          }
          * { box-sizing: border-box; }
          html, body { height: 100%; margin: 0; }
          body {
            background: var(--bg);
            color: var(--fg);
            font: 15px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text",
                  "Helvetica Neue", Arial, sans-serif;
            display: flex; flex-direction: column;
            align-items: center; justify-content: center;
            gap: 8px; padding: 16px; text-align: center;
            -webkit-user-select: none; user-select: none;
            overflow: hidden;
          }
          .badge {
            width: 44px; height: 44px; border-radius: 13px;
            display: grid; place-items: center; font-size: 25px;
            flex: 0 0 auto;
            background: color-mix(in srgb, var(--accent) 16%, transparent);
          }
          h1 { font-size: 19px; margin: 0; font-weight: 600; letter-spacing: -0.01em; flex: 0 0 auto; }
          p.host {
            margin: 0; color: var(--muted); font-size: 13px;
            max-width: 70ch; word-break: break-all; flex: 0 0 auto;
          }
          canvas {
            width: min(1200px, 100%);
            flex: 1 1 auto; min-height: 180px;
            display: block; border-radius: 12px; outline: none;
            background: #060a12; border: 1px solid var(--line);
            touch-action: none; cursor: crosshair;
          }
          .hint { color: var(--muted); font-size: 12.5px; margin: 0; flex: 0 0 auto; }
          kbd {
            font: inherit; font-size: 11px; padding: 1px 6px; border-radius: 5px;
            border: 1px solid var(--line);
            background: color-mix(in srgb, var(--fg) 6%, transparent);
          }
          button {
            font: inherit; font-size: 14px; font-weight: 500;
            color: #fff; background: var(--accent);
            border: 0; border-radius: 10px; padding: 9px 18px; cursor: pointer;
            flex: 0 0 auto;
          }
          button:active { transform: translateY(1px); }
        </style>
        </head>
        <body>
          <div class="badge">🚀</div>
          <h1>No internet</h1>
          <p class="host" id="host"></p>
          <canvas id="game" width="820" height="380" tabindex="0"
                  aria-label="Space Impact offline game"></canvas>
          <p class="hint" id="hint">
            <kbd>↑↓←→</kbd>/<kbd>WASD</kbd> fly · <kbd>Space</kbd> fire ·
            <kbd>X</kbd> special · <kbd>P</kbd> pause
          </p>
          <button id="retry" type="button" hidden>Try again</button>

          <script>
          (function () {
            "use strict";
            var TARGET = __TARGET__;

            var hostEl = document.getElementById("host");
            var retryEl = document.getElementById("retry");
            var hintEl = document.getElementById("hint");
            var canvas = document.getElementById("game");
            var ctx = canvas.getContext("2d");

            if (TARGET) {
              try { hostEl.textContent = new URL(TARGET).host; }
              catch (e) { hostEl.textContent = TARGET; }
              retryEl.hidden = false;
              retryEl.addEventListener("click", function () { location.href = TARGET; });
            } else {
              hostEl.textContent = "Check your connection and try again.";
            }

            function rand(a, b) { return a + Math.random() * (b - a); }
            function clamp(v, a, b) { return v < a ? a : (v > b ? b : v); }
            function hint(text) { hintEl.textContent = text || ""; }

            var W = 0, H = 0, dpr = 1;
            function resize() {
              dpr = Math.min(window.devicePixelRatio || 1, 2);
              var rect = canvas.getBoundingClientRect();
              W = Math.max(240, rect.width);
              H = Math.max(160, rect.height);
              canvas.width = Math.round(W * dpr);
              canvas.height = Math.round(H * dpr);
              ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
            }
            window.addEventListener("resize", function () { resize(); });

            var input = { up: false, down: false, left: false, right: false, fire: false };
            var pointer = { active: false, y: 0 };
            var highScore = 0;
            try { highScore = parseInt(localStorage.getItem("chordSpaceHigh") || "0", 10) || 0; }
            catch (e) { highScore = 0; }

            // Difficulty climbs with progression — a smooth value, not a level
            // cap. It never falls within a run, and keeps rising past ULTRA.
            var TIERS = [
              { at: 0, name: "EASY" },
              { at: 2, name: "NORMAL" },
              { at: 5, name: "HARD" },
              { at: 8, name: "EXPERT" },
              { at: 12, name: "ULTRA" }
            ];
            function tierFor(d) {
              var name = "EASY";
              for (var i = 0; i < TIERS.length; i++) if (d >= TIERS[i].at) name = TIERS[i].name;
              return name;
            }

            var g = {};
            function reset() {
              g = {
                phase: "idle", score: 0, high: highScore,
                lives: 4, maxLives: 7,
                gun: 1, maxGun: 8,
                special: "missile", specialCount: 3,
                wave: 1, kills: 0, waveTarget: 14,
                bossActive: false, banner: 0, bannerText: "",
                player: { x: 74, y: H / 2, invuln: 0, speedX: 3.0, speedY: 3.6 },
                bullets: [], ebullets: [], enemies: [], specials: [],
                drops: [], particles: [], stars: [],
                spawnIn: 70, fireIn: 0, shake: 0, blink: 0, spId: 1, bId: 1
              };
              for (var i = 0; i < 84; i++) {
                g.stars.push({ x: rand(0, W), y: rand(0, H), z: rand(0.2, 1) });
              }
            }
            // 0 at the very start, +1 per completed wave, plus how far through the
            // current wave the player is. This is the difficulty dial.
            function diff() {
              return (g.wave - 1) + clamp(g.kills / g.waveTarget, 0, 1);
            }
            function setBanner(text, frames) { g.bannerText = text; g.banner = frames; }
            function saveHigh() {
              if (g.score > highScore) {
                highScore = g.score;
                try { localStorage.setItem("chordSpaceHigh", String(highScore)); } catch (e) {}
              }
            }
            function start() {
              if (g.phase === "over") reset();
              if (g.phase !== "idle") return;
              g.phase = "running";
              g.player.invuln = 150;
              setBanner("WAVE 1 · EASY", 90);
              hint("");
            }
            function gameOver() { g.phase = "over"; saveHigh(); hint("Game over — press Space or tap to retry"); }

            function pBox() { var p = g.player; return { x: p.x - 13, y: p.y - 8, w: 26, h: 16 }; }
            function enemyBox(e) { return { x: e.x - e.w / 2, y: e.y - e.h / 2, w: e.w, h: e.h }; }
            function hit(a, b) {
              return a.x < b.x + b.w && a.x + a.w > b.x &&
                     a.y < b.y + b.h && a.y + a.h > b.y;
            }

            function burst(x, y, n, color, scale) {
              scale = scale || 1;
              for (var i = 0; i < n; i++) {
                var a = rand(0, Math.PI * 2), sp = rand(0.5, 3.4) * scale;
                g.particles.push({
                  x: x, y: y, vx: Math.cos(a) * sp, vy: Math.sin(a) * sp,
                  life: rand(12, 34), max: 34, color: color
                });
              }
            }

            // The normal-gun ladder: more streams, wider fans, shorter cooldown;
            // top levels pierce through enemies.
            var GUNS = [
              null,
              { fireIn: 9, dy: [0], slope: [0] },
              { fireIn: 9, dy: [-6, 6], slope: [0, 0] },
              { fireIn: 9, dy: [-8, 0, 8], slope: [-0.11, 0, 0.11] },
              { fireIn: 8, dy: [-12, -4, 4, 12], slope: [-0.15, -0.05, 0.05, 0.15] },
              { fireIn: 8, dy: [-16, -8, 0, 8, 16], slope: [-0.2, -0.1, 0, 0.1, 0.2] },
              { fireIn: 6, dy: [-16, -8, 0, 8, 16], slope: [-0.2, -0.1, 0, 0.1, 0.2] },
              { fireIn: 7, dy: [-18, -12, -6, 0, 6, 12, 18],
                slope: [-0.24, -0.16, -0.08, 0, 0.08, 0.16, 0.24], pierce: true },
              { fireIn: 5, dy: [-18, -12, -6, 0, 6, 12, 18],
                slope: [-0.24, -0.16, -0.08, 0, 0.08, 0.16, 0.24], pierce: true }
            ];
            function fireNormal() {
              if (g.fireIn > 0 || g.phase !== "running") return;
              var p = g.player;
              var spec = GUNS[clamp(g.gun, 1, GUNS.length - 1)];
              g.fireIn = spec.fireIn;
              for (var i = 0; i < spec.dy.length; i++) {
                g.bullets.push({
                  id: g.bId++, x: p.x + 15, y: p.y + spec.dy[i],
                  vx: 10, vy: spec.slope[i], pierce: !!spec.pierce
                });
              }
            }

            function fireEnemy(e, count) {
              var p = g.player;
              var base = Math.atan2(p.y - e.y, p.x - e.x);
              for (var i = 0; i < count; i++) {
                var a = base + (i - (count - 1) / 2) * 0.2;
                g.ebullets.push({
                  x: e.x - e.w * 0.4, y: e.y,
                  vx: Math.cos(a) * e.bs, vy: Math.sin(a) * e.bs
                });
              }
            }
            function fireRadial(e, n) {
              for (var i = 0; i < n; i++) {
                var a = (i / n) * Math.PI * 2 + e.phase;
                g.ebullets.push({
                  x: e.x, y: e.y,
                  vx: Math.cos(a) * e.bs * 0.85, vy: Math.sin(a) * e.bs * 0.85
                });
              }
            }

            // Procedural enemy generator. Every spawn is a random mix of a
            // type drawn from the pool the current difficulty has unlocked and a
            // formation, with stats scaled by the difficulty dial.
            function pickType(d) {
              var pool = ["drone", "drone"];
              if (d >= 0.6) pool.push("wave");
              if (d >= 1.8) pool.push("zig");
              if (d >= 3) pool.push("tank");
              if (d >= 4.5) pool.push("shooter");
              if (d >= 6) pool.push("spinner");
              if (d >= 7) pool.push("diver");
              if (d >= 9) pool.push("bomber");
              return pool[Math.floor(Math.random() * pool.length)];
            }
            function pushEnemy(type, x, y) {
              var d = diff();
              var speedMult = 1 + Math.min(2.0, d * 0.07);
              var hpBonus = Math.floor(d / 4);
              var cdMult = clamp(1 - d * 0.03, 0.45, 1);
              var e = {
                type: type, x: x, y: y, w: 22, h: 16, hp: 1, score: 10,
                move: "linear", speed: 1.8 * speedMult, base: y, amp: 0,
                phase: rand(0, 6.28), vy: 0, burst: 1, tickCd: 0,
                bs: 3.4 + Math.min(3.4, d * 0.12), fireBase: 110, fireCd: 0
              };
              if (type === "wave") {
                e.w = 24; e.h = 18; e.hp = 2; e.score = 20; e.move = "wave";
                e.amp = rand(16, 42) * Math.min(1.6, 1 + d * 0.05); e.speed *= 0.9; e.fireBase = 120;
              } else if (type === "zig") {
                e.w = 24; e.h = 20; e.hp = 2; e.score = 25; e.move = "zig";
                e.vy = rand(1.2, 2.2) + d * 0.05; e.speed *= 0.95; e.fireBase = 130;
              } else if (type === "tank") {
                e.w = 34; e.h = 26; e.hp = 5; e.score = 40; e.speed *= 0.6;
                e.burst = 3; e.fireBase = 100;
              } else if (type === "shooter") {
                e.w = 26; e.h = 22; e.hp = 3; e.score = 30; e.speed *= 0.8;
                e.fireBase = 65;
              } else if (type === "spinner") {
                e.w = 26; e.h = 26; e.hp = 3; e.score = 40; e.speed *= 0.7;
                e.spin = true; e.radial = 6; e.fireBase = 130;
              } else if (type === "diver") {
                e.w = 22; e.h = 18; e.hp = 2; e.score = 25; e.move = "diver";
                e.speed *= 1.35; e.fireBase = 1e9;
              } else if (type === "bomber") {
                e.w = 40; e.h = 30; e.hp = 8; e.score = 70; e.speed *= 0.5;
                e.burst = 5; e.fireBase = 120;
              }
              e.hp += hpBonus;
              e.fireCd = e.fireBase * cdMult * rand(0.6, 1.3);
              g.enemies.push(e);
            }
            function spawnGroup() {
              var d = diff();
              var patterns = ["single"];
              if (d < 1.5) patterns = ["single", "single", "column"];
              else if (d < 5) patterns = ["single", "column", "diagonal", "pincer"];
              else patterns = ["single", "column", "diagonal", "pincer", "swarm"];
              var pattern = patterns[Math.floor(Math.random() * patterns.length)];
              var type = pickType(d);
              var i, n, y, dir;
              if (pattern === "column") {
                n = 2 + Math.floor(Math.random() * 2) + (d > 8 ? 1 : 0);
                y = rand(70, H - 70);
                for (i = 0; i < n; i++) {
                  pushEnemy(type, W + 24, clamp(y + (i - (n - 1) / 2) * 46, 54, H - 40));
                }
              } else if (pattern === "diagonal") {
                y = rand(60, H - 60); dir = Math.random() < 0.5 ? 1 : -1;
                for (i = 0; i < 3; i++) {
                  pushEnemy(type, W + 24 + i * 34, clamp(y + dir * i * 40, 54, H - 40));
                }
              } else if (pattern === "pincer") {
                pushEnemy(type, W + 24, rand(60, H * 0.42));
                pushEnemy(type, W + 30 + rand(0, 30), rand(H * 0.58, H - 50));
              } else if (pattern === "swarm") {
                n = 3 + Math.floor(Math.random() * 3);
                for (i = 0; i < n; i++) {
                  pushEnemy(pickType(d), W + 24 + rand(0, 60), rand(60, H - 50));
                }
              } else {
                pushEnemy(type, W + 24, rand(54, H - 44));
              }
              g.spawnIn = clamp(72 - d * 2.4, 14, 72) * rand(0.8, 1.25);
            }

            function spawnBoss() {
              g.bossActive = true;
              var d = diff();
              var hp = Math.round(60 + d * 26);
              var patterns = ["spread", "radial", "support"];
              var pattern = patterns[Math.floor(Math.random() * patterns.length)];
              g.enemies.push({
                type: "boss", x: W + 110, y: H / 2,
                w: 72 + Math.min(60, d * 4), h: 58 + Math.min(50, d * 3),
                hp: hp, maxHp: hp, score: 200 + Math.round(d * 40),
                speed: 1.0 + Math.min(1.6, d * 0.08),
                phase: 0, fireCd: 70, supportIn: 180, tickCd: 0,
                pattern: pattern, bs: 3.6 + Math.min(3, d * 0.14)
              });
              setBanner("WAVE " + g.wave + " — BOSS", 90);
              g.shake = 26;
            }
            function spawnSupport(boss) {
              g.enemies.push({
                type: "drone", x: boss.x, y: boss.y + rand(-20, 20), w: 20, h: 14,
                hp: 1, score: 10, speed: 2.4, move: "linear", base: boss.y,
                phase: 0, vy: 0, burst: 1, tickCd: 0, bs: boss.bs * 0.8,
                fireBase: 120, fireCd: 80
              });
            }

            function updateBoss(e, dt) {
              if (e.x > W - 110) e.x -= e.speed * 1.7 * dt;
              e.phase += 0.02 * dt;
              e.y = H / 2 + Math.sin(e.phase) * (H * 0.28);
              e.fireCd -= dt;
              if (e.fireCd <= 0 && e.x < W) {
                if (e.pattern === "radial") { fireRadial(e, 8); e.fireCd = 70; }
                else { fireEnemy(e, 3); e.fireCd = 56; }
              }
              if (e.pattern === "support") {
                e.supportIn -= dt;
                if (e.supportIn <= 0 && e.x < W) { e.supportIn = rand(200, 320); spawnSupport(e); }
              }
            }

            function updateEnemy(e, dt) {
              if (e.tickCd > 0) e.tickCd -= dt;
              if (e.type === "boss") { updateBoss(e, dt); return; }
              if (e.move === "wave") {
                e.x -= e.speed * dt; e.phase += 0.05 * dt;
                e.y = e.base + Math.sin(e.phase) * e.amp;
              } else if (e.move === "zig") {
                if (e.x > W * 0.62) e.x -= e.speed * dt;
                else {
                  e.x -= e.speed * 0.7 * dt;
                  e.y += e.vy * dt;
                  if (e.y > H - 24) { e.y = H - 24; e.vy = -Math.abs(e.vy); }
                  if (e.y < 52) { e.y = 52; e.vy = Math.abs(e.vy); }
                }
              } else if (e.move === "diver") {
                e.x -= e.speed * dt;
                var dy = g.player.y - e.y;
                e.y += (dy > 0 ? 1 : dy < 0 ? -1 : 0) * Math.min(2.4, e.speed * 0.9) * dt;
              } else {
                e.x -= e.speed * dt;
              }
              if (e.spin) e.phase += 0.15 * dt;
              e.fireCd -= dt;
              if (e.fireCd <= 0 && e.x < W - 8 && e.x > -8) {
                e.fireCd = e.fireBase * rand(0.75, 1.25);
                if (e.radial) fireRadial(e, e.radial);
                else if (Math.random() < 0.72) fireEnemy(e, e.burst || 1);
              }
            }

            function killEnemy(e, idx) {
              var boss = e.type === "boss";
              burst(e.x, e.y, boss ? 48 : 12, boss ? "#ff7b6b" : "#ff9f68", boss ? 4 : 1);
              g.enemies.splice(idx, 1);
              g.score += e.score;
              if (g.score > g.high) g.high = g.score;
              if (boss) {
                g.shake = 40;
                for (var i = 0; i < 3; i++) dropAt(e.x, e.y + rand(-18, 18));
                waveComplete();
                return;
              }
              g.kills++;
              if (Math.random() < 0.12) dropAt(e.x, e.y);
              if (!g.bossActive && g.kills >= g.waveTarget) spawnBoss();
            }

            function waveComplete() {
              g.bossActive = false;
              g.score += 100 + g.wave * 20;
              g.wave++;
              g.kills = 0;
              g.waveTarget = 14 + Math.min(26, g.wave * 2);
              g.enemies.length = 0;
              g.ebullets.length = 0;
              g.player.invuln = 170;
              g.specialCount = Math.min(9, g.specialCount + 1);
              setBanner("WAVE " + g.wave + " · " + tierFor(diff()), 110);
            }

            function dropAt(x, y) {
              var r = Math.random();
              var t = r < 0.2 ? "life"
                    : r < 0.45 ? "gun"
                    : r < 0.65 ? "missile"
                    : r < 0.85 ? "laser" : "wall";
              g.drops.push({ type: t, x: x, y: y, vy: rand(-1.1, 1.1) });
            }

            function collect(dr) {
              if (dr.type === "life") {
                g.lives = Math.min(g.maxLives, g.lives + 1);
              } else if (dr.type === "gun") {
                g.gun = Math.min(g.maxGun, g.gun + 1);
              } else {
                g.special = dr.type;
                g.specialCount = Math.min(9, g.specialCount + 3);
              }
              g.score += 5;
              if (g.score > g.high) g.high = g.score;
              burst(dr.x, dr.y, 10, "#7ef0ff");
            }

            function damage() {
              var p = g.player;
              if (p.invuln > 0) return;
              g.lives--;
              g.gun = Math.max(1, g.gun - 1);
              p.invuln = 130;
              g.shake = 22;
              burst(p.x, p.y, 26, "#ff6b6b", 3);
              if (g.lives <= 0) gameOver();
            }

            function useSpecial() {
              if (g.phase !== "running" || g.specialCount <= 0) return;
              g.specialCount--;
              var p = g.player;
              if (g.special === "missile") {
                g.specials.push({ id: g.spId++, type: "missile", x: p.x + 18, y: p.y,
                                  vx: 4.4, vy: 0, dmg: 50 });
              } else if (g.special === "laser") {
                g.specials.push({ id: g.spId++, type: "laser", x: p.x + 16, y: p.y,
                                  t: 34, dmg: 4 });
              } else {
                g.specials.push({ id: g.spId++, type: "wall", x: p.x + 18,
                                  vx: 4.6, w: 10, dmg: 4 });
              }
            }

            function specialTick(sp, box) {
              for (var k = g.enemies.length - 1; k >= 0; k--) {
                var e = g.enemies[k];
                if (!hit(box, enemyBox(e))) continue;
                if (e.tickTag === sp.id && e.tickCd > 0) continue;
                e.tickTag = sp.id;
                e.tickCd = 4;
                e.hp -= sp.dmg;
                burst(e.x, e.y, 3, "#7ef0ff");
                if (e.hp <= 0) killEnemy(e, k);
              }
            }

            function updateSpecials(dt) {
              for (var i = g.specials.length - 1; i >= 0; i--) {
                var sp = g.specials[i];
                if (sp.type === "missile") {
                  var target = null;
                  for (var j = 0; j < g.enemies.length; j++) {
                    var en = g.enemies[j];
                    if (en.x > sp.x - 6 && (!target || en.x < target.x)) target = en;
                  }
                  if (target) {
                    var a = Math.atan2(target.y - sp.y, target.x - sp.x);
                    sp.vx = clamp(sp.vx + Math.cos(a) * 0.5, 2, 7);
                    sp.vy = clamp(sp.vy + Math.sin(a) * 0.5, -6, 6);
                  }
                  sp.x += sp.vx * dt; sp.y += sp.vy * dt;
                  var mbox = { x: sp.x - 6, y: sp.y - 4, w: 12, h: 8 };
                  var gone = false;
                  for (var k = g.enemies.length - 1; k >= 0; k--) {
                    var e = g.enemies[k];
                    if (hit(mbox, enemyBox(e))) {
                      e.hp -= sp.dmg;
                      burst(sp.x, sp.y, 8, "#ffd166");
                      if (e.hp <= 0) killEnemy(e, k);
                      gone = true;
                      break;
                    }
                  }
                  if (gone || sp.x > W + 20 || sp.y < -20 || sp.y > H + 20) g.specials.splice(i, 1);
                } else if (sp.type === "laser") {
                  sp.x = g.player.x + 16; sp.y = g.player.y; sp.t -= dt;
                  specialTick(sp, { x: sp.x, y: sp.y - 6, w: W - sp.x + 20, h: 12 });
                  if (sp.t <= 0) g.specials.splice(i, 1);
                } else {
                  sp.x += sp.vx * dt;
                  specialTick(sp, { x: sp.x, y: 0, w: sp.w, h: H });
                  if (sp.x > W + 20) g.specials.splice(i, 1);
                }
              }
            }

            function step(dt) {
              if (g.banner > 0) g.banner -= dt;
              if (g.phase !== "running") { g.blink += dt; return; }
              var p = g.player, i, o;

              var ax = (input.right ? 1 : 0) - (input.left ? 1 : 0);
              var ay = (input.down ? 1 : 0) - (input.up ? 1 : 0);
              p.x += ax * p.speedX * dt;
              p.y += ay * p.speedY * dt;
              if (pointer.active) p.y += (pointer.y - p.y) * Math.min(1, 0.18 * dt);
              p.x = clamp(p.x, 30, Math.min(W * 0.55, W - 60));
              p.y = clamp(p.y, 52, H - 20);
              if (p.invuln > 0) p.invuln -= dt;
              if (g.shake > 0) g.shake -= dt;

              g.fireIn -= dt;
              if (input.fire || pointer.active) fireNormal();

              for (i = g.bullets.length - 1; i >= 0; i--) {
                o = g.bullets[i];
                o.x += o.vx * dt; o.y += o.vy * dt;
                if (o.x > W + 12 || o.y < -40 || o.y > H + 40) g.bullets.splice(i, 1);
              }

              if (!g.bossActive) {
                g.spawnIn -= dt;
                if (g.spawnIn <= 0 && g.kills < g.waveTarget) spawnGroup();
              }
              for (i = g.enemies.length - 1; i >= 0; i--) {
                updateEnemy(g.enemies[i], dt);
                if (g.enemies[i].x + g.enemies[i].w < -40) g.enemies.splice(i, 1);
              }

              for (i = g.ebullets.length - 1; i >= 0; i--) {
                o = g.ebullets[i];
                o.x += o.vx * dt; o.y += o.vy * dt;
                if (o.x < -24 || o.y < -24 || o.y > H + 24) g.ebullets.splice(i, 1);
              }

              for (i = g.drops.length - 1; i >= 0; i--) {
                var dr = g.drops[i];
                dr.x -= 2.2 * dt; dr.y += dr.vy * dt;
                if (dr.y < 18) dr.vy = Math.abs(dr.vy);
                if (dr.y > H - 18) dr.vy = -Math.abs(dr.vy);
                if (dr.x < -20) { g.drops.splice(i, 1); continue; }
                if (hit(pBox(), { x: dr.x - 9, y: dr.y - 9, w: 18, h: 18 })) {
                  collect(dr); g.drops.splice(i, 1);
                }
              }

              for (i = g.enemies.length - 1; i >= 0; i--) {
                var e = g.enemies[i], box = enemyBox(e);
                for (var b = g.bullets.length - 1; b >= 0; b--) {
                  var bl = g.bullets[b];
                  if (bl.x < box.x || bl.x > box.x + box.w ||
                      bl.y < box.y || bl.y > box.y + box.h) continue;
                  if (e.bTag === bl.id) continue;
                  e.bTag = bl.id;
                  e.hp -= 1;
                  burst(bl.x, bl.y, 3, bl.pierce ? "#ff9f43" : "#ffd166");
                  if (!bl.pierce) g.bullets.splice(b, 1);
                  if (e.hp <= 0) { killEnemy(e, i); break; }
                  if (!bl.pierce) break;
                }
              }

              updateSpecials(dt);

              var pb = pBox();
              for (i = g.enemies.length - 1; i >= 0; i--) {
                if (hit(pb, enemyBox(g.enemies[i]))) { damage(); break; }
              }
              for (i = g.ebullets.length - 1; i >= 0; i--) {
                o = g.ebullets[i];
                if (o.x > pb.x && o.x < pb.x + pb.w && o.y > pb.y && o.y < pb.y + pb.h) {
                  g.ebullets.splice(i, 1); damage(); break;
                }
              }

              for (i = g.particles.length - 1; i >= 0; i--) {
                var pa = g.particles[i];
                pa.x += pa.vx * dt; pa.y += pa.vy * dt; pa.life -= dt;
                if (pa.life <= 0) g.particles.splice(i, 1);
              }
              var starSpeed = 1 + Math.min(1.6, diff() * 0.05);
              for (i = 0; i < g.stars.length; i++) {
                var st = g.stars[i];
                st.x -= (0.6 + st.z * 2.8) * starSpeed * dt;
                if (st.x < 0) { st.x = W + rand(0, 24); st.y = rand(0, H); }
              }
            }

            function drawEnemy(e) {
              var x = e.x, y = e.y;
              if (e.type === "boss") {
                ctx.fillStyle = "#ff4d6d";
                ctx.beginPath();
                ctx.moveTo(x - e.w / 2, y);
                ctx.lineTo(x + e.w / 2, y - e.h / 2);
                ctx.lineTo(x + e.w / 2 + 8, y);
                ctx.lineTo(x + e.w / 2, y + e.h / 2);
                ctx.closePath(); ctx.fill();
                ctx.fillStyle = "#2b0710";
                ctx.fillRect(x - e.w / 2 + 8, y - e.h / 2 + 8, e.w - 16, e.h - 16);
                ctx.fillStyle = "#ffe066";
                ctx.beginPath(); ctx.arc(x - 8, y, 6, 0, 6.2832); ctx.fill();
                var frac = clamp(e.hp / e.maxHp, 0, 1);
                ctx.fillStyle = "rgba(255,255,255,0.15)";
                ctx.fillRect(x - 34, y - e.h / 2 - 14, 68, 5);
                ctx.fillStyle = "#ff6b6b";
                ctx.fillRect(x - 34, y - e.h / 2 - 14, 68 * frac, 5);
              } else if (e.type === "wave") {
                ctx.fillStyle = "#ff6f91";
                ctx.beginPath(); ctx.ellipse(x, y, e.w / 2, e.h / 2, 0, 0, 6.2832); ctx.fill();
                ctx.fillStyle = "#3a0d1c";
                ctx.beginPath(); ctx.ellipse(x - 4, y - 3, 5, 4, 0, 0, 6.2832); ctx.fill();
              } else if (e.type === "tank") {
                ctx.fillStyle = "#d16bff";
                ctx.fillRect(x - e.w / 2, y - e.h / 2, e.w, e.h);
                ctx.fillStyle = "#3d1450";
                ctx.fillRect(x - e.w / 2 + 4, y - e.h / 2 + 4, e.w - 8, e.h - 8);
                ctx.fillStyle = "#ffd166";
                ctx.fillRect(x + 2, y - 3, 6, 6);
              } else if (e.type === "shooter") {
                ctx.fillStyle = "#ffd166";
                ctx.beginPath();
                ctx.moveTo(x - e.w / 2, y);
                ctx.lineTo(x + e.w / 2, y - e.h / 2);
                ctx.lineTo(x + e.w / 2, y + e.h / 2);
                ctx.closePath(); ctx.fill();
                ctx.fillStyle = "#3a2a06";
                ctx.fillRect(x + e.w / 2 - 6, y - 3, 5, 6);
              } else if (e.type === "spinner") {
                ctx.save();
                ctx.translate(x, y);
                ctx.rotate(e.phase);
                ctx.fillStyle = "#c9a3ff";
                var r = e.w / 2;
                ctx.beginPath();
                for (var k = 0; k < 6; k++) {
                  var a = (k / 6) * Math.PI * 2;
                  var rr = k % 2 === 0 ? r : r * 0.5;
                  ctx[k === 0 ? "moveTo" : "lineTo"](Math.cos(a) * rr, Math.sin(a) * rr);
                }
                ctx.closePath(); ctx.fill();
                ctx.restore();
                ctx.fillStyle = "#2a1140";
                ctx.beginPath(); ctx.arc(x, y, 4, 0, 6.2832); ctx.fill();
              } else if (e.type === "diver") {
                ctx.fillStyle = "#7ef0ff";
                ctx.beginPath();
                ctx.moveTo(x + e.w / 2, y);
                ctx.lineTo(x - e.w / 2, y - e.h / 2);
                ctx.lineTo(x - e.w / 2, y + e.h / 2);
                ctx.closePath(); ctx.fill();
              } else if (e.type === "bomber") {
                ctx.fillStyle = "#ff9f43";
                ctx.beginPath();
                ctx.moveTo(x - e.w / 2, y - e.h / 2);
                ctx.lineTo(x + e.w / 2 - 8, y - e.h / 2);
                ctx.lineTo(x + e.w / 2, y);
                ctx.lineTo(x + e.w / 2 - 8, y + e.h / 2);
                ctx.lineTo(x - e.w / 2, y + e.h / 2);
                ctx.closePath(); ctx.fill();
                ctx.fillStyle = "#3a2005";
                ctx.fillRect(x - e.w / 2 + 7, y - e.h / 2 + 8, e.w - 16, e.h - 16);
                ctx.fillStyle = "#ffe066";
                ctx.beginPath(); ctx.arc(x - 4, y, 4, 0, 6.2832); ctx.fill();
              } else {
                ctx.fillStyle = "#ff8f5a";
                ctx.beginPath();
                ctx.moveTo(x - e.w / 2, y);
                ctx.lineTo(x + e.w / 2, y - e.h / 2);
                ctx.lineTo(x + e.w / 2, y + e.h / 2);
                ctx.closePath(); ctx.fill();
                ctx.fillStyle = "#2a1206";
                ctx.fillRect(x + e.w / 2 - 5, y - 2, 4, 4);
              }
            }

            function drawSpecial(sp) {
              if (sp.type === "missile") {
                ctx.fillStyle = "#ffd166";
                ctx.beginPath();
                ctx.moveTo(sp.x + 9, sp.y);
                ctx.lineTo(sp.x - 7, sp.y - 5);
                ctx.lineTo(sp.x - 7, sp.y + 5);
                ctx.closePath(); ctx.fill();
                ctx.fillStyle = "#ff9f43";
                ctx.fillRect(sp.x - 14, sp.y - 2, 8, 4);
              } else if (sp.type === "laser") {
                ctx.fillStyle = "rgba(126,240,255,0.85)";
                ctx.fillRect(sp.x, sp.y - 3, W - sp.x + 20, 6);
                ctx.fillStyle = "rgba(216,255,255,0.95)";
                ctx.fillRect(sp.x, sp.y - 1, W - sp.x + 20, 2);
              } else {
                ctx.fillStyle = "rgba(126,240,255,0.7)";
                ctx.fillRect(sp.x, 0, sp.w, H);
                ctx.fillStyle = "rgba(216,255,255,0.9)";
                ctx.fillRect(sp.x + 4, 0, 2, H);
              }
            }

            function drawDrop(dr) {
              var col = dr.type === "life" ? "#ff6b6b"
                      : dr.type === "gun" ? "#7dff9b"
                      : dr.type === "missile" ? "#ffd166"
                      : dr.type === "laser" ? "#7ef0ff" : "#c9a3ff";
              var label = dr.type === "life" ? "♥"
                        : dr.type === "gun" ? "G"
                        : dr.type === "missile" ? "M"
                        : dr.type === "laser" ? "L" : "W";
              ctx.fillStyle = col;
              ctx.beginPath(); ctx.arc(dr.x, dr.y, 9, 0, 6.2832); ctx.fill();
              ctx.fillStyle = "#060a12";
              ctx.font = "700 11px ui-monospace, Menlo, monospace";
              ctx.textAlign = "center";
              ctx.fillText(label, dr.x, dr.y + 4);
              ctx.textAlign = "left";
            }

            function drawPlayer() {
              var p = g.player;
              if (p.invuln > 0 && Math.floor(p.invuln / 6) % 2 === 0) return;
              if (input.fire || pointer.active || g.phase === "idle") {
                var f = 10 + Math.random() * 12;
                ctx.fillStyle = "#ffb703";
                ctx.beginPath();
                ctx.moveTo(p.x - 12, p.y - 4);
                ctx.lineTo(p.x - 12 - f, p.y);
                ctx.lineTo(p.x - 12, p.y + 4);
                ctx.closePath(); ctx.fill();
              }
              ctx.fillStyle = "#8be9ff";
              ctx.beginPath();
              ctx.moveTo(p.x + 15, p.y);
              ctx.lineTo(p.x - 12, p.y - 9);
              ctx.lineTo(p.x - 6, p.y);
              ctx.lineTo(p.x - 12, p.y + 9);
              ctx.closePath(); ctx.fill();
              ctx.fillStyle = "#eafcff";
              ctx.beginPath(); ctx.arc(p.x + 2, p.y, 2.4, 0, 6.2832); ctx.fill();
            }

            function heart(x, y, s) {
              ctx.beginPath();
              ctx.moveTo(x, y + s * 0.32);
              ctx.bezierCurveTo(x, y, x - s * 0.55, y, x - s * 0.55, y + s * 0.36);
              ctx.bezierCurveTo(x - s * 0.55, y + s * 0.72, x, y + s * 0.92, x, y + s * 1.12);
              ctx.bezierCurveTo(x, y + s * 0.92, x + s * 0.55, y + s * 0.72, x + s * 0.55, y + s * 0.36);
              ctx.bezierCurveTo(x + s * 0.55, y, x, y, x, y + s * 0.32);
              ctx.fill();
            }

            function specialLabel() {
              return g.special === "missile" ? "MISSILE"
                   : g.special === "laser" ? "LASER" : "WALL";
            }

            function drawHud() {
              ctx.font = "600 15px ui-monospace, 'SF Mono', Menlo, monospace";
              ctx.textAlign = "right";
              var score = String(g.score).padStart(5, "0");
              if (g.high > 0) score += "   HI " + String(g.high).padStart(5, "0");
              ctx.fillStyle = "#dbe7ff";
              ctx.fillText(score, W - 12, 22);

              ctx.textAlign = "left";
              ctx.fillStyle = "#ff6b6b";
              for (var i = 0; i < g.lives; i++) heart(16 + i * 18, 8, 12);

              var d = diff();
              ctx.fillStyle = "#9fb4d8";
              ctx.font = "600 12px ui-monospace, Menlo, monospace";
              ctx.fillText("WAVE " + g.wave + " · " + tierFor(d), 16, 44);
              ctx.fillStyle = "#7dff9b";
              ctx.fillText("GUN " + g.gun + "/" + g.maxGun, 16, H - 28);
              ctx.fillStyle = "#7ef0ff";
              ctx.fillText(specialLabel() + " ×" + g.specialCount, 16, H - 12);

              if (g.bossActive) {
                var boss = null;
                for (var b = 0; b < g.enemies.length; b++) {
                  if (g.enemies[b].type === "boss") { boss = g.enemies[b]; break; }
                }
                if (boss) {
                  ctx.fillStyle = "rgba(255,255,255,0.15)";
                  ctx.fillRect(W / 2 - 90, 10, 180, 6);
                  ctx.fillStyle = "#ff4d6d";
                  ctx.fillRect(W / 2 - 90, 10, 180 * clamp(boss.hp / boss.maxHp, 0, 1), 6);
                }
              }
            }

            function drawOverlay() {
              ctx.textAlign = "center";
              if (g.phase === "idle") {
                ctx.fillStyle = "rgba(219,231,255," + (0.6 + 0.4 * Math.sin(g.blink * 0.08)) + ")";
                ctx.font = "700 22px ui-monospace, 'SF Mono', Menlo, monospace";
                ctx.fillText("SPACE IMPACT", W / 2, H / 2 - 10);
                ctx.fillStyle = "rgba(200,215,255,0.7)";
                ctx.font = "12px -apple-system, sans-serif";
                ctx.fillText("endless · press Space or tap to launch", W / 2, H / 2 + 14);
              } else if (g.phase === "over") {
                ctx.fillStyle = "rgba(255,120,120,0.95)";
                ctx.font = "700 22px ui-monospace, 'SF Mono', Menlo, monospace";
                ctx.fillText("GAME OVER", W / 2, H / 2 - 8);
                ctx.fillStyle = "rgba(219,231,255,0.8)";
                ctx.font = "12px -apple-system, sans-serif";
                ctx.fillText("wave " + g.wave + " · press Space or tap to retry", W / 2, H / 2 + 14);
              } else if (g.phase === "paused") {
                ctx.fillStyle = "rgba(219,231,255,0.9)";
                ctx.font = "700 20px ui-monospace, 'SF Mono', Menlo, monospace";
                ctx.fillText("PAUSED", W / 2, H / 2);
              }
              if (g.banner > 0 && g.bannerText) {
                ctx.globalAlpha = clamp(g.banner / 40, 0, 1);
                ctx.fillStyle = "#ffd166";
                ctx.font = "700 22px ui-monospace, 'SF Mono', Menlo, monospace";
                ctx.fillText(g.bannerText, W / 2, H * 0.3);
                ctx.globalAlpha = 1;
              }
              ctx.textAlign = "left";
            }

            function draw() {
              ctx.fillStyle = "#060a12";
              ctx.fillRect(0, 0, W, H);

              var ox = g.shake > 0 ? rand(-2, 2) : 0;
              var oy = g.shake > 0 ? rand(-2, 2) : 0;
              ctx.save();
              ctx.translate(ox, oy);

              for (var s = 0; s < g.stars.length; s++) {
                var st = g.stars[s];
                ctx.fillStyle = "rgba(210,225,255," + (0.15 + st.z * 0.6) + ")";
                var size = 0.7 + st.z * 1.6;
                ctx.fillRect(st.x, st.y, size, size);
              }

              for (var i = 0; i < g.bullets.length; i++) {
                var b = g.bullets[i];
                ctx.fillStyle = b.pierce ? "#ff9f43" : "#ffd166";
                ctx.fillRect(b.x - 4, b.y - 1.5, b.pierce ? 9 : 6, 3);
              }
              ctx.fillStyle = "#ff7b6b";
              for (var j = 0; j < g.ebullets.length; j++) {
                var eb = g.ebullets[j];
                ctx.beginPath(); ctx.arc(eb.x, eb.y, 3, 0, 6.2832); ctx.fill();
              }

              for (var d = 0; d < g.drops.length; d++) drawDrop(g.drops[d]);
              for (var e = 0; e < g.enemies.length; e++) drawEnemy(g.enemies[e]);
              for (var sp = 0; sp < g.specials.length; sp++) drawSpecial(g.specials[sp]);

              for (var t = 0; t < g.particles.length; t++) {
                var pa = g.particles[t];
                ctx.globalAlpha = clamp(pa.life / pa.max, 0, 1);
                ctx.fillStyle = pa.color;
                ctx.fillRect(pa.x - 1.5, pa.y - 1.5, 3, 3);
              }
              ctx.globalAlpha = 1;

              drawPlayer();
              ctx.restore();

              drawHud();
              drawOverlay();
            }

            var last = 0;
            function loop(now) {
              if (!last) last = now;
              var dt = Math.min(2.5, (now - last) / 16.667);
              last = now;
              step(dt);
              draw();
              requestAnimationFrame(loop);
            }

            function togglePause() {
              if (g.phase === "running") g.phase = "paused";
              else if (g.phase === "paused") g.phase = "running";
            }

            window.addEventListener("keydown", function (e) {
              switch (e.code) {
                case "ArrowUp": case "KeyW": input.up = true; e.preventDefault(); break;
                case "ArrowDown": case "KeyS": input.down = true; e.preventDefault(); break;
                case "ArrowLeft": case "KeyA": input.left = true; e.preventDefault(); break;
                case "ArrowRight": case "KeyD": input.right = true; e.preventDefault(); break;
                case "KeyP": togglePause(); break;
                case "KeyX": case "KeyK":
                  if (!e.repeat) useSpecial();
                  e.preventDefault();
                  break;
                case "Space": case "KeyJ":
                  e.preventDefault();
                  if (g.phase === "idle" || g.phase === "over") start();
                  input.fire = true;
                  break;
              }
            }, { passive: false });

            window.addEventListener("keyup", function (e) {
              switch (e.code) {
                case "ArrowUp": case "KeyW": input.up = false; break;
                case "ArrowDown": case "KeyS": input.down = false; break;
                case "ArrowLeft": case "KeyA": input.left = false; break;
                case "ArrowRight": case "KeyD": input.right = false; break;
                case "Space": case "KeyJ": input.fire = false; break;
              }
            });

            function pointerY(e) {
              var rect = canvas.getBoundingClientRect();
              return clamp(e.clientY - rect.top, 52, H - 20);
            }
            canvas.addEventListener("pointerdown", function (e) {
              e.preventDefault();
              canvas.focus();
              if (g.phase === "idle" || g.phase === "over") start();
              pointer.active = true;
              pointer.y = pointerY(e);
            });
            canvas.addEventListener("pointermove", function (e) {
              if (pointer.active) pointer.y = pointerY(e);
            });
            function endPointer() { pointer.active = false; }
            window.addEventListener("pointerup", endPointer);
            canvas.addEventListener("pointercancel", endPointer);

            window.__chordOffline = {
              start: start,
              step: step,
              useSpecial: useSpecial,
              state: function () {
                return {
                  phase: g.phase, wave: g.wave, tier: tierFor(diff()),
                  score: g.score, lives: g.lives, gun: g.gun,
                  special: g.special, specialCount: g.specialCount,
                  enemies: g.enemies.length, bullets: g.bullets.length,
                  bossActive: g.bossActive
                };
              }
            };

            resize();
            reset();
            requestAnimationFrame(loop);
          })();
          </script>
        </body>
        </html>
        """#
}

/// Serves `OfflineGamePage.html` for the private scheme. One instance is shared
/// by every web view and pinned on each copied configuration, so a copied
/// template can never lose it.
@MainActor
final class OfflineGameSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
            let data = OfflineGamePage.html(target: OfflineGamePage.targetURL(from: url))
                .data(using: .utf8)
        else {
            urlSchemeTask.didFailWithError(
                NSError(
                    domain: NSURLErrorDomain, code: NSURLErrorBadURL,
                    userInfo: [NSLocalizedDescriptionKey: "offline page unavailable"]
                )
            )
            return
        }
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
