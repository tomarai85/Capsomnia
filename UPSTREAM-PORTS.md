# Upstream ports ledger

This fork (feature/glass-menu lineage) diverged from fuji-mak/Capsomnia at #48
(2026-07-18, the 1.0.3 era) and REPLACED the menu/settings design and the keep-awake
core (modes Off/CapsLock/Auto + battery floor). Upstream 2.0 rearchitected its own core
(coordinator objects), so a git merge is impossible without importing that architecture
wholesale — measured 2026-08-13: 6 conflicted files, and the largest hunks are two
different architectures of the same 1,479-line core file. Codex review the same day
concurred: rebase/subtree/partial-merge all either replay the same conflict or falsely
mark upstream as merged. **Policy: features are PORTED one at a time, adapted to this
fork's design, and recorded here. Never `git merge upstream/main`.**

The owner's standing rule for what qualifies (2026-08-13): the fork's current design and
behavior stay as they are; take only what adds capability.

## Ported

| Upstream | What | Adaptation | Here |
|---|---|---|---|
| v3.1.0, PR #76 (`ExternalCapsLockOffPolicy`) | Closed-lid guard: a Caps Lock turn-off observed while the lid is closed is external (remote desktop syncing its keyboard) and must not release sleep prevention | Holds INTENT in the poll instead of re-asserting Caps Lock (this base has no caps-setting machinery); `autoOffInProgress`/`recentUserAction` params dropped — no timer here, and menu actions switch the MODE, which ends the guard structurally. Off by default, toggle in Settings. | `ClosedLidCapsLockGuard` (SystemServices.swift), wired in `desiredKeepAwake`; tests in `ClosedLidCapsLockGuardTests` |

## Evaluated and rejected

| Upstream | What | Why not |
|---|---|---|
| v3.0.0 (PR #66) | Auto-off timer: after N minutes, turn off keep-awake and put the Mac to sleep | Hostile to this fork's primary use (lid closed, remote work from a phone): an expired timer would sleep the Mac mid-session and drop remote access. Revisit only on explicit request. |
| v2.0.0 | Coordinator architecture (SystemCapsLockStateReader / CapsLockToggleCoordinator / GlobalHotKeyManager) + Settings redesign | Architecture replacement — exactly what the owner's rule forbids. Individual capabilities can still be ported piecemeal. |

## Candidates not yet decided

| Upstream | What | Note |
|---|---|---|
| v2.0.0 | Global toggle shortcut | Useful if Caps Lock is remapped; porting means bringing hotkey registration into this base. Ask the owner. |
| v1.1.0 | Prevent all-caps typing (Accessibility-permission event filter) | Self-contained filter; moderate port. Ask the owner. |
| v0.24-0.25-era fixes | Various small fixes inside 2.x refactors | Hard to extract individually; sweep upstream diffs when touching the affected area. |
