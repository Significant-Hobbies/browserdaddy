# Real-browser privacy qualification

`PrivateWindowRuntimeTests` is opt-in. Ordinary `swift test` skips its browser
access. A skipped, failed or setup-blocked attempt is never a privacy pass.
No test requests Automation access, opens the owner archive, imports history,
changes browser settings, invokes classification, or prints tab URLs/titles.

Normal mode creates one controlled Chrome window with this inert canary URL:
`about:blank#browserdaddy-qualification-20261024`.
It records the new window ID, requires the native foreground process and top
on-screen ordinary window to be Chrome, verifies that the controlled window is
the Chrome front window and has exactly one tab, and closes only that created
window afterward. It does not enumerate unrelated normal tabs. Run stages
separately:

1. Normal window: `BROWSERDADDY_PRIVACY_MODE=normal swift test --filter PrivateWindowRuntimeTests`.
2. For private qualification, open a separate normal Chrome window with the
   same inert canary URL and keep it open. Then open one Incognito window
   through browser UI with the same canary URL.
   Run with `BROWSERDADDY_PRIVACY_MODE=private`.
3. Close only the test Incognito window through UI, return to the normal
   canary, then run with `BROWSERDADDY_PRIVACY_MODE=recovery`.

Normal/recovery require the exact canary in real capture and routing output.
Private requires an actual Incognito window, empty focus URL/title,
unavailable routing capture, and one normal canary inventory entry instead
of two. The actual private capture is also applied to a temporary focus
archive to check that previous public attention is not carried forward.
Missing consent or an inventory error cannot masquerade as private exclusion.

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
