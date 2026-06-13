# Novex — Build Journal & Project Documentation

*A complete account of how Novex was built: the idea, the goals, the methodology, every feature, every refinement, what went right, what went wrong, and what's next.*

**Project:** Novex — a free, on-device, private email assistant for the macOS menu bar
**Repo:** https://github.com/Tharuntejandhe/Novex
**Stack:** Swift · SwiftUI · AppKit · Apple Foundation Models (on-device) · Apple Mail Envelope Index · EventKit
**Built by:** Tharun Tej × Claude

---

## 0. TL;DR

Novex turns a noisy inbox (~120 emails/day, mostly newsletters and job alerts) into the 2–3 things that actually need you — and it does it **100% on your Mac**, with no account, no cloud, and no telemetry. It reads the local copy of mail that Apple Mail keeps on disk, ranks it with a deterministic engine (so it never "hallucinates" importance), and uses Apple's on-device foundation model only to *phrase* the result. It drafts replies, flags subscriptions you're wasting money on, surfaces interesting reads from your newsletters, answers questions about your inbox by voice or text, and delivers ambient notifications via a Dynamic-Island-style card. It ships free and open-source (MIT), distributed without a paid Apple Developer ID. It went from idea to a public v0.1.0 release with 212 passing tests.

---

## 1. The Idea

### The problem
Email is where focus goes to die. Research that framed the project: ~120 emails/day per knowledge worker, ~28% of the workweek lost to email, only ~12% of emails contain an actual action item, ~66% of people feel inbox-stressed, ~121 notification interruptions/day, and roughly half of all inbox volume is spam/noise. The inbox is 95% noise and 5% signal, and every existing tool that fixes this does so by **uploading your mail to a server** and running it through a cloud model.

### The thesis
A **private, on-device inbox chief-of-staff** that turns the flood into 2–3 calm, actionable things — free, with nothing leaving your Mac. The moat: cloud tools (Lindy at ~$50/mo, Superhuman, Shortwave) can't ethically watch your every email-open and learn your patterns; a local app can, privately. The pitch sharpened further after WWDC 2026 revealed that Apple Intelligence now routes some work to Google Gemini in the cloud — making "100% on-device, never Gemini" an even cleaner differentiator.

### The pivot that defined everything
The original design was MiniMax (a cloud LLM) via OpenCode + Gmail OAuth. That was **dropped entirely (2026-05-24)** in favor of a fully on-device, zero-network architecture:
- **LLM:** Apple on-device Foundation Models (`SystemLanguageModel.default`), macOS 26+. No API key, no network.
- **Mail:** read Apple Mail's local Envelope Index SQLite directly (read-only). No Gmail API, no OAuth.
- **Voice:** on-device Apple Speech framework.

This pivot is the reason every later decision had to honor "zero cost, zero network."

---

## 2. Goals & Hard Constraints

These were declared non-negotiable and every feature was measured against them:

1. **Zero cost, ever.** No paid APIs, no cloud bills — for the developer or the user. This is *why* the stack is on-device Foundation Models + local Mail.
2. **Frictionless setup.** Download → working in the fewest steps. Minimal permission prompts (Full Disk Access + optional mic). No config files, no wizards.
3. **Low battery / low power.** Minimal CPU, minimal wake-ups. Prefer event-driven/coalesced work over polling. Idle cheaply.
4. **Professional & system-friendly.** Production-quality, native-feeling. No hacks that degrade the system.
5. **Privacy as the product.** Nothing leaves the machine. (The only exception, added late and disclosed: an optional once-a-day GitHub version check, toggleable.)

**How they were applied:** default every proposal to on-device/free; reject anything adding setup steps, recurring cost, or background draw; justify the power cost of any background work; keep the permission surface minimal.

---

## 3. Methodology & Working Principles

A handful of principles shaped the entire build:

- **Deterministic over LLM.** Correctness lives in code; the model only phrases. Importance ranking, money detection, follow-up classification, and "what matters" are all pure, testable code. The LLM never decides what's important — it only writes the sentence. This is why Novex is fast, predictable, and never invents urgency.
- **Validate every feature on real data.** Don't claim "done" until the output is checked against the real inbox. A feature that looks done in code but produces dumb output on real mail is not done.
- **Build only what was asked, in the approved look.** Don't over-build adjacent features or visuals.
- **Product mindset at every feature.** Think like a real user. "This is when the project becomes a product and is actually shippable."
- **Allergic to dumb output.** The user repeatedly (and rightly) rejected anything that looked dumb — and each rejection became a permanent rule (see §9, §15).

### Validation tooling invented along the way
Because the app is a headless menu-bar agent reading TCC-protected files, normal debugging didn't work. The toolkit that emerged:
- **`NSLog` → `~/Library/Logs/Novex.log`** (login-item stderr) — the reliable logging channel; `os.Logger.debug` is NOT persisted, so `log show` shows nothing.
- **`screencapture -x -R`** of specific screen regions → read the PNG to *see* the UI headlessly.
- **A dependency-free test runner** (`Sources/NovexDevTests/main.swift`, hand-rolled asserts, `swift run NovexDevTests`) because the dev machine has only Command Line Tools (no Xcode → no XCTest).
- **Gated debug flags** (`defaults write com.tarun.novex <FLAG> -bool true`) to trigger states headlessly (auto-open popover, fire a real Q&A, seed data).
- **Demo mode** (late addition) — render the real UI with realistic fake mail for privacy-safe marketing screenshots.

---

## 4. Architecture & Tech Stack

| Layer | Choice | Why |
|---|---|---|
| App shape | Menu-bar agent (`.accessory`, `LSUIElement`), `NSStatusItem` + `NSPopover` | No Dock icon; a fixed popover can't bounce/flicker like `MenuBarExtra(.window)` |
| UI | SwiftUI hosted via `NSHostingView`/`NSHostingController` | Native look, fast iteration |
| Controls | A custom `appKitTap` (NSView mouseUp overlay), **not** SwiftUI `Button` | SwiftUI `Button`'s `_ButtonGesture` → `assumeIsolated` crashed the whole app on tap |
| AI | Apple Foundation Models (`FoundationModelsClient`), on-device | Zero cost, zero network, private |
| Mail | Apple Mail Envelope Index (SQLite) + `.emlx` body files (`MailReader`, `BodyReader`) | The only on-device source of mail; no OAuth |
| Calendar/Reminders | EventKit | On-device, includes Google data synced into Apple apps |
| Voice in | Apple Speech (push-to-talk) | On-device transcription |
| Voice out | `AVSpeechSynthesizer` | On-device TTS |
| New-mail detection | `FSEvents` watcher on `~/Library/Mail` | Event-driven, near-instant, battery-friendly |
| Notification card | Borderless `NSPanel` at `.statusBar` level, all-Spaces | A floating Dynamic-Island-style card that works on any display |

---

## 5. The Data Layer — reading Mail on-device (the hardest part)

This was the single most painful and most important subsystem. Three independent, compounding bugs made the app show "Nothing recent" for days despite fresh Gmail:

1. **Stale WAL read.** Opening the Envelope Index with `immutable=1` made SQLite ignore the `-wal` file, so Novex read a frozen snapshot from whenever Mail last checkpointed (days ago). **Fix:** open `?mode=ro` (reads *through* the live WAL), with a copy-to-tmp fallback for when Mail isn't running.
2. **Wrong epoch on macOS 26.** `date_received` switched from Mac-absolute (since 2001) to **Unix** (since 1970). The 24h cutoff became meaningless and dates were off by ~56 years. **Fix:** detect by magnitude and use matching units.
3. **Gmail "All Mail" filtered out.** Gmail (IMAP) stores every inbox message under `[Gmail]/All Mail`, but an inbox-only mailbox filter excluded "all mail" → it dropped *every* Gmail message. **Fix:** keep "all mail"; only exclude junk/spam/trash/sent/drafts. **Invariant: never re-add "all mail" to the exclusion — it nukes the whole Gmail inbox.**

They *compounded*: even after fixing WAL and epoch, the Gmail filter still zeroed everything. Diagnosed via temporary `NSLog` diagnostics read from `Novex.log`.

**Bodies live on disk, not in the DB.** A `summaries` table has a preview but only covers ~10% of recent mail. Full bodies require parsing `.emlx` files, located (without a full directory walk) at `…/Data/<digits of rowid÷1000, reversed>/Messages/<rowid>.emlx`. `BodyReader` parses the `.emlx` (strips the byte-count line + trailing plist), handles multipart, and (a gotcha) decodes quoted-printable into a `[UInt8]` then UTF-8 — decoding byte-by-byte to `Character` is Latin-1 and mojibakes every multi-byte sequence.

**Apple's own ML signals** (`message_global_data`, joined on the integer `message_id`): `model_high_impact` (populated, ~7% of mail), category, urgent/follow-up (empty on this Mac). These feed the ranking engine.

### The ranking engine (the heart of the product)
`MailMessage.importanceScore` is pure code: `isUrgent +100, isHighImpact +80, needsFollowUp +60, !isRead +40, isFlagged +30`, minus heavy penalties — `automatedType≥2 −45`, `unsubscribeType>0 −35`, and the decisive `isNotificationSender −50`. A message is "important" at score ≥ 30. The briefing runs the LLM **only** on important mail; when nothing clears the bar, it says "nothing needs you" instead of manufacturing signal. Plus learned nudges: VIP bonus, sender affinity, and owner-model interest overlap — all of which *nudge* but never override the noise penalty.

---

## 6. Feature-by-Feature Journey

Each feature followed the same arc: **idea → build → refine on real data → validate.**

### Daily briefing
The core. Ranks mail deterministically, collapses duplicate notifications (Figma/LinkedIn send many for one thing), features only genuinely important threads, and shows a calm "all caught up" when the inbox is noise. **Refinement:** the first version featured pure noise as "important" — the user said "the analysis is dumb." Root cause: the automated penalty was too weak (automated unread netted positive). Strengthened the penalties so automated mail nets negative; the LLM now runs only on important mail. *Lesson: a good assistant says "nothing needs you" when the inbox is noise.*

### Conversational assistant voice
The user: "it should be like an assistant person who gives the update, not a notification drawer." Researched the market (Shortwave's conversational executive-assistant briefing, Superhuman's one-line summaries). Redesigned so the briefing leads with a time-of-day greeting + a synthesized conversational line ("Three things need you — reply to Sarah…") instead of a clinical status + raw list. The summary for a quiet inbox is **deterministic** (`casualSummary`) so it can never be dumb.

### Smart Reply
Tap a reply-needed item → Novex drafts a contextual reply in your voice, editable with Shorter/Warmer/Formal re-rolls, handed to Mail via `mailto:`. Later upgraded to **pre-draft** the top reply in the background so it's already waiting (the "assistant did the work" moment). Prompt-injection hardened. **Hard rule:** never drafts to no-reply/bot senders (see §9).

### Follow-up Radar
Reads across all mailboxes including Sent, derives "my addresses" from Sent senders, and classifies threads: *needs your reply* (they wrote last) vs *waiting on them* (you wrote last). Tap any thread → on-device "Catch me up" TL;DR.

### Declutter & Unsubscribe
Groups inbox newsletters by sender, one-taps the **real** `List-Unsubscribe` header parsed from the `.emlx`, and offers a local Mute that hides a sender everywhere.

### Money Radar (three iterations)
Detects subscriptions and trials-about-to-charge from receipt emails — no bank login. **v1:** catalog guesses. **v2:** reads the *real* charged amount from receipt bodies (fetches only candidate bodies — can't open 1500 files), plus Cancel links for 40 merchants. **v2.1:** false-positive hardening — excludes tax invoices/income/statements, per-currency plausibility ceilings, per-currency totals (never sums ₹ and $). *Lesson: a wrong number is worse than no number.*

### Owner model (the differentiator)
A deterministic, on-device model of what *you* care about — interest tokens learned from mail you open and star, plus interests you set at onboarding. It nudges ranking and powers Discover. No LLM guessing; counts only.

### Discover ("Worth a look")
Surfaces the genuinely interesting reads buried in the newsletters you already get, matched to your interests. Pure/deterministic; stays *empty* when nothing matches (no noise). Live external news was **rejected** — it would break zero-network. *Lesson: the privacy promise outranks a nice-to-have.*

### Ask Novex (Q&A → chat)
Originally a one-shot Q&A that **dumped raw email bodies** with rows of asterisks instead of answering — embarrassing. Rebuilt as a **chat interface**: question bubbles + answers, short context (subject + ~110-char snippet, not full bodies), a strong "never paste/list/asterisks" instruction, and `tidyAnswer` post-processing. Reads a wide 60-day window and ranks by query-term coverage so it can answer about weeks-old mail.

### Reminders & Calendar
EventKit, on-device. Shows "what's next" and "on your plate" alongside mail — including Google Calendar/Tasks if synced into Apple's apps.

### Text-to-speech voice
`AVSpeechSynthesizer` reads the briefing aloud. **The big learning:** the user said it sounded robotic. Root cause discovered by enumerating installed voices: the Mac had **only "compact" voices** — no enhanced/premium one — so the picker had nothing better to choose. The real fix is a free, one-time Premium voice download; Novex now detects this (`hasNaturalVoice`) and surfaces a "Get voice" button in Settings. *Lesson: robotic TTS on macOS = no premium voice installed, not a code bug.*

### The notification card (the notch saga)
A Dynamic-Island-style card that drops in for new important mail. This went through *many* iterations (see §8). The endpoint: a clean, self-contained floating rounded card that does **not** depend on the notch (so it works on any monitor, notch or not), positioned by computing the menu-bar height per display.

### The fly-to-Novex dot animation
The user's creative ask: a new-mail card collapses into a dot that flies along an arc to the menu-bar ✦ icon, dissolves, and the panel opens to that mail. Built with a borderless panel hosting a SwiftUI dot, a 120fps timer doing eased lerp + a downward arc dip + a size swell, dissolving on arrival. Iterated heavily on speed and feel; finally paired with the panel's native scale-open (the "Blip-style flip") so the dot dissolves *into* the icon and the panel scales *out of* it. Tunable/toggleable in Settings.

### Wake / unlock greeting
On wake-from-sleep or screen-unlock, Novex greets you with what you missed via a notch card — and stays **silent if nothing needs you** (no notification spam). Throttled to once / 10 min.

### Immediate-notification watcher
The user's sharp question: "if I get a new mail, do I get notified immediately?" The honest answer was *no* — the refresh loop only ran while the panel was open. **Fix:** an `FSEvents` watcher on Mail's store fires a refresh (and the card) within ~2–3 seconds of any new mail, panel open or not. Event-driven, so zero battery cost while idle.

### Update check
The only network touch. An anonymous, at-most-once-a-day GET to GitHub's public Releases API; if a newer version exists it surfaces a card in the daily briefing. Off-switchable. This is the one place the "zero-network" claim is softened — and the README discloses it precisely.

---

## 7. The Big Refinements & Pivots

### The notch shape saga (3+ iterations)
Getting the notch panel to look right took many rounds of user feedback:
1. Inverse/concave top corners → looked like a broken "double-notch" (rejected).
2. Convex/external rounded top corners → looked like a card floating detached in the middle (rejected: "what is this").
3. Flush top + rounded bottom → fused with the notch correctly. *Lesson: for a notch panel, never round the top corners — flush top = attached; any top rounding = floating.*
4. Then a "notch-flange" emerge shape → an ugly anvil/T (rejected), and — crucially — it was **notch-dependent**, which breaks on non-notch monitors.
5. **Final pivot:** drop notch-shaping entirely → a clean, self-contained floating rounded card (Dynamic Island style), monitor-independent. The user was right twice: the shape *and* the dependency were wrong.

### Liquid Glass attempt + revert
Tried the macOS 26 Liquid Glass (`.glassEffect`) for the card and the flying drop — it looked premium but the user said "remove it, we'll figure it out later." Reverted to solid black. *Lesson: ship the agreed look; park the experiment.*

### The rename: Aura → Novex
The app was "Aura" for most of its life. For the public launch the user wanted a unique, short, meaningful name. After two rounds of suggestions, **Novex** was chosen — "the most important point," and also Latin for *cross* (the Southern Cross constellation), which ties to the app's dot/sparkle motif. A full global rename followed: Swift targets (`NovexCore`/`Novex`/`NovexDevTests`), bundle id `com.tarun.novex`, app name, launchd label, log file, signing cert, every UI string. The bundle-id change reset Full Disk Access (a known, one-time cost).

### The logo
Designed in CoreGraphics (zero cost, no art tools). After two batches of concepts (constellation, crosshair, sparkle, convergence, navigator star, monogram), the user chose **"Convergence"** — rays distilling inward to one glowing novex point, with a subtle cross baked in. Rendered at every icon size via `iconutil`.

---

## 8. The Recurring Core Bug — bots vs people

The single most repeated piece of feedback, across weeks: **Novex kept treating automated notification emails as human conversations.** It drafted a reply to a no-reply Fiverr tax-doc, featured an already-read 2FA code as "important," and produced a nonsense "catch me up" on a Slack notification.

Root cause: Apple's `automated_conversation` flag misses many no-reply/notification senders, so they slipped past the penalty. **Fix:** one source of truth — `MailMessage.isNotificationSender` (a sender address/name heuristic) and `isReplyable = !isNotificationSender` — wired *everywhere*: importance scoring (−50), the reply action downgraded to "read" for non-replyable, prepared drafts gated, and Follow-up Radar's "wants reply" using it (so Slack/2FA never appear).

**The invariant that came out of it:** reply/draft/feature ONLY for real people. An assistant must distinguish a *person* from a *bot* — only humans get replies, only humans' mail is "needs you." This was the user's core point all along.

---

## 9. Struggles / What Went Wrong

- **The mail-reading trifecta** (§5) — three compounding bugs that masqueraded as "sync is broken" for days.
- **A whole-app crash on every button tap.** The app launched via a manual `NSApplication.run`, which never registered the main thread as the main-actor executor, so any SwiftUI `Button` action segfaulted (`assumeIsolated`). Latent because buttons were never click-tested headlessly. **Fix:** a real SwiftUI `App`/`Window` scene owns the window; all controls use the custom `appKitTap` instead of SwiftUI `Button`.
- **Ad-hoc signing revoked Full Disk Access on every rebuild.** macOS keys TCC to the code-hash, which changed each ad-hoc build. **Fix:** a stable self-signed "Novex Local" cert so FDA persists across rebuilds. (It also caused false "mail stopped syncing" diagnoses.)
- **"The analysis is dumb."** Featuring all-noise inboxes as important (fixed via stronger penalties).
- **Injecting fake content into the live UI.** A debug "Mercor" peek left on during development confused the user into thinking it was real. *Lesson: never leave fake/placeholder content visible in the live UI.* (This later informed the *correct* way to fake data — a gated demo mode used only for screenshots.)
- **The notch blocking clicks.** The panel intercepted clicks in the top-center of the screen. *Invariant: a notch/menu-bar overlay must be 100% click-through unless actively showing something.*
- **The harness occasionally fabricated tool output** (fake "build complete," phantom code in file reads). Ground truth was re-established via `grep -c` of code markers + actual `swift build`/`swift run` exit codes. *Lesson: trust deterministic short outputs and build/run results over long file dumps.*
- **TCC blocks the agent shell from `~/Downloads`, `~/Desktop`, `~/Documents`** — media had to be copied into the project folder or `/tmp` to be readable; screen-recording filenames contain a non-breaking space (glob, don't type the name).
- **The GIF, twice.** First too short (didn't show the panel opening); then a damaged-looking encode from heavy dithering on a photographic wallpaper. Fixed by capturing a bigger region and a cleaner palette.

---

## 10. What Went Right

- **The deterministic-ranking architecture.** "Reasoning in code, phrasing in the model" made the app fast, predictable, testable, and immune to LLM hallucination — and it works even with zero AI available.
- **The test discipline.** A dependency-free runner grew to **212 passing checks** covering ranking, money detection, follow-up classification, prompt-injection sanitization, and more.
- **The privacy story held up under audit.** A full security review confirmed: zero network (bar the opt-in update check), no email content ever logged, parameterized SQL, prompt-injection tested, no force-unwrap crashers, no hidden paywall.
- **The validation loop.** `NSLog` + `screencapture` + gated flags + the test runner made a headless menu-bar agent genuinely debuggable.
- **Demo mode for screenshots.** Rendering the *real* UI with fake data produced marketing shots that are authentic *and* leak no private inbox content — far better than pixel-editing.

---

## 11. Validation & Testing Approach

- **`swift run NovexDevTests`** — 212 hand-rolled assertions, no XCTest/Xcode needed, runs on the user's machine too.
- **`NSLog` → `Novex.log`** for runtime tracing (the only reliable channel).
- **`screencapture -x -R`** + reading the PNG to verify UI headlessly.
- **Gated debug flags** to trigger states without a GUI.
- **Real-data validation** at every feature — the inbox being "100% automated noise" was itself a great test case (it proved Novex correctly says "nothing needs you").
- **Honest caveats** when something couldn't be validated headlessly (the flight feel, TTS audio) — those were handed to the user to test.

---

## 12. Security & Readiness Audit (pre-launch)

| Area | Result |
|---|---|
| Network calls | Zero (only the opt-in update check) |
| Email content logging | None |
| SQL (Mail DB) | Read-only, parameterized, no untrusted interpolation |
| Prompt injection | Sanitized + fenced + tested (a malicious newsletter can't hijack the model) |
| Crash risks | No `try!`/`fatalError`/force-unwraps in app code |
| Paywall / gating | None — license code removed for the OSS launch |
| Sandbox | Intentionally non-sandboxed (needs Full Disk Access; correct for a notarization-free Mail app) |
| Graceful AI fallback | All AI calls guard availability; the app stays useful without Apple Intelligence |

**Verdict: functionally ready to ship.**

---

## 13. Open-Source Launch

- **License:** MIT.
- **Distribution model (the free path):** modeled on Battery-Toolkit and muffon — **self-signed, NOT notarized** (no paid Apple Developer ID). Users either build from source (no Gatekeeper prompt at all) or download the release and do a one-time right-click → Open (or `xattr -dr com.apple.quarantine`). A Homebrew cask template is included.
- **The README** is the storefront: hero, badges, the privacy story, a feature table, a "See it" gallery (the animation GIF + Money Radar + Ask Novex), an account-connectivity section (Gmail/iCloud/Outlook/Yahoo/IMAP via Apple Mail + Calendar/Reminders), three install paths, step-by-step setup, a day-to-day user guide, an FAQ, and a roadmap.
- **Screenshots:** generated via the gated demo mode (real UI, fake mail) so nothing private is exposed.
- **A late polish pass** removed every em-dash, en-dash, unicode-minus, and middle-dot from the README — small punctuation tells that read as machine-written — and tightened/resized the images.
- **Shipped:** public repo at github.com/Tharuntejandhe/Novex with a **v0.1.0 release** carrying `Novex.zip`, which lights up the README download link, the Homebrew cask, and the in-app update check.

---

## 14. Key Learnings & Invariants

A distilled list of the rules this build earned the hard way:

1. **Reasoning in code, phrasing in the model.** Never let the LLM decide what's important.
2. **Say "nothing needs you" when the inbox is noise.** Don't manufacture signal.
3. **Distinguish a person from a bot.** Only humans get replies; only humans' mail is "needs you."
4. **A wrong number/deadline is worse than none.** (Money Radar, deadline extraction.)
5. **For a notch panel, never round the top corners** — and don't make the UI depend on the notch existing.
6. **A menu-bar overlay must be click-through unless actively showing something.**
7. **Never leave fake/placeholder content in the live UI.** If you must fake data, gate it and use it only for screenshots.
8. **Ad-hoc signing churns TCC permissions** — use a stable self-signed cert so Full Disk Access persists.
9. **macOS 26 changed the mail epoch to Unix, and Gmail lives under "All Mail"** — both will silently zero your data if mishandled.
10. **Robotic TTS = no premium voice installed,** not a code bug.
11. **`NSLog`→file beats `os.Logger` for a login-item agent;** `grep -c` + build/run exit beats trusting long tool dumps.
12. **The privacy promise outranks features** — external news was cut to keep zero-network honest.

---

## 15. Future Improvements / Roadmap

- **More on-device connectors** — surface Slack/Discord from the local Notification Center store (the private way, no cloud API). Mirroring other apps' notifications needs restricted private APIs, so this is bounded.
- **App Intents / Siri & Shortcuts** — blocked on this build setup (the `appintentsmetadataprocessor` ships only with full Xcode, not Command Line Tools), so intents would compile but never register. Revisit with full Xcode.
- **Optional Liquid Glass theming** on macOS 26 (the experiment we parked).
- **Per-feature scheduling** for the daily digest.
- **Light-mode option** (currently an intentional always-dark HUD).
- **Cold-start bootstrapping** of the owner model from Sent mail (it currently learns from opens + stars, which is sparse early).
- **Notarization** if a paid Developer ID ever makes sense (removes the one-time Gatekeeper step).

---

## 16. Stats & Timeline (abridged)

- **Language:** Swift end-to-end (single signed `.app`, no Python).
- **Tests:** 212 passing checks, dependency-free runner.
- **Distributable:** `Novex.zip` ≈ 2.4 MB.
- **Network calls in the whole app:** effectively zero (one optional, anonymous, daily update check).

**Timeline of major milestones:**
- *2026-05-24* — pivot to fully on-device / zero-network.
- *2026-05-28* — hard constraints locked; power-aware refresh; signing/FDA strategy.
- *2026-06-01* — the button-tap crash fixed via a real SwiftUI scene.
- *2026-06-02/03* — mail-reading trifecta fixed; the deterministic ranking engine.
- *2026-06-08* — feature-complete v0.1 (4 tabs + assistant features); prompt-injection hardening; Money Radar v2.
- *2026-06-09* — real `.emlx` bodies; whole-inbox Q&A; the notch prototype.
- *2026-06-10* — notch becomes notification-only; conversational assistant voice; the "four smart features"; the briefing-quality fix.
- *2026-06-12* — Q&A → chat; owner identity & interest learning; Reminders; the bots-vs-people gate; the fly-to-Novex animation.
- *2026-06-13* — rename to Novex; logo; Discover; voice fix; the FSEvents watcher; wake greeting; demo-mode screenshots; security audit; **public v0.1.0 launch.**

---

## 17. Credits

Built by **Tharun Tej × Claude**.
Free and open-source under the MIT license. Your mail is yours; so is this code.
