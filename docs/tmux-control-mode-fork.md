# tmux Control Mode (-CC) Fork — Maintenance & Rebase Runbook

## Purpose & golden rule

This fork (the iOS/visionOS "rootshell" build of Ghostty) adds **tmux control mode
(`-CC`)** support that maps tmux windows/panes onto native Ghostty tabs/splits. We will
**never upstream** it. The goal of this document and the `ROOTSHELL-TMUX` markers in the
tree is to make rebasing onto `ghostty-org/ghostty` (`upstream/main`) mechanical.

> **Golden rule:** `grep -rn "ROOTSHELL-TMUX" src/ include/` finds **every** fork-owned
> tmux hook. Each carries a stable `id=` (see the registry below) and most carry a
> `reapply:` note describing how to put it back if it conflicts on rebase. Hooks that are
> part of the **frozen C ABI** the iOS Swift app consumes are additionally tagged
> `FROZEN-ABI` and must never be renamed or reordered.

The Swift consumer lives in the separate `rootshell` repo
(`rootshell/Features/Tmux/TmuxController.swift`, the `ghostty_tmux_*` call
sites, and `rootshell/rootshell-Bridging-Header.h`). Any change to a
`FROZEN-ABI` hook must be mirrored there.

---

## How the fork is structured (two kinds of divergence)

1. **Relocated, fully fork-owned files** — we *replaced* upstream's experimental tmux
   parser wholesale, then moved it off the shared path so it can never 3-way-merge.
2. **Hooks into live upstream files** — small edits interleaved into files upstream also
   maintains. We pulled the cleanly-separable parts into `*_tmux.zig` sidecars and left
   the irreducible remainder inline, each marked with a `ROOTSHELL-TMUX` banner.

### File inventory by tier

| Tier | Files | Strategy on rebase |
|------|-------|--------------------|
| **A. New, fork-only** | `src/termio/Tmux.zig` (tmux termio backend) | Carry forward verbatim. |
| **B. Relocated parser** | `src/terminal/tmux_cc/{control,viewer,layout,output,control_writer,integration_test}.zig` + aggregator `src/terminal/tmux.zig` | Take OUR version wholesale. See "Relocated parser" below. |
| **C. Sidecars (extracted glue)** | `src/Surface_tmux.zig`, `src/apprt/surface_tmux.zig` | Carry forward verbatim. |
| **C. Hooked upstream files** | `src/Surface.zig`, `src/apprt/embedded.zig`, `src/apprt/surface.zig`, `src/termio/stream_handler.zig`, `src/terminal/dcs.zig`, `src/terminal/parse_table.zig` | Re-apply banner-marked hooks; reconcile bodies live in the sidecars. |
| **D. One-/few-line hooks** | `src/apprt/action.zig`, `src/termio/backend.zig`, `src/termio/message.zig`, `src/termio/Termio.zig`, `src/termio/Thread.zig`, `src/termio.zig`, `src/config/Config.zig`, `include/ghostty.h` | Re-apply the marked lines. |

### Sidecar map (where extracted logic lives)

| Sidecar | Owns | Re-exported by |
|---------|------|----------------|
| `src/Surface_tmux.zig` | `TmuxReconcileOp`, `TmuxReconcilePayload`, and the planners `planTmuxReconcile` / `focusTmuxReconcile` / `titleTmuxReconcile` (pure, no `Surface` state) | `Surface.zig` re-exports the two types as `Surface.TmuxReconcile{Op,Payload}`; calls the planners via `tmux_reconcile.*` |
| `src/apprt/surface_tmux.zig` | `TmuxFocusChanged`, `TmuxTitleChanged`, `TmuxTopologySnapshot` value types | `apprt/surface.zig` re-exports them as `Message.Tmux*` |
| `src/termio/Tmux.zig` | the entire tmux termio backend (Tier A) | `src/termio.zig` (`pub const Tmux`) |
| `src/terminal/tmux_cc/` | the tmux control-mode parser/viewer/layout (Tier B) | `src/terminal/tmux.zig` aggregator, exposed as `terminal.tmux` |

> `SurfaceRelayWriter` intentionally stays in `apprt/surface.zig` (not the sidecar) because
> it is tightly coupled to that file's `Message` / `Mailbox` types; extracting it would
> create a circular import. It is marked `id=apprt-relay-writer`.

---

## Relocated parser (Tier B) — the biggest rebase win

Upstream ships its own experimental tmux parser at `src/terminal/tmux/{control,viewer,
layout,output}.zig`. We replaced those with our own implementation and **relocated them to
`src/terminal/tmux_cc/`** so the two never collide. The module symbol stays `terminal.tmux`
and `src/terminal/main.zig`'s wiring line is byte-identical to upstream (no conflict there);
only the aggregator `src/terminal/tmux.zig` points at `tmux_cc/` instead of `tmux/`.

**On rebase:**
- `src/terminal/tmux/*` is **deleted in our tree**. If upstream edits those files, git raises
  a trivial *delete/modify* conflict — resolve by **keeping the deletion** (`git rm` them).
- Never try to 3-way-merge upstream's experimental parser into `tmux_cc/`. They are different
  implementations. Take ours.
- If upstream ever *renames/moves* its tmux module, you'll see a build break referencing the
  old path — update the aggregator only.

---

## Frozen C ABI contract (what the iOS Swift app depends on)

These must remain byte-stable. Mirror any change in `rootshell`.

- **Action:** `GHOSTTY_ACTION_TMUX_RECONCILE` and the `action.zig` union member
  `tmux_reconcile` + `pub const Key` enum entry `tmux_reconcile` (tag value — do not
  reorder) + the `TmuxReconcile` payload struct and its `C` extern struct.
- **Session-dashboard actions (`id=action-session-variants` /
  `id=action-session-structs` / `id=ghostty-h-session-actions`):**
  `GHOSTTY_ACTION_TMUX_SESSIONS_CHANGED` (void — session list churn, incl.
  other-client attach/detach/switch; the app refreshes its dashboard),
  `GHOSTTY_ACTION_TMUX_SESSION_CHANGED`
  (`ghostty_action_tmux_session_changed_s {session_id, name, name_len}` — the
  attached session's identity on startup/switch/rename; name is borrowed for the
  callback only), and `GHOSTTY_ACTION_TMUX_COMMAND_RESPONSE`
  (`ghostty_action_tmux_command_response_s {tag, is_err, body, body_len}` — the
  response to an app query sent via `ghostty_surface_tmux_command_with_reply`;
  body borrowed for the callback only; empty body + is_err means the query was
  dropped by a viewer reset/teardown before tmux answered). Key-enum order is
  append-only after `tmux_reconcile` and enforced by `checkGhosttyHEnum`.
- **Reconcile op consumer (`embedded.zig`, `id=embedded-capi-reconcile`):** enum tag values
  `CTmuxOpTag` (op `0..8`) and `CTmuxLayoutKind` (`0..2`); extern struct field order of
  `CTmuxOp` (= `ghostty_tmux_op_s`) and `CTmuxLayoutInfo` (= `ghostty_tmux_layout_info_s`);
  exports `ghostty_tmux_reconcile_op_count` / `ghostty_tmux_reconcile_op` /
  `ghostty_tmux_reconcile_free` / `ghostty_tmux_layout_info` / `ghostty_tmux_layout_child`.
- **Pane creation / resize / detach / command / active / resume:** `ghostty_surface_new_tmux_pane` (`id=embedded-new-tmux-pane`),
  `ghostty_surface_tmux_set_client_size` (`id=embedded-set-client-size`),
  `ghostty_surface_tmux_detach` (`id=embedded-tmux-detach`),
  `ghostty_surface_tmux_command` (`id=embedded-tmux-command`) — queues a raw
  `split-window`/`kill-pane` through the viewer command queue (drives splits),
  `ghostty_surface_tmux_command_with_reply` (`id=embedded-tmux-command-with-reply`)
  — queues an app query (`list-sessions`, `new-session -P`, ...) through the
  viewer command queue (`Command.user_query`, `id=viewer-user-query`) and
  delivers its `%begin/%end` block (or `%error` body) back through the action
  callback as `GHOSTTY_ACTION_TMUX_COMMAND_RESPONSE`, correlated by the
  app-chosen `tag`. Pending queries are errored back (empty body, is_err) on
  every queue-clearing reset: `%session-changed` rebuild, `forceResync`,
  teardown, resume abort (`id=streamhandler-query-command`),
  `ghostty_surface_tmux_active` (`id=embedded-tmux-active`) — bool probe of live
  control-mode state for the Swift ESC escape hatch,
  `ghostty_surface_tmux_resume` (`id=embedded-tmux-resume`) — re-enters control
  mode on a relaunched surface whose tssh session reattached a live `tmux -CC`
  (synthesizes the `ESC P 1000 p` entry, then the viewer `.resync` state drains
  the reattached stream and rebuilds via list-windows),
  `ghostty_surface_tmux_resume_abort` (`id=embedded-tmux-resume-abort`) — aborts a
  resume from the app's watchdog (tmux gone / session expired), tearing down the
  resync viewer and returning the parser to ground,
  `ghostty_surface_tmux_recover` (`id=embedded-tmux-recover`) — heals a LIVE
  gateway whose command/response stream desynced or that lost mid-stream data
  (the tsshd buffer overflowing while backgrounded). Drives `tmuxForceResync` (a
  live re-resync: reset the command pipeline, realign the parser, re-probe,
  rebuild via list-windows) WITHOUT tearing down panes. No-op unless a viewer is
  live in the steady command-queue state (distinct from `..._resume`, which only
  acts when NO viewer exists). Called from the app's always-on wedge watchdog,
  `ghostty_surface_tmux_reset` (`id=embedded-tmux-reset`) — full RESET after a
  LOSSY reconnect: the tsshd server discarded buffered output (back-pressure-free
  discard mode), dropping bytes mid-`%output`/control block. Drives
  `tmuxForceReset`: like `..._recover` (re-resync without tearing down panes) but
  ALSO force-recaptures every pane (`reset_recapture` → `syncLayouts` recapture,
  `id=viewer-force-reset`) and re-arms the title subscription, so the gateway is
  rebuilt identical to a fresh `tmux -CC attach` plus full content — no duplicated
  scrollback, no tab flicker. Called when the app's tssh transport reports a
  non-recoverable output discard,
  `ghostty_surface_tmux_reset_prioritized`
  (`id=embedded-tmux-reset-prioritized`) — append-only active-first form of the
  reset ABI. The app supplies its locally selected tmux window id. After the
  clean-stream marker the viewer reuses already-valid live metadata (re-sending
  client size first when it changed after the last acknowledgement), refreshes
  authoritative topology, fully recaptures that window (all split panes), and
  applies window-scoped pane state so it becomes interactive independently.
  Other windows recover one command at a time in the background; the exact
  Rootshell `select-window -t @N` relay reprioritizes unfinished work after the
  currently streaming command. Any ordinary tracked command between capture
  steps rewinds partial jobs; a pane moving between windows also rewinds its job
  and invalidates a displaced in-flight capture. This prevents live gated output
  from opening a gap between snapshots. Window-scoped state applies only to jobs
  whose four captures are complete, so a pane added while that command is in
  flight cannot bypass capture. History-only intermediate frames do not wake pane
  renderers; the coherent visible/state boundary performs the redraw, avoiding
  duplicate scrollback flashes during attach. The legacy reset remains the
  no-preference compatibility entry point,
  `ghostty_surface_tmux_resume_prioritized`
  (`id=embedded-tmux-resume-prioritized`) — cold-launch counterpart carrying
  the restored locally selected window into the fresh viewer. Newly discovered
  panes enter the same incremental scheduler, so the selected restored tab is
  interactive before background tabs finish their history captures. The first
  focus reconcile also uses that local preference instead of tmux's possibly
  different server-active window, so the new Swift controller cannot navigate
  away from the pane being recovered. Panes created during incremental recovery
  queue their OSC 10/11 color reports at admission, ahead of capture, so tmux can
  answer queries issued immediately by the new process. Rootshell
  skips the hidden gateway's saved ANSI replay (projected panes are rebuilt from
  tmux) and keeps restored tssh output gated until
  `ghostty_surface_tmux_active` confirms this viewer is armed. Only then are
  buffered control records released, so a fast roaming reattach cannot render
  raw `%output` lines through the gateway shell. Rootshell arms this path only
  when tssh reports that the old PTY actually resumed; a fresh-spawn fallback
  clears the saved gateway projection and rejoins the ordinary shell scrollback
  path, preserving its layout-deferred token until a correctly sized callback
  claims it exactly once,
  `ghostty_surface_tmux_force_exit` (`id=embedded-tmux-force-exit`) — the
  watchdog's give-up path: forcibly exits control mode LOCALLY (tears down the
  viewer, emits the empty-topology snapshot so the app prunes via the normal
  reconcile path AND drops the controller, returns the parser to ground). Unlike
  `..._detach` it does not wait for tmux to answer `detach-client`, so it works
  when tmux/the link is unresponsive. Server session stays alive.
- **Dead-shell detach detection (`id=probe-echo-detach`, core-internal, no ABI):**
  when a recovery resync's probe is written into a remote that is actually a
  plain shell (tmux exited but its `%exit` was lost to data loss), the shell
  ECHOES the probe back verbatim — including the literal UNEXPANDED
  `#{session_id}`, which a genuine reply can never contain (tmux expands it to
  `$N`, inside a `%begin` block), AND a per-probe random nonce
  (`buildResyncProbe`), so pane output quoting the PUBLIC marker text (these
  sources/docs) whose `%output` framing was lost cannot forge a match.
  `ProbeEchoMatcher` (`src/terminal/tmux_cc/probe_echo.zig`) scans the control
  parser's tolerant-`.idle` skipped bytes for `needle_prefix ++ nonce ++ "'"`
  while armed (`id=control-probe-echo`, armed with the just-written probe's
  nonce right after each recovery/reset/re-probe write; never on
  restore-resume, which the app's 12s resume watchdog owns; disarmed on block
  completion). On match the parser
  raises a take-and-clear detach edge (`id=control-probe-echo-edge`, dcs
  passthroughs `id=dcs-tmux-probe-echo`) and `tmuxDetachEchoExit`
  (`id=streamhandler-detach-echo`) tears down exactly like a clean `%exit`
  (teardown + deferred force-unhook). Deliberately does NOT engage the
  post-force-exit `ExitDrain` (`id=streamhandler-post-exit-drain`): the echo is
  by construction past the shell transition, no `%exit` will ever arrive, and
  draining would eat the shell's real output — the echoed line's own tail is
  consumed by the matcher's drain_line state instead.
- **Debug snapshot (`id=embedded-tmux-debug-snapshot`, FROZEN):**
  `ghostty_surface_tmux_debug_snapshot` fills a privacy-safe scalar
  `ghostty_tmux_debug_snapshot_s` (viewer/parser state, command-queue + sent-FIFO
  depths, in-flight command kind, pending pane responses, ages) for the iOS tmux
  debug log. It is a **lockless atomic read on the app thread** (no IO-thread hop)
  off an atomic mirror (`TmuxDebugMirror`, `id=tmux-debug-mirror`) the IO thread
  refreshes at tmux event sites — so it stays valid even when control mode is
  protocol-stalled. The first call flips an `enabled` atomic that gates the
  refresh, so it is a true no-op until the app opts in. The struct contains ONLY
  numeric ids/counts/enum-codes/ages/booleans — never pane output, titles,
  command text, keystrokes, or hostnames. The `ghostty_tmux_debug_snapshot_s`
  layout is **append-only**: add fields at the end and bump `abi_version`; keep
  `stream_handler.zig`'s `TmuxDebugSnapshot` and the `include/ghostty.h` typedef
  byte-for-byte in sync. Error/state codes are documented inline in both. The
  shared `control.ErrorCode` enum (`id=control-error-code`, in `control.zig`,
  also set on `viewer.zig`) backs `parser_last_error` / `viewer_last_error`.
- **Header:** the matching block in `include/ghostty.h`.

**Verify the ABI** (from the `ghostty-dec20` repo, after a build):
```bash
nm macos/GhosttyKitAppStore.xcframework/ios-arm64/libghostty-internal.a \
  | grep -E '_ghostty_(tmux|surface_new_tmux|surface_tmux_(set_client|detach|command|active|resume|resume_prioritized|recover|reset|reset_prioritized|reprobe|force_exit))' | sort -u
```
Expect 19 `T` (defined text) symbols:
`_ghostty_surface_new_tmux_pane`, `_ghostty_surface_tmux_set_client_size`,
`_ghostty_surface_tmux_detach`, `_ghostty_surface_tmux_command`,
`_ghostty_surface_tmux_command_with_reply`,
`_ghostty_surface_tmux_active`, `_ghostty_surface_tmux_resume`,
`_ghostty_surface_tmux_resume_prioritized`,
`_ghostty_surface_tmux_resume_abort`, `_ghostty_surface_tmux_recover`,
`_ghostty_surface_tmux_reset`, `_ghostty_surface_tmux_reset_prioritized`,
`_ghostty_surface_tmux_reprobe`,
`_ghostty_surface_tmux_force_exit`, `_ghostty_tmux_layout_child`,
`_ghostty_tmux_layout_info`, `_ghostty_tmux_reconcile_free`,
`_ghostty_tmux_reconcile_op`, `_ghostty_tmux_reconcile_op_count`. Also
`git diff include/ghostty.h` should be comment-only across a refactor.

---

## Locking model (id=termio-tmux-mutex / id=streamhandler-unlocked-io)

The control channel's liveness must never depend on the gateway renderer or
any pane renderer (the 2026-06 attach-wedge root cause: the read thread held
`renderer_state.mutex` across the whole stream parse and nested pane renderer
mutexes inside, so one stuck pane renderer starved every command reply).

- `Termio.tmux_mutex` serializes ALL tmux state on a surface: the viewer,
  `handler.dcs` while `.tmux`, parser-state pokes, force-unhook/resume/drain
  flags.
- **Lock order: `renderer_state.mutex` → `tmux_mutex` → pane renderer mutex.**
  Never take the renderer mutex while holding `tmux_mutex`.
- While HOOKED, `Termio.processOutput` parses control bytes under `tmux_mutex`
  only (`processOutputTmuxPrefix`). Unhooked chunks parse under renderer →
  tmux (the chunk may hook mid-stream).
- Whenever `tmux_mutex` is held, `handler.tmux_unlocked_io` is set; all three
  mailbox writers (`messageWriter`, `surfaceMessageWriter`,
  `rendererMessageWriter`) then use bounded no-unlock sends — the upstream
  queue-full slow paths unlock/relock the renderer mutex, which is UB when it
  isn't held and an ABBA when it is.
- Pane writes from the viewer use bounded locks (`lockRendererBounded`,
  id=viewer-pane-bounded-lock) with spill/re-fetch fallbacks; nothing on the
  control path blocks indefinitely on a pane.
- Sent-FIFO markers are recorded BEFORE the pty write, under `tmux_mutex`
  (Thread id=thread-tmux-write-record-atomic). Markers are COUNTED per
  send-keys command line: a batched `.tmux_send_keys` payload carries several
  `\n`-terminated lines in one message (Tmux id=tmux-send-keys-batch) and tmux
  acks each line with one `%begin/%end` block, so the Thread arm records
  `count(payload, '\n')` untracked markers in one bulk call.

## Banner convention

```zig
// ROOTSHELL-TMUX BEGIN (id=some-id)          // multi-line region; add FROZEN-ABI if C ABI
// what:    ...
// reapply: ...
...hooked code...
// ROOTSHELL-TMUX END (id=some-id)
```
```zig
foo, // ROOTSHELL-TMUX (id=some-id): one-line hook (e.g. a union variant or field)
```
Rules: every `BEGIN` has a matching `END`; C-ABI hooks carry `FROZEN-ABI` + a `DO NOT
REORDER` note; behavioral hooks in `dcs.zig` / `stream_handler.zig` / `parse_table.zig`
(the `dcs_passthrough` override) are also gated with
`if (comptime build_options.tmux_control_mode)` (a second greppable marker). The
`tmux_control_mode` build option is currently aliased to `oniguruma`
(`src/terminal/build_options.zig`); it was deliberately **not** decoupled.

### `id` registry

242 hook ids across 31 files (the table below enumerates the Tier C/D upstream-hooked
files; the fork-owned sidecars `src/Surface_tmux.zig`, `src/apprt/surface_tmux.zig`,
`src/termio/Tmux.zig`, and the `src/terminal/tmux_cc/*` parser also carry `id=`-tagged hooks
but are carried forward verbatim, so they are not re-listed here). Regenerate the full list
any time with:
```bash
grep -rn 'ROOTSHELL-TMUX' src/ include/ | grep -oE 'id=[a-z0-9-]+' | sort -u
```

| File | ids |
|------|-----|
| `src/apprt/action.zig` | `action-reconcile-variant` (FROZEN), `action-key-variant` (FROZEN), `action-reconcile-struct` (FROZEN) |
| `src/apprt/embedded.zig` | `embedded-capi-reconcile` (FROZEN), `embedded-new-tmux-pane` (FROZEN), `embedded-set-client-size` (FROZEN), `embedded-tmux-detach` (FROZEN), `embedded-tmux-command` (FROZEN), `embedded-tmux-active` (FROZEN), `embedded-tmux-resume-prioritized` (FROZEN), `embedded-tmux-resume-abort` (FROZEN), `embedded-tmux-recover` (FROZEN), `embedded-tmux-reset` (FROZEN), `embedded-tmux-reset-prioritized` (FROZEN), `embedded-tmux-reprobe` (FROZEN), `embedded-tmux-force-exit` (FROZEN), `embedded-tmux-flush-deferred` (FROZEN), `embedded-new-tmux-pane-fn`, `embedded-init-tmux-pane-fn`, `embedded-relay-field`, `embedded-relay-deinit`, `embedded-ui-terminal-arm` |
| `src/apprt/surface.zig` | `apprt-surface-tmux-types-extracted`, `apprt-msg-topology`, `apprt-msg-write`, `apprt-msg-focus`, `apprt-msg-title`, `apprt-relay-writer` |
| `src/Surface.zig` | `surface-reconcile-extracted`, `surface-initoptions-backend`, `surface-init-backend-select`, `surface-arm-topology`, `surface-arm-write`, `surface-send-keys-untracked`, `surface-paste-atomic`, `surface-arm-focus`, `surface-arm-title` |
| `src/termio/stream_handler.zig` | `streamhandler-viewer-field`, `streamhandler-force-unhook-field`, `streamhandler-deinit-viewer`, `streamhandler-changeconfig-disable`, `streamhandler-changeconfig-colors`, `streamhandler-set-client-size`, `streamhandler-pump-command-queue`, `streamhandler-write-tracked-command`, `streamhandler-record-tracked`, `streamhandler-record-untracked`, `streamhandler-pane-command`, `streamhandler-detach`, `streamhandler-tmux-active`, `streamhandler-tmux-active-flag`, `streamhandler-dcs-ground`, `streamhandler-block-fifo-filter`, `streamhandler-command-tracked`, `streamhandler-windows-empty-guard`, `streamhandler-dcs-dispatch`, `streamhandler-broken-control-unhook`, `streamhandler-tmux-teardown`, `streamhandler-gateway-menu`, `streamhandler-suppress-gateway-reports`, `snapshot-feed-pane-titles`, `streamhandler-resume-resend-probe`, `streamhandler-resume-abort`, `streamhandler-force-resync`, `streamhandler-force-reset`, `streamhandler-force-exit`, `streamhandler-unlocked-io`, `streamhandler-post-exit-drain`, `tmux-debug-mirror`, `tmux-debug-snapshot-struct` (FROZEN), `tmux-debug-read-progress`, `viewer-cursor-style-default`, `streamhandler-detach-echo` |
| `src/termio/backend.zig` | `backend-kind`, `backend-config-tmux`, `backend-tmux`, `backend-threaddata-tmux` |
| `src/termio/Termio.zig` | `termio-derived-config`, `termio-derived-init`, `termio-stream-config`, `termio-tmux-mutex`, `termio-tmux-process-output` |
| `src/terminal/dcs.zig` | `dcs-tmux-enter`, `dcs-can-sub-abort`, `dcs-is-inactive`, `dcs-begin-tmux-resync`, `dcs-tmux-take-recover`, `dcs-tmux-probe-echo`, `dcs-tmux-max-bytes` (tmux parser must NOT inherit the 1 MiB handler cap), `dcs-tmux-put-error` (parser failure → `.broken`, never silent `.ignore`) (rest gated by `build_options.tmux_control_mode`) |
| `src/terminal/parse_table.zig` | `parsetable-dcs-utf8-passthrough`, `parsetable-dcs-utf8-test` |
| `src/terminal/stream_terminal.zig` | `streamterm-dcs-st`, `streamterm-dcs-can-sub` |
| `src/termio/message.zig` | `termio-msg-set-client-size`, `termio-msg-pane-command`, `termio-msg-send-keys`, `termio-msg-track-command`, `termio-msg-detach`, `termio-msg-resume`, `termio-msg-resume-abort`, `termio-msg-recover`, `termio-msg-reset`, `termio-msg-force-exit`, `termio-msg-flush-deferred` |
| `src/termio/Thread.zig` | `thread-set-client-size`, `thread-pane-command`, `thread-send-keys`, `thread-track-command`, `thread-detach`, `thread-resume`, `thread-resume-abort`, `thread-recover`, `thread-reset`, `thread-force-exit`, `thread-tmux-write-record-atomic` |
| `src/termio.zig` | `termio-tmux-export` |
| `src/termio/mailbox.zig` | `mailbox-send-bounded` |
| `src/config/Config.zig` | `config-tmux-control-mode` |
| `include/ghostty.h` | `ghostty-h-action-enum` (FROZEN), `ghostty-h-reconcile` (FROZEN), `ghostty-h-set-client-size` (FROZEN), `ghostty-h-tmux-detach` (FROZEN), `ghostty-h-tmux-command` (FROZEN), `ghostty-h-tmux-active` (FROZEN), `ghostty-h-tmux-resume` (FROZEN), `ghostty-h-tmux-resume-prioritized` (FROZEN), `ghostty-h-tmux-resume-abort` (FROZEN), `ghostty-h-tmux-recover` (FROZEN), `ghostty-h-tmux-reset` (FROZEN), `ghostty-h-tmux-reset-prioritized` (FROZEN), `ghostty-h-tmux-force-exit` (FROZEN), `ghostty-h-tmux-flush-deferred` (FROZEN), `ghostty-h-tmux-debug-snapshot` (FROZEN) |

---

## Step-by-step rebase procedure

1. `git fetch upstream && git rebase upstream/main` (or merge).
2. **Tier A / C sidecars / B parser** (`src/termio/Tmux.zig`, `src/Surface_tmux.zig`,
   `src/apprt/surface_tmux.zig`, `src/terminal/tmux_cc/*`): these are fork-owned, no upstream
   equivalent — carry forward. If `src/terminal/tmux/*` reappears as a delete/modify
   conflict, **keep it deleted**.
3. **Tier C/D hooked upstream files:** for each conflicted file, run
   `grep -n ROOTSHELL-TMUX <file>` and re-apply each marked hook using its `reapply:` note
   and the registry above. Check off every `id` for that file.
4. Rebuild. Requires Zig 0.16 (`brew install zig`); the old visionOS stdlib
   patching is gone, 0.16 has those fixes.
   ```bash
   zig build test            # fast iteration; compiles everything for the host
   ```
5. **ABI verify** (see "Frozen C ABI contract"): `nm` the static archive for the tmux
   symbols; `git diff include/ghostty.h` should be comment-only.
6. Run tests: `zig build test` (covers `src/terminal/tmux_cc/integration_test.zig` and the
   `dcs.zig` tmux tests).
7. Rebuild the shippable framework and the app, from `rootshell/scripts`:
   `./build-framework.sh appstore --ghostty-source /path/to/ghostty-dec20`, then build
   `rootshell-AppStore` and smoke-test `tmux -CC` on device (native tab/split mapping,
   pane input, scrollback, resize).

### Drift checks (run any time)
```bash
# BEGIN/END must balance:
echo "$(grep -rc 'ROOTSHELL-TMUX BEGIN' src/ include/ | awk -F: '{s+=$2} END{print s}') begin / \
      $(grep -rc 'ROOTSHELL-TMUX END'   src/ include/ | awk -F: '{s+=$2} END{print s}') end"
# Every FROZEN-ABI symbol still present:
nm macos/GhosttyKitAppStore.xcframework/ios-arm64/libghostty-internal.a \
  | grep -cE '_ghostty_(tmux|surface_new_tmux|surface_tmux_(set_client|detach|command|active))'   # expect 11 (command_with_reply matches too)
# No stale upstream tmux/ path references crept back in:
grep -rn 'terminal/tmux/' src/ --include='*.zig' | grep -v 'tmux_cc/'      # expect empty
# Hook ids present (compare against the previous sync, currently 244):
grep -rn 'ROOTSHELL' src/ include/ | grep -oE 'id=[a-z0-9-]+' | sort -u | wc -l
```

---

## Fork features with NO marker

`ROOTSHELL-TMUX` only covers tmux control mode. These other fork features have
no marker safety net, so a merge can drop them silently. After every sync, check
each symbol still exists — an auto-merged upstream rewrite is the usual way one
disappears.

| Feature | Check for |
|---|---|
| iOS/visionOS/Catalyst port | `src/termio/Pipe.zig`, `backend.Kind.{pipe,tmux}`, `Command.startPosixSpawnPty`, `pty.zig` `.ios => PosixPty`, the `.maccatalyst` arms (incl. `renderer/generic.zig` display-link arms, `preThreadDeinit`) |
| Live environ (`id=global-live-environ`, `id=surface-exec-env-scope`) | `global.zig` `liveEnviron()`: `environ()`/`environMap()` must re-read `std.c.environ`, never return the `ghostty_init` snapshot; `os/file.zig` `allocTmpDir` dupes on POSIX; `Surface.zig` builds the env map only in the exec branch. The host app calls `setenv` all process long; a cached slice crashes in `Environ.createMap` |
| Smooth scroll / rubber band / bottom inset | `setSmoothScrollOffset`, `setRubberBandOffset`, `scrollToRowSmooth`, `setBottomInset`, `posToViewportLocked`, `render.zig` `beginUpdateExtraRows` |
| HDR / EDR boost | `Metal.zig` `hdr_boost` / `setHDRBoost`, `brightness_gain`, `apply_brightness` in shaders.metal |
| Display link | `IOSDisplayLink`, `vsyncTicking`, `reconcileLinkIdleLocked`, `setFrameRateRange`; `drawFrame` must keep excluding `sync` from `needs_redraw` |
| iTerm2 inline images | `Terminal.iterm2Image`, `terminal/iterm2/images.zig`, `graphics_storage.iterm2_loading` |
| IPv6 word selection | `Screen.selectWordOrIPv6`, and that `selectWordBetween` calls it |
| Multi-row link extension | `terminal/link_extend.zig`, `renderer/link.zig` `extendMatchAcrossRows` |
| Cursor blink modes | `config.CursorBlinkMode`, `.rootshell` arm in `renderer/cell.zig`, `computeBlinkAlpha` |
| Display-only redaction | `renderer/redact.zig`, `render.zig` `rebuildViewportRow` |
| Screen dump / external IO C API | the `ghostty_surface_dump_*`, `_pty_master_fd`, `_response_read_fd`, `_get_slave_fd` exports |
| Content-change events | `Surface.queueContentChanged`, `action.surface_content_changed` |

Two more invariants worth re-checking by hand, because nothing catches them:

- **`uiTerminalLocked` discipline.** `grep -n 'io\.terminal' src/Surface.zig
  src/apprt/embedded.zig` and classify every hit. UI / mouse / selection / link /
  paste / dump / VT-state-a-program-queries paths must use `uiTerminalLocked()`,
  `uiTerminalLockedConst()` or `renderer_state.terminal`; only real IO keeps
  `io.terminal`. A regression here shows up only as "broken inside tmux panes".
- **Dependency pins.** `build.zig.zon` plus the four `pkg/*/build.zig.zon` point
  at forks carrying fixes upstream lacks (libxev `.maccatalyst`, translate-c/aro
  visionOS). Upstream bumping those deps will conflict; rebase the fork rather
  than taking upstream's pin, or visionOS/Catalyst stops building.
