# BrowserDaddy — project status

## 2026-09-27 — 0.4.7 build 16: windowless routing, invisible after setup

Protected release run 36319870382 signed, notarized, stapled, launched,
and published source `9d3d8fb` as 0.4.7 build 16. Public DMG verified
SHA-256 `4bf7c059fa236d0cdc1b8d12790fc76e0db211806c7ce65b6620f3b23e2560eb`;
installed to /Applications and live-verified: launch opens 0 windows, a
routed link opens a background tab and restores focus to the clicker.
macOS floor is now 15 (`Scene.defaultLaunchBehavior` requirement;
LSMinimumSystemVersion updated). Details below.

Clicking a link registered to BrowserDaddy no longer flashes the main
window: the WindowGroup carries `.defaultLaunchBehavior(.suppressed)`, so
a GURL launch is purely a routing pipe. `openWindow` is captured eagerly
from the menubar icon (the only eagerly-rendered view) since the main
window may never exist — Dock/⌘-tab reopen and the menu's "Open
BrowserDaddy" still create it. Links that arrive while the UI is already
up (e.g. History's "Open URL") no longer hide the app — UI state is
snapshotted at URL receipt and only launch-created surfaces are torn
down. A 3s window after each URL event suppresses racing reopen events.
Deployment floor moved to macOS 15 (the suppression API's requirement —
SceneBuilder can't branch on runtime availability).

Routed links also open as *background tabs* — `/usr/bin/open` now carries
`-g` on every silent route so the destination browser never comes
forward. Explicit picks keep foreground behavior (`BrowserOpener.open`'s
`foreground:` flag — hotkey picker, DnD "Send to"). Since a background
route plus LaunchServices' delivery-activation would strand focus on a
windowless handler, the last non-self frontmost app is tracked
(seeded at launch — the clicker predates us — and kept fresh via
didActivateApplicationNotification) and re-activated after routing.
`keySenderPIDAttr` is absent on LS-delivered GURLs, so activation history
is the fallback. Verified live: cold launch 0 windows, GURL 0 windows
and focus back in the clicker, reopen 1 window, GURL-with-window keeps
the window. 59 tests green; build warning-free.

Invisible-after-setup: the clipboard watcher (passive picker on every URL
copy) is gone — the picker now only exists for explicit invocations
(⌃⌥O, ⌃⌥Space, menu). `clipboardWatch` dropped from RouterConfig (old
stored configs ignore it); the panel's passive mode removed with it. One
launch-window exception: an un-onboarded app opens its window ~1s after
launch so first-run setup is reachable; once `onboarded=1` nothing ever
surfaces on its own.

Production verification battery (installed build): http/https handler
registered to the release bundle; copy produces no UI and no browser;
rapid-fire GURLs route without windows or crashes (none in
DiagnosticReports); quit-with-window + relaunch still yields 0 windows
(state restoration honors `.suppressed`); runtime activation policy is
accessory — menubar-only, no Dock tile or ⌘-tab entry.

## 2026-09-27 — deep audit pass 2 (local, unreleased)

Continued the bug sweep into the last unreviewed surfaces. FocusWatcher's
private-window gate now covers every Chromium browser (was Chrome-only —
Brave/Edge/Vivaldi/Arc/Opera/Chromium focus was app-only despite their
sdefs exposing `mode`; scripts still fail closed where `mode` is absent).
Permission probes switched to `AEDeterminePermissionToAutomateTarget`
non-interactively — a `count windows` AppleScript probe could have fired
consent prompts for every running Chromium browser just by opening
Permissions. Safari tab actions now write per-request result files
(two rapid close/focus ops previously overwrote each other's result and
the loser timed out with "did not confirm" after the tab already closed).
Site-cap alerts match subdomains (`youtube.com` cap counts
`www.youtube.com`; lookalikes like `notyoutube.com` don't match) and the
Add field accepts pasted URLs, normalized to host[:port]. Classifier tag
writes moved into `writeTransaction` (atomic, rollback on mid-batch
cancel/error). Route patterns with a path segment ignore query/fragment
on the host+path glob. Stale copy fixed in Onboarding/Permissions/Alerts
to reflect Chromium-family coverage. 58 tests green; build warning-free.

## 2026-09-27 — clipboard-focus bugfix pass (local, unreleased)

Owner report: copying a link sometimes opened a browser on its own. Root
cause: the clipboard watcher showed the picker with `NSApp.activate()` and
key status, so the next keystroke (⏎/digit — modifiers ignored, so even ⌘1)
silently confirmed a target. The picker also spawned under the pointer.
Fix: picker is now modal-split — clipboard-driven shows are passive
(non-activating, non-key, top-of-screen, click-only, auto-dismiss) while
⌃⌥O/⌃⌥Space keep the interactive keyboard flow. Other fixes in the same
pass: self-triggering Copy-URL buttons, `BrowserOpener` stderr-pipe
deadlock, `closeTabs` index-shift (now closes descending), scheme-less
slash route patterns, incognito `mode` filter extended to all
Chromium-family tab scripts, SQLite step-error/null/URI-escaping fixes,
`BEGIN`-leak rollbacks via `writeTransaction`, legacy Python archive
importer wired into `runExtract`, 1-day streak counting, empty-frontmost
focus rows, and hardcoded tick intervals. 62 tests green; `swift build`
warning-free.

## 2026-09-26 — 0.4.6 build 15: background routing and Safari tabs

Clicked HTTP(S) links still use ordered rules and fallback, but launch as a
windowless menu bar utility and register the GURL handler before launch URLs
arrive. A copied HTTP(S) URL now opens the floating target menu; choosing a
browser opens it, while dismissing the menu does nothing. Safari tab inventory
uses a bundled Safari App Extension that checks Private Browsing before reading
or sharing page URLs and titles. The old Safari AppleScript tab and current-tab
paths are disabled. Safari tab access remains optional in Safari Settings.

Focused router and tab tests, the full 44-test Swift package suite, Release
build, and stable Xcode 26.6 universal extension build passed. An isolated
native preview showed the copied-link menu without surfacing the main window
and cancellation opened no browser. Protected release run 36244668955 signed,
notarized, stapled, launched, and published source `1aac8e3` as 0.4.6 build 15.
The public DMG and feed passed live byte verification; the downloaded DMG
matched SHA-256 `5d755c66b41960e1066a06b17b84412136df8d339567b6c4e2767bac2f310984`
and local Gatekeeper/stapler checks. An isolated signed test copy is staged.
Installed default-handler and enabled Safari extension checks remain tracked
in GitHub issue #25.

## 2026-09-25 — 0.4.0 build 5: link router + tabs shipped

Released the link router, picker, and Tabs workspace described below.
Universal DMG `BrowserDaddy-0.4.0-5-universal.dmg`, Developer ID signed,
hardened runtime, notarization `3814a25e` accepted and stapled; installed
to /Applications. Hardening applied during verification: `open -b` alone
silently drops URLs and `open -n` spawns duplicate app instances —
non-profile targets now use `open -a <path>` (cryptex apps resolve through
the /Applications stub) plus explicit activation; profile targets keep
`-n -b --args`. Copied links route like clicked links (rules → fallback);
the picker is explicit-hotkey only and auto-dismisses on focus loss.
Automation denials re-fire the real consent prompt. BrowserAccess resolves
non-scoped bookmarks and accepts readable paths when scope can't start.
`run-local.sh` embeds Sparkle and dev-signs with a stable identity so TCC
grants survive rebuilds. Dock reopen rebuilds the main window. GitHub
feed/tag publication still pending.

## 2026-09-25 — link router (local, unreleased)

New link-routing feature, tracked in GitHub issue #6 and implemented on top
of 0.3.1. BrowserDaddy can now be the macOS default browser: `CFBundleURLTypes`
declares http/https and a GURL AppleEvent handler routes every clicked link
silently — first ordered rule wins, else the configured fallback target (never
the default-handler path, which would loop). Rules match host globs and
full-URL globs, case-insensitive, and land in a browser+Chromium-profile
target opened via `/usr/bin/open -na --args --profile-directory=`.

Explicit picks go through a floating picker panel, reached three ways: a
clipboard watcher (0.4s pasteboard poll, gated on a browser being frontmost)
auto-opens rule-matched copies and pops the picker otherwise — verified live
by copying a `routeme.dev` link in Safari straight into Brave with zero
keystrokes; ⌃⌥O picks for the copied link; ⌃⌥Space reads the frontmost
browser's active tab (AppleScript; Chrome and Brave incognito windows are
refused via the verified window-mode check — both sdefs expose `mode`).
Carbon `RegisterEventHotKey` drives the hotkeys — no accessibility grant
needed. Router workspace (SETUP → Router) edits
rules, fallback, and manually declared profile dirs; discovered profiles
come from `Local State` inside connected grant roots only. Config persists
in `meta.router.config`.

Same session added the LIVE → Tabs workspace (issue #7): `TabInventory`
enumerates every open tab per scriptable browser via AppleScript
(Chrome/Brave incognito filtered by window mode, Safari/Firefox limits
disclosed), with close/focus verbs, multi-select bulk close, search filter,
context-menu Send-to, and drag-onto-browser-section moves (open in target,
close source only on success). Auto-refreshes every 15s while visible.

`BrowserCore/LinkRouter.swift` carries RouterConfig/RouterStore/RuleEngine/
BrowserOpener/ProfileDiscovery/FrontmostTab; `LinkRouterService` + panel +
`RouterView` live in the app. `run-local.sh` now embeds Sparkle.framework
(the dev bundle previously crashed on launch without it). 53 package tests
pass (11 new). Verified live: GURL → Safari fallback and a `routeme.dev`
rule → Brave both opened correctly. Picker hotkeys, profile-targeted opens,
and release-sandbox entitlement review remain unverified on-device;
superseded by the 0.4.0-5 release entry above.

## 2026-09-22 — 0.3.1 build 4: guided connect + faster auto-sync

Onboarding/Permissions now give exact per-browser folder directions and a
"Connect all detected browsers" wizard walks each unconnected browser with
the panel pre-opened at its data folder — the user-mediated pick stays the
security grant (sandbox boundary unchanged). Re-extract cadence 6h → 30min
plus a stale-check sync on app activation. Settings gains "Review first-run
setup" replay; finishing a replay extracts new grants immediately.

Universal DMG, Developer ID signed, notarization `f658a119` accepted, stapled.
Feed republished (sparkle:version 4). Tag `v0.3.1-4`, private GitHub release.

## 2026-09-22 — 0.3.0 build 3: attention alerts + sync feedback

Owner report: "Sync History" appeared dead and live mode seemed off. Evidence
showed the watcher was healthy (focus rows seconds old) but the app had zero
browser-folder grants, so sync was a no-op whose only feedback rendered on
Permissions. Fixes: last extract-log line now shows in the global status bar;
connect accepts a directly-selected profile dir (Chrome/Default, a Firefox
profile); the NOW card no longer calls a tab-less browser "not a browser";
and the watcher holds a `userInitiatedAllowingIdleSystemSleep` activity token
so App Nap cannot suspend polling.

New `AlertEngine` (BrowserCore) fires local UNUserNotificationCenter alerts on
persisted thresholds: focused minutes/day, per-site caps, unbroken-page
streaks, and a separate agent-suspected tally (scriptable-browser URL churn
with <5% input — non-Chrome browsers can't qualify, disclosed in UI). Rules
fire once per day and survive restart via `meta` markers. Config lives in
`meta.alerts.config`; editable in the Permissions ALERTS band and the new
Settings scene (⌘,). Delivery is injected so tests stay hermetic; 37 package
tests pass (7 new).

Release: universal DMG, Developer ID signed, notarization `8028766a` accepted,
stapled; SHA256 `864b2c9e…36dd99`. Feed republished via prepare-appcast →
`site/public/updates` → `wrangler deploy` (build number bumps to 3 — Sparkle
compares `sparkle:version`, so builds are global-monotonic, not per-version).
Tag `v0.3.0-3` pushed; private GitHub release holds the DMG.

## 2026-09-20 — first update release 0.2.2 build 2

BrowserDaddy 0.2.2 (build 2) is the first Sparkle-enabled release. Universal
arm64/x86_64 DMG, Developer ID signed with hardened runtime, Apple notarization
accepted (submission 88eec1dc-fcbc-4149-85d1-65f3860da599), stapled and
Gatekeeper-validated. Build 2 replaces the unpublished-to-users build 1 after
independent review found the sandboxed app lacked
`SUEnableInstallerLauncherService` and the `-spks`/`-spki` mach-lookup
entitlements Sparkle requires to install updates in a sandboxed host. The signed appcast was generated via
`scripts/prepare-appcast.py` and is served live at
`https://browserdaddy.significanthobbies.com/updates/appcast.xml` by the
`browserdaddy-updates` Worker; the Ed-signed enclosure downloads verified.
Notarization credentials were restored to Keychain as the
`fleet-personal-notary` profile (from Infisical). SHA256SUMS records the final
stapled artifact since stapling rewrites the DMG.

## 2026-09-20 — daddy-series update stack

BrowserDaddy now shares the daddy-series structure and Sparkle update stack
with storagedaddy and performancedaddy (issue
sarthakagrawal927/storagedaddy#30): Sparkle 2.9.6 pinned, `AppUpdates` defers
checks and relaunches while a history sync is in flight, update items live in
the app menu, `SU*` keys are injected at packaging by
`scripts/package-release.py`, and `scripts/{sparkle_support,prepare-appcast,
test_sparkle_support}.py` match the sibling repos. An updates-only Worker owns
`browserdaddy.significanthobbies.com/updates/*` — deployed and verified live
alongside the ios-landings Pages site; the feed is a dormant empty channel
until the first release publishes an enclosure via `prepare-appcast.py`, which
gates on a signed, notarized, stapled DMG plus SHA256SUMS. EdDSA signing key
`browserdaddy-updates` stays in Keychain; only the public key is committed.
CI parity added (`swift test`, release build, sparkle unittest, worker test).
All package tests plus sparkle and worker tests pass.

## 2026-09-20 — expandable history, retagging and composable filters

History now combines text, browser, browser/profile, rolling date range,
effective category and tag-state filters in one parameterized local query.
Rows disclose source, exact visit time, full URL, separate page/domain categories
and whether each tag came from the user or classifier.dev. A visible Retag sheet
supports exact-page, exact-domain and registrable-domain overrides plus scoped
clearing. These operations change only derived archive metadata; they never edit
browser history or make a network request. Optional external classification stays
separate in Permissions behind consent v2.

Synthetic native verification covered expansion, accessible labels, scope switching,
filter menus/count/clear behavior and a saved local tag immediately leaving the
active untagged result set. No personal browsing data or real classifier request was
used. The design receipt passes in preserve mode and all 30 tests pass. Source is
pushed at `fc5a59f` and a universal Developer ID signed 0.2.1 build 4 candidate has
valid hardened-runtime sandbox entitlements and macOS 14 arm64/x86_64 slices.

Apple accepted app submission `cceadcd6-cb7d-4be4-93a8-5a79316d4657` and final
DMG submission `e559de82-4470-4766-87bd-adfdad583e0c`. Both artifacts were stapled
and Gatekeeper accepted them as Notarized Developer ID. The signed `v0.2.1-4` source
tag points at `fc5a59f`; its private GitHub release contains the final DMG and checksum
(`5672146c820c2044beb94065650bd69b91709a705f255eb8fd9e423efba42c17`). Installed
BrowserDaddy is now 0.2.1 build 4; the prior app bundle is recoverably retained under
`.build/BrowserDaddy-0.2.0-3-before-0.2.1.app`. The sandbox archive was not replaced;
its SQLite integrity check passes with 109,698 visit rows and 524 focus rows. Tracking:
GitHub issue #5.

## 2026-09-20 — browser-scoped folder grants

BrowserDaddy no longer requests Full Disk Access or scans browser locations
implicitly. Each connected browser uses a user-selected, read-only,
security-scoped folder bookmark. Discovery is restricted to that resolved root,
rejects symlink escapes and validates that the folder contains the expected
history database before persisting a grant. Disconnect stops future reads while
preserving already archived rows. The release entitlement set now enables App
Sandbox, read-only user-selected files, app-scoped bookmarks, outbound networking
for the optional classifier, and the Chrome-only Apple Events exception.

The first sandboxed release includes Apple's container migration manifest for the
existing BrowserDaddy Application Support directory. A separate sandbox probe
using a synthetic Chromium database verified onboarding, persistent bookmark
resolution after relaunch, extraction, and archive retention after disconnect.
No personal browser folder was selected or personal screenshot captured. All 26
Swift package tests pass.

Universal 0.2.0 build 3 was Developer ID signed, notarized and stapled. Apple
accepted the app submission `5dcba543-bb61-4907-8951-23d84fe6d15c` and final DMG
submission `d3dc616b-2430-47e3-8caf-3600f13fa83e`; Gatekeeper accepted both. The
installed 0.1.0 app and archive were backed up before replacement. On first launch,
macOS moved the archive into the stable sandbox container; SQLite integrity passed
and aggregate rows matched the backup (with one expected new focus row after the
watcher started). The legacy archive backup remains under Application Support.
Installed 0.2.0 build 3 launched as PID 82508 and remained running. Tracking:
GitHub issue #4. Actual browser-folder selection and owner-observed Chrome
normal/private-window acceptance remain before any public download.

## 2026-09-20 — signed native candidate and corrected optional consent

Owner approved optional external classification with accurate, revocable consent.
Consent v2 discloses hostnames, truncated titles and paths, network-address exposure,
and that sent data cannot be recalled. Requests are not described as anonymous.
Legacy opt-ins require renewal; revocation cancels the retained task and prevents
remaining requests. Response shape/label/confidence validation fails closed, including
extra/missing result counts. URL credentials/query/fragment are excluded from URL
hints; the remaining text may still contain personal information. Local features
remain independent. A failed archive open now shows recovery guidance instead of
force-crashing. Twenty-two synthetic tests pass; no real classification request was made.

Universal 0.1.0 build 2 targets macOS 14 (both Mach-O slices verified), uses the
Tab Scout icon and stable `com.significanthobbies.browserdaddy` release identity,
and is Developer ID signed with hardened runtime and the Apple Events entitlement.
Apple notarization `bfe584c6-13cf-4b44-8622-49152ce6f564` was Accepted. App and DMG
stapling and Gatekeeper checks passed. Installed app signature/ticket verified;
native launch returned PID 65420 and the process remained running on follow-up.
The old development app bundle is preserved under `.build/pre-release-app-backup-20260920/`.
No archive was deleted/replaced, permission grants approved, or personal screenshots taken.

This is a native prerelease candidate, not a fully qualified public release.
Real private-window exclusion and new-identity permission-flow acceptance remain;
no public landing download is enabled. Tracking: GitHub issue #3.

## 2026-09-20 — Tab Scout brand integration

Owner delegated the choice after three visual systems. Tab Scout now owns the
native compact mark, larger artwork and macOS icon, with independent copies in
ios-landings. Existing black/mint controls and the Editorial landing are preserved.
`scripts/build-icon.sh` regenerates native ICNS representations. Source assets
were generated with the built-in image tool; no personal browsing screenshots
were used. Landing inspected at 390, 768 and 1440px. Independent scoped reviews:
36.7/40 visual (normalized), 18/20 technical, 92/100 landing comprehension;
no branding P0/P1 found. This is not native release/privacy qualification.


## 2026-09-20 — bounded privacy fixes; release still blocked

Collection now waits for onboarding completion and starts only once. Keyboard
history sync cannot bypass onboarding. Chrome tab capture checks its immutable
window mode before reading tab URL/title; unavailable/private captures immediately
close the old URL segment. Other browsers remain app-only until their private
window detection is qualified, and do not receive unnecessary automation probes.
The report test now uses a synthetic temporary archive, never the user's real DB.
All 15 Swift package tests pass, including onboarding, capture policy, persisted
segment transitions and report fixtures. Chrome mode semantics were checked in
the installed scripting dictionary; real private-window runtime acceptance is
still outstanding. No personal archive was read for testing.

Native release remains blocked: the optional external classifier conflicts with
the written no-network policy, its disclosure omits transmitted paths, and opt-out
does not cancel an in-flight batch. Owner asked to choose local-only or a qualified
optional-network boundary. No app was signed, notarized, installed or released.
The historical privacy blocker above was addressed by the later consent-v2 candidate;
runtime acceptance remains. Tab Scout was subsequently selected and integrated.

## Current state

Native macOS app (SwiftUI + SwiftPM), forked from the storagedaddy/
performancedaddy template: `BrowserCore` library + `BrowserDaddy`
executable + XCTest. StorageDaddy visual language throughout — black
surfaces, mint accent, banded cards, doodle artwork.

Prototype reference at ~/browserdaddy/ (Python): extract.py, watch.py,
stats.py and its historical archive. The app ports that pipeline natively.
The stable native archive is migrated into the sandbox container on the first
sandboxed release launch.

Repo: github.com/sarthakagrawal927/browserdaddy (private).
Tracking: issue #1.

## Features (shipped)

**Collection**
- BrowserCore: SQLite store (recursive-locked, Sendable-safe), archive
  schema (visits/searches/focus/meta/domain_categories/page_categories),
  merge-dedupe on (browser, profile, visit_id)
- Discovery below explicitly connected, read-only browser roots only;
  Chromium profiles, Firefox and Safari; symlink-escape rejection and
  snapshots past SQLite locks
- Three engine extractors + epoch normalization; omnibox search terms
- FocusWatcher: NSWorkspace frontmost polling + AppleScript tab URL +
  CGEventSource idle gating → focus segments (2s ticks, 60s idle,
  3-miss tolerance, real elapsed dt, blip dropping, name map)
- Auto-extract on boot + every 6h (launchd not required)

**App surfaces**
- Onboarding: per-browser folder grants, automation explainer, honest-collection
  summary, opt-in tagging (one-shot, until meta.onboarded)
- Attention page: NOW (live app+tab), per-day timeline strip, WHERE IT
  GOES (apps/sites, active vs open), PATTERN (hourly)
- Dashboard: verdict, CHANGED LATELY (biggest MTD shifts), SPOT CHECK
  (per-domain month-to-date verdict + 60d sparkline + focus delta),
  TIMELINE (Day/Week/Month stacked by browser), MOVERS, TRENDS
  (focus/day, cumulative domains, new domains, novelty %, night-owl
  share, per-domain monthly), CATEGORIES + TOPICS (classifier.dev),
  SITES, DEEP READ (active-min per visit), HEATMAP (dow×hour),
  PROFILES (per-source hourly), DAYS (busiest, streaks, gaps, dow
  matrix), DAY EDGES (first/last site of day), HABITS (daily fixtures,
  return speed), DEPTH (concentration), SHARED (cross-browser),
  PACE (switch rate, median span), SESSIONS, SEARCHES
- History: search + per-browser filter
- Permissions: per-browser Connect/Change/Disconnect, Automation state, sync trigger,
  launch-at-login, TAGGING toggle + Tag button
- Global filters: source (browser/profile) + range (7/30/90d/all) —
  every band honors them; all grouping in local time

**Classification (classifier.dev, opt-in)**
- Batch scripts + in-app Classifier (the app's only network call,
  consent-gated via meta.classify_optin)
- Enriched inputs: domains send top page titles, pages send
  host/path/title; labels upgrade only when confidence improves
- Coverage: 4,048 domains (93% of visits), 35k pages (90% of visits)

## Boundaries

- Local-only by default; classification is opt-in and sends domain
  names / page titles only
- Private browsing is never reconstructed; visits ≠ attention — focus
  data is the real attention signal and only exists from watcher start
- Sandboxed and read-only on user-selected browser stores; no Full Disk Access,
  launchd requirement or implicit home-directory discovery; native APIs only

## Known thin spots / next steps

- Free-tier classifier quota throttles bulk re-runs; incremental is fine
- ~1.2k long-tail domains still <0.5 confidence — swept on next tag run
- from_visit chains stored but unexploited (navigation trees = next
  feature)
- Dashboard is long; could split into sub-pages if it grows further
- Python launchd agents can be retired once app grants are confirmed:
  `launchctl bootout gui/$UID/com.browserdaddy.{watch,extract}`
