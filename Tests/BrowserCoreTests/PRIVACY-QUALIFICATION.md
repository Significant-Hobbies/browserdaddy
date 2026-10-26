# Real-browser privacy qualification

`PrivateWindowRuntimeTests` is opt-in. Ordinary `swift test` skips its browser
access. A skipped, failed or setup-blocked attempt is never a privacy pass.
No test requests Automation access, opens the owner archive, imports history,
changes browser settings, invokes classification, or prints tab URLs/titles.

The ordinary `normal` mode uses a controlled canary in the already-front
normal Chrome window. Private/recovery qualification uses a separate
test-owned Chrome process and UUID profile; it never probes an owner window or
profile.

Normal mode uses one controlled tab in the already-front normal Chrome window
with this inert canary URL:
`about:blank#browserdaddy-qualification-20261024`.
It records native window/tab IDs, requires the selected foreground process and
top on-screen ordinary window to be the same Chrome PID, and binds every
capture read to the approved normal window and canary tab. It closes only the
created tab and restores the prior active tab afterward. It does not enumerate
unrelated tab content.

Run: `BROWSERDADDY_PRIVACY_MODE=normal swift test --filter PrivateWindowRuntimeTests`.

Normal qualification requires the exact canary in real capture and routing
output. A denied-consent or foreground-identity failure stops before content;
it is not a normal capture pass. Deterministic tests cover private/unknown
exclusion, inventory ordering and focus carry-forward; they are not
live-browser privacy proof.

The opt-in `private` and `recovery` modes run one combined sequence:

1. Resolve the exact installed Chrome app and executable, record existing
   Chrome process IDs, create a unique temporary profile, and launch that
   executable directly with the profile and fixed `about:blank` canary. The
   retained `Process` handle must remain live at the fresh PID, and
   `NSRunningApplication` must report the same PID, bundle and executable.
   Ownership is bound to the exact argument vector passed to that direct
   launch; any process exit, forwarding or identity ambiguity stops before
browser metadata or content reads. The argument vector is launch provenance
from the retained child handle, not an OS read-back of live argv.
2. Require the selected app and top ordinary window to belong to that fresh
   process. Capture the normal canary, then create one incognito window using a
   PID-addressed Apple Event. The metadata snapshot records only window IDs,
   modes and normal-window tab IDs. Incognito tab IDs, URLs and titles are
   never requested. The production focus reader must return app-only state.
3. Bring the original normal window forward using its exact window ID and a
   PID-addressed event. Require the same normal window and tab identity, then
   verify that capture resumes for the fixed canary.

Run: `BROWSERDADDY_PRIVACY_MODE=private swift test --filter PrivateWindowRuntimeTests/testChromeWindowPrivacyAtTheActualCaptureBoundaries`.
`BROWSERDADDY_PRIVACY_MODE=recovery` runs the same combined sequence. Both
require existing Chrome Automation consent and never request it; denial skips
before metadata/content reads. The exact UUID profile is retained at the
reported temporary path for owner review. The harness requests graceful
termination only through the still-live direct `Process` handle while its PID
and app identity still match; it never removes the profile. If app identity
cannot be proven while the child remains live, it leaves that child alone and
reports its PID rather than risking a signal to an unverified process. A missing
permission, unsupported app launch behavior, ownership mismatch, foreground
mismatch or ambiguous window delta is a failed or skipped qualification, never
a pass.

The private/recovery mode proves this capture sequence only. It does not
qualify browser relaunch, restoration after process exit, the installed
BrowserDaddy package, sandbox/TCC equivalence, or the required ordinary-use
diary periods.

This qualifies capture kernels in the test executable. It does not establish
installed-package identity, sandbox/TCC equivalence or full sampler behavior.
Retain source/package hash, OS/browser version, stage, timestamp, exit/skip
state and evidence location in the current release qualification record.
Never include private URLs, titles, owner archives or browser profiles there.

Before removing the installed release caveat, complete the exact-package
matrix: normal/private/unknown state, browser switches, idle, sleep/wake and
relaunch. Check focus segments as well as Tabs and explicit routing. Safari
extension permission states are separate from the disabled AppleScript path;
unsupported browsers must disclose app-only/unavailable state. Changing
permissions or sleeping the owner's Mac is not part of this automatic test.
