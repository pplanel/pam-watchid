# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

`pam_watchid` is a single-file Objective-C PAM module (`src/pam_watchid.m`) for macOS
that authenticates `sudo` via an Apple Watch double-click, using
`LocalAuthentication`'s `LAPolicyDeviceOwnerAuthenticationWithCompanion`. It targets
Apple Silicon Macs without usable Touch ID (Mac mini/Studio, clamshell MacBooks) and is
meant to sit below `pam_tid.so` in `/etc/pam.d/sudo_local`.

See `AGENT.md` for the macOS-security engineering role/style this repo follows
(C↔Obj-C bridging discipline, ARC, PAM compliance).

## Build & test

Nix is the only build path (there is no Makefile):

```bash
nix build            # build + verify; result at result/lib/pam/pam_watchid.so
nix build .#harness  # build the standalone harness
nix run .#harness    # trigger a real watch prompt WITHOUT touching /etc/pam.d/
nix flake check      # build all packages
```

`nix build` compiles with `-Wall -Wextra -Werror` and then runs `checkPhase` (the former
`make verify`): it `file`s the Mach-O and greps `nm -gU` for the `pam_sm_*` exports, failing
the build if they are missing.

There is no unit-test suite. `test/harness.m` is the only test: it `dlopen`s the module
and system `libpam`, runs one live `pam_sm_authenticate` transaction (always with
`debug`), and forwards extra CLI args as module options (e.g. `nix run .#harness -- timeout=10`).
This requires real hardware (paired watch, Bluetooth) to exercise the success path.

Debug logs go to unified logging, not stdout:
```bash
log stream --predicate 'subsystem == "org.pam.watchid"' --level debug
```

## Nix build details

The module is linked as a `-bundle -undefined dynamic_lookup` object (no `-lpam`; the
`pam_sm_*` symbols resolve from the host PAM runtime at load time), built against
`-mmacosx-version-min=26.0`, and installed to `$out/lib/pam/pam_watchid.so`.

Nix layout: `flake.nix` (packages + `overlays.default`) → `default.nix` (module derivation,
including the build + verify `checkPhase`)
and `harness.nix` (wrapped harness that symlinks the store `.so` into `build/` so the
hardcoded `dlopen("build/pam_watchid.so")` path resolves). `pam-watchid.nix` is the
non-flake overlay. No `-fmodules` is used anywhere by design (avoids a non-hermetic
module cache); frameworks are linked explicitly.

## Architecture notes (`src/pam_watchid.m`, ~590 lines)

Flow of `pam_sm_authenticate`, in order — each gate returns `PAM_AUTHINFO_UNAVAIL` to
fall through to the next PAM module rather than failing the stack:

1. `PAM_SILENT` is **ignored** (the flag is `(void)`-cast). It means "suppress PAM
   conversation text", not "skip auth" — and sudo 1.9.16+ sets it by default, so bailing
   here skipped the watch prompt on any host without `Defaults !pam_silent`. The module
   uses an `LAContext` prompt + `os_log`, never the PAM conversation, so there's nothing
   to silence. (Matches `pam_tid.so`.)
2. Remote rejection: `PAM_RHOST` non-empty, or (no tty + `SSH_CONNECTION`) → skip, unless
   `allow_remote` is set.
3. `is_console_user()` — **anti-confused-deputy core**: via `SCDynamicStoreCopyConsoleUser`,
   requires the caller UID (for root targets) or target username (for `-u user`) to match
   the active GUI/WindowServer console owner. This stops a background/remote actor from
   buzzing the physical user's watch.
4. Preflight `canEvaluatePolicy:` (watch paired/unlocked/Bluetooth on).
5. Build the multi-line watchOS prompt from `get_target_command()` (parses the invoking
   process's argv via `sysctl(KERN_PROCARGS2)`, stripping sudo flags),
   `get_computer_name()`, `get_short_cwd()`, `get_parent_and_tty()`.
6. Evaluate async, block the PAM thread on a `dispatch_semaphore_t` with a bounded timeout
   (default 30s, `timeout=` option). A GCD `SIGINT` source calls `[context invalidate]` so
   Control-C dismisses the prompt on Mac and watch instead of hanging.

Concurrency/memory landmines to preserve:
- `NS_VALID_UNTIL_END_OF_SCOPE` on the `LAContext` is required: under `-O2` ARC may release
  it right after `evaluatePolicy:`, which cancels the evaluation and blocks the wait forever.
- Everything Obj-C runs inside an `@autoreleasepool` because PAM modules load into hosts with
  no active pool. CoreFoundation returns use `__bridge_transfer` to hand ownership to ARC.
- The `reply` block maps `LAError` codes to PAM: success→`PAM_SUCCESS`,
  `LAErrorUserCancel`→`PAM_AUTH_ERR` (stop the chain), and the unavailable/other-cancel
  cases→`PAM_AUTHINFO_UNAVAIL` (fall through). Changing this mapping changes the sudo UX.

`pam_sm_setcred` and `pam_sm_acct_mgmt` are intentional `PAM_SUCCESS` stubs, mirroring
Apple's `pam_tid.so.2`.
