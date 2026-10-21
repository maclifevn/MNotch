# MNotch / MFinder notch drop coordination

Both apps expose **Receive files at notch**: Automatic, MFinder, MNotch, Off.
The selection is shared and applies to the next native file drag. Feature toggles
remain independent: coordination never enables a disabled File Tray, Drop Tray,
or Drop to Notch trigger, and never launches the other app.

Automatic chooses a ready MFinder Drop Tray on each supported display, then a
ready MNotch File Tray. A fixed selection does not fall back. MFinder currently
supports physical camera notches; MNotch also supports simulated notches. Shake,
modifier-key and manual Drop Tray activation remain available independently.
Existing trays and their files are not merged or migrated. A closed or populated
original MFinder tray advertises capacity for a new sibling without reopening,
allocating a tray while idle, or moving its old items. The native destination
waits for that sibling to load before accepting a drop.

## Native intake and failure behavior

An atomic metadata transaction reserves a destination per display for the native
drag pasteboard generation. The reservation includes the receiving process's
instance UUID. It cannot change when settings change, a peer starts/quits, or a
receiver restarts during that gesture. An unavailable receiver rejects the drop;
AppKit leaves the source responsible for its files. Automatic can select another
receiver only for a new gesture. The receiver checks local readiness again before
intake, and consumes its claim before calling a provider that may re-enter AppKit.

MNotch makes its entire overlay mouse-transparent and hides its presentation
while another receiver owns the drag. Returning an empty dragging operation by
itself is not a window handoff. Each receiver handles its own native pasteboard;
file URLs, file promises and user file contents never travel over this protocol.
MFinder retains its existing synchronous promise-claim and batch lifetime fences.
MNotch's existing File Tray supports file URLs; promise-only sources are rejected
when MNotch is selected, leaving the source untouched.

## Protocol v1

The mirrored `NotchDropBridge.swift` is compiled directly into each app. Changes
must update both copies and their routing tests together. The signed bundle
advertises `MacLifeNotchDropProtocol = 1`.

Same-user metadata lives in `~/Library/Application Support/MacLife/NotchDropBridge`.
The directory is created atomically with mode 0700; lock/data files use 0600.
Transactions use a separate flock inode and atomically replace bounded JSON
(maximum 64 KiB, two peers, 16 recent reservations). No symlink is accepted for
the final directory, lock or data inode. Launch identity and the MacLife signing
team authenticate peers; validated signatures are cached per PID/launch identity.

Disk work, signature validation and bounded lock backoff run on a private serial
queue. Native dragging callbacks inspect only memory. Distributed notifications
wake readers; bursts are coalesced into at most one active refresh and one
follow-up. They are not the authority for file intake. Application lifecycle
notifications refresh peer readiness. A failed or incompatible metadata read
fails closed. An older running peer without this protocol gets exclusive access
to overlapping physical notches; Settings asks the user to update both apps.

## Verification

- Both app test targets contain the same routing, disk-safety and lifecycle cases.
- MFinder native intake tests cover authorization failure, revocation during
  pasteboard decoding, every promise finishing after a batch was claimed, and
  a closed original receiving into a new sibling while preserving old bytes.
- MNotch: `swift test`, plus address/thread sanitizer runs for routing changes.
- MNotch: `python3 Scripts/QA/notch-drop-process-qa.py` runs independent processes,
  contention, simultaneous first launch, process death, restart and all policies.
- `Scripts/QA/NotchDropFixture.swift` supplies disposable native URL/promise batches
  for desktop and fullscreen interaction checks. Verify original/destination bytes.
- Before replacing MFinder, its exact signed candidate must pass the mandatory
  minimized-window thumbnail gate and use its guarded installer (see AGENTS.md).

A local test build does not update either public Sparkle feed.
