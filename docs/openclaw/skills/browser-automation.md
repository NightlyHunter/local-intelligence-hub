# OpenClaw Browser Automation — Stealth Patching Reference

> **Purpose:** Reference document for configuring a Playwright-based browser skill in OpenClaw so that headless automation doesn't get flagged as a bot by modern fingerprint-based detection (reCAPTCHA v3, Cloudflare Turnstile, hCaptcha's invisible mode, etc.).
>
> **Scope:** Automation of *your own accounts* on sites you have legitimate access to. Not a scraping or evasion guide.
>
> **Context:** Part of Phase 4 planning. Builds on OpenClaw skills architecture discussed in design notes. See also: ADR-002 (why 122B for agent tasks), ADR-008 (why NOT to route automation through gluetun).

---

## Why stealth patching matters

Modern bot detection almost never looks at one signal. It computes a score across dozens of browser fingerprint dimensions and compares against a baseline of what real browsers look like. A default Playwright/Puppeteer Chromium build leaves fingerprint tells in ~20+ places that no real user's browser has. Any one of them flips the score; several in combination guarantee a challenge or block.

The goal of stealth patching is **not** to look like a specific real user — that's impossible and counterproductive. The goal is to stop looking like a *default headless browser*, which is the specific thing every detection script is trained to catch.

This is the single highest-leverage intervention for browser automation reliability. More than proxies, more than solving services, more than clever prompting. A stealth-patched Chromium with a warmed-up profile on a residential IP will sail past most detection; a default Playwright Chromium will get challenged even on sites that barely care about bots.

---

## The fingerprint tells that matter

These are the specific signals default headless browsers leak. A good stealth setup patches all of them.

### 1. `navigator.webdriver === true`

The most famous tell. WebDriver-controlled browsers expose this flag. One line of JavaScript (`if (navigator.webdriver) { block(); }`) catches 90%+ of naive automation. Every stealth plugin patches this first.

### 2. Missing or wrong `navigator.plugins` and `navigator.mimeTypes`

Real Chrome has a non-empty plugins array (PDF viewer, etc.). Headless Chrome has an empty one. Detection scripts check length and contents.

### 3. `navigator.languages` mismatch

Headless defaults to `["en-US"]` with no secondary. Real browsers usually have 2–3 entries reflecting the user's locale preferences. Must also match the `Accept-Language` HTTP header — mismatches are a classic tell.

### 4. WebGL renderer and vendor strings

`WebGLRenderingContext.getParameter()` with specific constants returns the GPU vendor and renderer. Headless often returns `"Google Inc."` / `"Google SwiftShader"` (software rendering) instead of `"Intel Inc."` / `"Intel Iris OpenGL Engine"` or similar real hardware. This is one of the most reliable detection signals in use today.

### 5. Canvas fingerprint

Drawing text/shapes to a canvas and hashing the pixel output produces a fingerprint that varies by OS, GPU, font rendering, and driver version. Headless Chromium on Linux has a very specific, very recognizable canvas fingerprint. Detection scripts collect this and compare against known-bot hashes.

### 6. AudioContext fingerprint

Same idea as canvas but for audio — synthesize a tone, hash the output buffer. Varies by audio stack and hardware.

### 7. `chrome` object properties

Real Chrome has `window.chrome` with specific nested objects (`chrome.runtime`, `chrome.loadTimes`, etc.). Headless Chromium's `window.chrome` is either missing properties or has telltale differences.

### 8. Permissions API behavior

Querying `navigator.permissions.query({name: 'notifications'})` returns different states in headless vs. normal Chrome in ways that are scriptable to detect.

### 9. Missing hardware APIs

Battery API, Bluetooth, some sensor APIs. Desktops rarely have battery; laptops always do. Mismatches between claimed UA and available APIs are flagged.

### 10. User-Agent / Client Hints mismatch

If UA says Chrome 120 on Windows but `navigator.userAgentData.platform` says Linux, detection catches it immediately. UA spoofing without patching Client Hints is worse than not spoofing at all.

### 11. TLS / JA3 fingerprint (not browser-level)

Even before any JS runs, the TLS handshake has a fingerprint (cipher suite order, extensions, etc.). Real Chrome has a specific JA3 hash; default Node.js HTTP clients and even some automation stacks have a different one. This is why pure HTTP scraping (requests library + headers) often fails on protected sites — the TLS handshake already identified you.

### 12. Timing anomalies

Real users have mouse movement between clicks, typing cadence with variance, scroll events before clicks. Default automation goes directly from `click(A)` to `click(B)` with zero motion in between. Behavioral scoring catches this.

---

## The practical stack

Here's what a stealth-patched browser skill actually looks like in practice. The specifics evolve — check each project's current state — but the shape is stable.

### Layer 1: patched Playwright

Two common paths:

**Path A: `playwright-extra` + `puppeteer-extra-plugin-stealth`**

`playwright-extra` is a wrapper that lets you use Puppeteer-Extra plugins with Playwright. The stealth plugin is the de-facto standard — it bundles ~15 individual evasion modules addressing most of the fingerprint tells above.

```javascript
import { chromium } from 'playwright-extra';
import stealth from 'puppeteer-extra-plugin-stealth';

chromium.use(stealth());

const browser = await chromium.launchPersistentContext(
  '/home/fitz/openclaw/browser-profile',
  {
    headless: false,  // or 'new' for new headless mode — less detectable than old headless
    viewport: { width: 1920, height: 1080 },
    locale: 'en-US',
    timezoneId: 'America/Chicago',
    args: [
      '--disable-blink-features=AutomationControlled',
    ],
  }
);
```

Pros: well-maintained, broad coverage, easy to adopt.
Cons: widely known — sophisticated detection vendors have fingerprinted the stealth plugin's specific patching patterns. Still works against most sites, fails against top-tier bot detection (Cloudflare's paid tier, DataDome, PerimeterX/HUMAN).

**Path B: patched Chromium builds**

Projects like `patchright`, `rebrowser-patches`, and `undetected-chromedriver` (for Selenium) ship modified Chromium binaries or runtime patches that avoid the "stealth plugin fingerprint" problem. More effective against advanced detection, but higher maintenance burden — you're tracking upstream Chromium releases plus the patch set.

For personal automation, **start with Path A.** Move to Path B only if Path A gets caught on a site you specifically need.

### Layer 2: persistent user-data directory

`launchPersistentContext` (shown above) points Chromium at a real profile directory that accumulates cookies, local storage, IndexedDB, cache, and history across runs. This is not optional — it's how you ride on already-authenticated sessions instead of re-logging-in every time.

Critical rules:

- **One profile per logical agent**, not per automation. Don't create `profile-amazon`, `profile-github` — you lose the benefit of a warmed-up profile that looks like a real multi-site user.
- **Log in manually once** to the profile. Launch with `headless: false`, use the browser like a human for 15 minutes, visit a few sites, accept some cookies, let some ad trackers fire. Then close. The profile now has the texture of a real browsing history.
- **Don't share a profile across machines.** It'll have fingerprint inconsistencies (different hardware = different canvas/WebGL).
- **Back up the profile directory periodically.** Loss of profile = loss of every saved login = redo all manual auth steps.

Recommended location on the Linux PC: `~/openclaw/browser-profile/`. Back up to the same place your other OpenClaw config lives.

### Layer 3: realistic context

Beyond the stealth plugin's patches, set these explicitly on every launch:

```javascript
{
  viewport: { width: 1920, height: 1080 },     // Match a real screen size
  locale: 'en-US',                             // Matches your actual locale
  timezoneId: 'America/Chicago',               // Matches your IP's timezone
  colorScheme: 'light',                        // Or 'dark' — but be consistent
  deviceScaleFactor: 1,                        // 2 for HiDPI displays
  userAgent: undefined,                        // Let Chromium set this — do NOT spoof unless you also patch Client Hints
  extraHTTPHeaders: {
    'Accept-Language': 'en-US,en;q=0.9',       // Must match navigator.languages
  },
}
```

**Do not spoof the User-Agent unless you know what you're doing.** Client Hints (`sec-ch-ua`, `sec-ch-ua-platform`, etc.) are sent automatically by Chromium and must match the claimed UA. Mismatches are a worse tell than the default UA.

### Layer 4: human-like interaction timing

The stealth plugin handles static fingerprints. Behavioral fingerprints (mouse movement, typing cadence, scroll patterns) are not patched — the agent has to generate them. A good browser skill wraps raw Playwright actions with timing:

```javascript
async function humanType(page, selector, text) {
  await page.click(selector);
  for (const char of text) {
    await page.keyboard.type(char);
    await page.waitForTimeout(50 + Math.random() * 100);  // 50-150ms per char
  }
}

async function humanClick(page, selector) {
  const el = await page.$(selector);
  const box = await el.boundingBox();
  // Move mouse to a random point inside the element, not dead center
  await page.mouse.move(
    box.x + box.width * (0.3 + Math.random() * 0.4),
    box.y + box.height * (0.3 + Math.random() * 0.4),
    { steps: 10 + Math.floor(Math.random() * 15) }  // Multiple steps = mouse path
  );
  await page.waitForTimeout(50 + Math.random() * 150);
  await page.mouse.down();
  await page.waitForTimeout(30 + Math.random() * 70);
  await page.mouse.up();
}
```

This matters more than most people realize. A site that sees 4 clicks with zero mouse movement between them and uniform 50ms spacing will challenge you regardless of how perfect the static fingerprint is.

Libraries like `ghost-cursor` (Puppeteer) or manual Bezier-curve mouse paths can automate this. For a home-lab agent, the simple random-delay-plus-path approach above is sufficient.

### Layer 5: network identity

Everything above is client-side. Server-side, sites also see your IP.

- **Residential IP (your home connection):** scores well. Bot detection trusts residential ISP space.
- **Datacenter IP (AWS, DO, most VPN exits including ProtonVPN):** scores poorly. Expect constant challenges.
- **Mobile IP (cellular):** scores best. Carriers share pools so bot reputation is diluted.

**Critical for your stack:** do NOT route OpenClaw browser traffic through the `gluetun` container. That container exists for qBittorrent's kill switch and exits via ProtonVPN Netherlands — a known datacenter range. Your browser agent should go out your home T-Mobile connection directly.

On the Linux PC this is the default — gluetun only affects containers with `network_mode: "service:gluetun"`. Just don't put OpenClaw in that mode and you're fine.

---

## Captcha fallback strategy (recap)

Stealth patching reduces how often you see captchas. It doesn't eliminate them. When one does appear:

**Tier 4 (human-in-the-loop) is the default for this project.** The agent detects a challenge (look for specific selectors like `iframe[src*="recaptcha"]`, `iframe[src*="hcaptcha"]`, `div[class*="cf-turnstile"]`), takes a screenshot, sends it to Telegram with a "please solve" message, and waits. You solve it in a visible browser window that shares the profile, the cookies update, and the automation continues.

Implementation hinges on launching the browser with `headless: false` when the agent pings for help — or running a persistent visible browser session on a display-accessible Linux PC that you can VNC into.

**Solving services (Tier 3)** are out of scope for now. Revisit only if a specific recurring automation target justifies the paid dependency and the labor-ethics consideration.

---

## Verification: is stealth actually working?

A few test pages can tell you immediately if the setup passes or fails:

- **`https://bot.sannysoft.com/`** — comprehensive fingerprint report, shows pass/fail for every major tell. First stop.
- **`https://abrahamjuliot.github.io/creepjs/`** — very thorough fingerprinting, shows a "trust score" and detailed breakdown. Catches sophisticated issues.
- **`https://arh.antoinevastel.com/bots/areyouheadless`** — specifically checks for headless indicators.
- **`https://browserleaks.com/`** — multi-category leaks (WebRTC, fonts, canvas, WebGL, etc.).

Workflow: launch your stealth-patched browser, navigate the agent to these pages, have it dump the results. If `bot.sannysoft.com` shows all green rows, you're past the naive detection tier. If `creepjs` trust score is above ~50% and it can't conclusively identify you as a headless browser, you're past the intermediate tier. Top-tier commercial bot detection is harder to test against without trying your actual targets.

Run these after every major change to the stealth setup. A Chromium version bump or a plugin update can silently regress one of the patches.

---

## Maintenance reality

Stealth patching is not set-and-forget. Detection vendors and evasion projects are in an active arms race, and stealth plugin updates lag behind new detection techniques by weeks to months. Realistic maintenance looks like:

- **Pin your dependency versions** in the OpenClaw browser skill. An accidental `npm update` can silently break evasion.
- **Re-run the verification pages quarterly** or after any unexpected challenge behavior. If scores drop, pull the latest stealth plugin and re-test.
- **Watch the projects:** `playwright-extra`, `puppeteer-extra-plugin-stealth`, `patchright`, `rebrowser-patches`. When they push releases addressing new detection, update.
- **Budget for regression.** A site that worked for six months may suddenly start challenging. Usually the fix is a stealth plugin update, sometimes it's switching from Path A to Path B, occasionally the site has genuinely tightened and no automation works anymore.

For personal automation against a small, stable set of targets (your accounts on services you use regularly), this is tractable. For broad scraping targets you don't control, it's a part-time job.

---

## Phase 4 integration checklist

When this moves from plan to implementation, the sequence:

1. [ ] Install Node.js on the Linux PC (OpenClaw host) if not present.
2. [ ] Install a Playwright-based browser skill for OpenClaw. Verify source carefully (ClawHavoc typosquatting risk — check publisher, GitHub stars, commit history, issue activity).
3. [ ] Confirm the skill supports: `launchPersistentContext`, stealth plugin integration, custom timing wrappers. If not, fork or pick another.
4. [ ] Create `~/openclaw/browser-profile/` as the persistent directory.
5. [ ] Launch Chromium interactively (headless: false), log into the services you want the agent to use, browse for 15 min to warm the profile. Back up the directory.
6. [ ] Run the agent against `bot.sannysoft.com` and `creepjs`. Confirm clean fingerprint. Fix any red flags before proceeding.
7. [ ] Pick one narrow automation as a first target. Define success criteria upfront.
8. [ ] Wire the Telegram human-in-the-loop fallback for captcha challenges.
9. [ ] Confirm browser container/process is NOT routed through gluetun — it should use the Linux PC's direct internet connection.
10. [ ] Run the first automation end-to-end. Measure reliability over ~10 runs before expanding scope.

Post-stabilization, this becomes a Phase 4 ADR covering the skill selection, the Path A vs. Path B decision, and the human-in-the-loop pattern.

---

## Open questions to revisit

- Which specific OpenClaw-compatible browser skill to install? (Deferred until actively building — check current ecosystem state at that point.)
- Does OpenClaw's skill framework support async wait-for-human tool calls (Telegram-based captcha fallback)? If not, it becomes the agent pausing the session and the human resuming it manually — still workable but less clean.
- Should the browser agent run as a systemd service on the Linux PC, or launched on-demand by OpenClaw per task? On-demand is simpler; persistent avoids cold-start latency for frequent automations.
- Profile backup cadence. Weekly cron to tar the profile dir into `~/openclaw/backups/` is probably sufficient.
