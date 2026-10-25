# Real-browser privacy qualification

`PrivateWindowRuntimeTests` is opt-in. Ordinary `swift test` skips its browser
access. A skipped, failed or setup-blocked attempt is never a privacy pass.
No test requests Automation access, opens the owner archive, imports history,
changes browser settings, invokes classification, or prints tab URLs/titles.

The current automatic harness is normal-only. Private and recovery modes
deliberately skip, so they are not runnable qualification stages. Do not run
them against owner windows or interpret their skips as privacy evidence.

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
it is not a normal capture pass. Live private/recovery qualification needs an
isolated task-owned browser process and remains an explicit coverage limit.
Deterministic tests cover private/unknown exclusion, inventory ordering and
focus carry-forward; they are not live-browser privacy proof.

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
