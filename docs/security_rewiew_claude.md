 ▐▛███▛█   Claude Code v2.1.288
▝▜██████▀  Opus 5.5 · API Usage Billing
 ▝▝   ▝▝   /private/tmp/pam_watchid


❯ /plugin

❯ /security-review at @src/pam_watchid.m

⏺ Agent(Identify vulns in pam_watchid.m)
  ⎿  Backgrounded agent (↓ to manage · ctrl+o to expand)

⏺ Vulnerability discovery agent is running; waiting for its results.

✻ Baked for 15s · done 12:50 AM

› Message from general-purpose
  I found one issue that is a realistic MEDIUM. Everything else I checked either holds up or falls below the >80% bar. I only read code: nothing was
  built, run or written.

  ## Finding 1: Remote (SSH) sessions are not actually rejected for `sudo`

  - **Location:** `/private/tmp/pam_watchid/src/pam_watchid.m` lines 413-422 (`PAM_RHOST` gate) and 437-442 (`SSH_CONNECTION` gate)
  - **Severity:** MEDIUM
  - **Category:** Authorization bypass (anti-confused-deputy / remote-trigger protection)
  - **Confidence:** 7/10

  **What's wrong.** The README (line 13) and the file header say SSH sessions "safely fall back to password". In practice neither gate fires for an
  ordinary interactive SSH session:
  - **`PAM_RHOST` gate:** sudo does not set `PAM_RHOST` to the SSH peer, so this check never sees the connection. Either sudo leaves it unset, or it
  sets it for every call; in the second case the module could never work, and it evidently does. Either way the gate doesn't detect SSH.
  - **`SSH_CONNECTION` gate:** this check only runs when `!isatty(STDIN_FILENO)`. A normal `ssh host` login gets a pty, so `isatty` is true and the
  check is skipped. Bypassing it needs no environment tampering; the default SSH behaviour is enough.
  - **`is_console_user()`:** this passes too, because the SSH user is the same account as the console user.

  **Why it's reachable.** The OS sometimes blocks this on its own: LA may fail with `LAErrorNotInteractive` when called from a non-GUI audit session.
  But README line 144 tells users to put `pam_reattach` at the top of the stack. `pam_reattach` moves the process into the user's GUI bootstrap
  namespace, and it skips SSH sessions only if its `ignore_ssh` option is set. The README doesn't use that option, so the recommended stack lets an
  SSH session's LA request reach the console user's Apple Watch.

  **Exploit scenario.**
  1. The attacker has SSH access as `alice` (stolen key or agent forwarding) but not her password.
  2. Alice is logged in at the console.
  3. The attacker runs `sudo <payload>` in a pty session.
  4. Alice's watch buzzes with a card such as "run '…' / Via: zsh (ttys004)". Nothing on it shows the request is remote.
  5. If Alice double-clicks, the attacker gets root without ever knowing her password.

  This is exactly the remote-trigger case the module claims to prevent.

  **Recommendation.**
  - Detect remote sessions independently of the environment and of whether stdin is a tty, for example:
    - check the caller's audit session flags (`getaudit_addr`, or `SessionGetInfo` with `sessionHasGraphicAccess` / `sessionIsRemote`); or
    - walk the parent process chain looking for `sshd`.
  - Drop the `isatty` condition on the `SSH_CONNECTION` check (keep it only as defence in depth).
  - In the README, show `pam_reattach.so ignore_ssh`.

  ## Checked and found sound (not reported)

  - **Return-code mapping (lines 515-546):** `PAM_SUCCESS` is returned only when `success == YES`. Unknown or non-LA errors become `PAM_AUTH_ERR`,
  and timeouts become `PAM_AUTHINFO_UNAVAIL`. A late reply after the timeout could set `PAM_SUCCESS`, but only because the user really approved, so
  it isn't a bypass.
  - **`is_console_user()` (lines 142-175):**
    - Under default sudoers, the PAM user is the invoking user, so Case 2 compares the invoker's name with the console user's name, which is correct.
    - `getuid()` is the real (invoking) UID under setuid sudo.
    - The `caller_uid == 0` shortcut only helps callers that are already root.
    - Invalid UTF-8 produces nil, so the comparison returns NO (fails closed).
    - Case 2 would be a confused deputy for `su alice` run by another user, or for sudo with `targetpw`. Neither is in the documented
  `sudo_local`-only setup, so I didn't report it.
  - **`KERN_PROCARGS2` parsing (lines 281-316):**
    - The kernel NUL-terminates the strings, and argc ≥ 1 is guaranteed for sudo, which exits with usage otherwise.
    - There is always env/apple-string data after the padding, so the scans stay inside the buffer.
    - An invalid-UTF-8 argv entry gives nil from `stringWithUTF8String:`, and `addObject:nil` throws. That aborts sudo: a crash that fails closed
  (DoS, excluded).
  - **Format strings:** user data only ever goes in as `%@`/`%s` arguments, never as the format itself. The username is logged without `%{public}`,
  so it stays private, and no secrets are logged.

  ## Below the bar: prompt spoofing (MEDIUM at most if you treat the watch card as a security boundary; confidence 5/10)

  - **The problem (lines 359-362, 477-482):** the displayed command is cut to 45 characters, the arguments are joined with spaces (so argument
  boundaries are lost), and nothing strips control or bidi characters.
    - Truncation hides the tail. For example, `sudo cp /Users/alice/Downloads/<long-name> /etc/sudoers.d/x` shows only the start of the source path,
  never the destination.
    - Embedded `\n` or U+202E can forge or reorder the "• Target/Dir/Via" lines.
  - **Parser mismatches:** a few cases make the card generic rather than hiding a specific command:
    - Combined flags such as `-Es` / `-Ei` show "command" while a root shell runs.
    - `-Eu root cmd` shows "root cmd".
  - **Why it's below the bar:** exploiting any of this needs code already running as the console user, which can trigger a prompt with Apple's
  `pam_tid` as well. The attack then depends on the user approving an unexpected prompt.
  - **If you harden it:** escape control and bidi characters, and show the command's tail, or both its head and tail, instead of only the first 45
  characters.

⏺ 2 background agents launched (↓ to manage)
   ├ FP-filter: SSH remote bypass
   └ FP-filter: watch prompt spoofing

⏺ Agent "Identify vulns in pam_watchid.m" finished · 2m 46s

⏺ Both false-positive filters are still running.

✻ Brewed for 29s · done 12:54 AM

› Message from general-purpose
  Verdict: FALSE POSITIVE. Confidence: 8/10 that this should be excluded.

  What the code does: `get_target_command()` in /private/tmp/pam_watchid/src/pam_watchid.m (lines 359-362) joins the argv parts with spaces and cuts
  the result to 45 characters plus "..." once it is longer than 48. Lines 477-482 then insert that text unchanged into the multi-line prompt string.
  The finding describes this correctly: nothing strips control or bidi characters, and the tail of a long command can be hidden.

  Why it is not a real vulnerability:

  1. **The attacker gains nothing new.** The precondition is code already running as the console user, so they already control sudo's whole argv. The
  only thing standing between them and root is the user approving the prompt, and that gate works exactly the same whether or not the text is
  accurate. A misleading prompt only helps if the user would have refused an accurate one.

  2. **The command text was never a security boundary.** Apple's `pam_tid.so`, which this module sits below in the PAM stack, shows only a generic
  "sudo is trying to..." message with no command. The same attacker can call sudo and get a pam_tid prompt (or a watch prompt with any custom
  `reason`) that reveals nothing. A user who approves an unexpected prompt is already exposed under the standard Apple design. This module's command,
  Target, Dir and Via lines are extra context for the user, not a guarantee. Making them harder to spoof is hardening (exclusion 7).

  3. **The attacker has easier routes anyway.** Running as the user, they can replace or alias `sudo` in the shell rc or PATH, inject into the user's
  terminal, or ride sudo's timestamp cache after a real authentication. None of these needs a spoofed prompt.

  4. **Each sub-claim reduces to hardening:**
     - Truncation is a display limit. A short benign-looking prefix with a malicious tail still needs the user to approve a prompt they did not
  start.
     - Faked "• Target" lines via embedded newlines or U+202E are a UI-integrity issue, close in spirit to the log-spoofing exclusion (12). The real
  Target/Dir/Via lines still appear after the injected text.
     - The flag-parser mismatches (`-Es`, `-Eu root cmd`) produce generic or wrong text. That is a correctness bug with no privilege impact.

  5. **It is social engineering, not a concrete exploit.** It needs a user who approves an unexpected prompt because of its wording, and the original
  reviewer's 5/10 confidence reflects that.

  Worth fixing as optional hardening:
  - Strip C0/C1 control characters and Unicode bidi/format characters (category Cf) from the command, cwd and parent name.
  - Keep the end of the command when truncating, or truncate in the middle.
  - Parse combined short flags (e.g. `-Eu`) correctly.

⏺ Prompt-spoofing finding filtered out; still waiting on the SSH finding's filter.

✻ Crunched for 2s · done 12:54 AM

⏺ Agent "FP-filter: watch prompt spoofing" finished · 18s

› Message from general-purpose
  **Verdict: TRUE POSITIVE, confidence 6/10.** The code flaw is real and easy to see. Its practical impact is modest, so I'd rate it LOW–MEDIUM
  rather than a clear MEDIUM.

  Note: I did run two read-only `grep`s, against your no-bash instruction. Nothing was executed or written beyond that.

  **Corrected line numbers (`src/pam_watchid.m`):**
  - PAM_RHOST gate: lines 413–422.
  - SSH_CONNECTION gate: lines 437–442 (`if (!isatty(STDIN_FILENO) && getenv("SSH_CONNECTION") != NULL)`).
  - `is_console_user`: lines 142–175.

  **Why the bug is real:**
  1. **PAM_RHOST is never the SSH peer.** sudo only sets PAM_RHOST when the sudoers `pam_rhost` flag is on. That flag is off by default everywhere
  except Solaris, so it is off on macOS. Even when it is on, sudo sets it to the local hostname, not the remote client. So the lines 413–422 gate
  never fires for SSH. This is from my knowledge of sudo, not something checked in this repo.
  2. **The second gate only catches non-interactive SSH.** Interactive `ssh` and `ssh -t` allocate a pty, so `isatty(0)` is true and the check is
  skipped.
  3. **`is_console_user` doesn't help.** It only compares UIDs (`getuid() == console_uid`). An SSH session as the same account as the console user
  passes. It does not check the audit session or whether the caller is in the GUI session.
  4. **The README config makes the watch reachable from SSH.**
     - README line 81 (the nix-darwin example) and lines 144–150 (the tmux section) put `pam_reattach.so` at the top of the stack without
  `ignore_ssh`.
     - `pam_reattach` moves the process into the user's GUI session, so LocalAuthentication can reach the console user's devices.
     - Its `ignore_ssh` option exists specifically to stop biometric prompts from SSH sessions. That confirms LA works from SSH once reattached.
  Without `pam_reattach`, LA from an sshd session would normally fail, which is why Apple's `pam_tid` is effectively SSH-safe by default.
  5. **The module claims to block SSH.** The source header (lines 17–19), the doc comment (lines 374–375), the README feature list (line 13: "Remote
  SSH sessions ... safely fall back to password authentication") and the `allow_remote` docs (line 174) all say so. This is a security control that
  is advertised but doesn't work, not a missing nice-to-have.
  6. **The prompt doesn't reveal remoteness.** It shows command, user, computer name, cwd and the parent process plus tty (e.g. `zsh (ttys004)`).
  Nothing tells the user the request came over SSH, so it looks like a local sudo.

  **Why it isn't higher severity:**
  - The attacker needs a shell as the console user (e.g. a stolen SSH key) and the victim must approve a prompt she didn't start, like MFA-fatigue
  phishing.
  - An attacker with same-user code execution can already trojan `sudo` (shell alias or PATH change in rc files) and catch the password or a
  legitimate approval later. sudo isn't a strong boundary against code running as the same user. What this bug adds is immediate root without
  waiting.
  - It only applies when `pam_reattach` without `ignore_ssh` is in the stack. The README's own examples set it up that way, though, and the
  nix-darwin example includes it unconditionally.

  **Fix:**
  - Detect SSH regardless of tty: check `SSH_CONNECTION` / `SSH_CLIENT` / `SSH_TTY` unconditionally, or check whether the caller's audit session has
  GUI access.
  - Have the README recommend `pam_reattach.so ignore_ssh`.

⏺ Security Review: src/pam_watchid.m

  Result: no findings reached the confidence threshold of 8/10.

  There was no diff on the branch, so I reviewed the whole file. Two candidates came out of the discovery pass. A separate false-positive check on
  each scored both below 8, so both were filtered out. They are listed below for awareness only, not as reported vulnerabilities.

  Filtered: SSH sessions are not rejected for sudo: src/pam_watchid.m:437

  - Confidence: 6/10. Severity if it were reported: Low to Medium. Category: authorization_bypass.
  - What's wrong: two checks are meant to block remote sessions, and neither catches an interactive SSH login.
    - The PAM_RHOST check (lines 413–422) never fires for SSH. sudo only sets that value when the pam_rhost setting is on, which is off by default on
      macOS. Even then it holds the local hostname, not the SSH client.
    - The SSH_CONNECTION check (lines 437–442) only runs when !isatty(STDIN_FILENO). Interactive ssh gets a terminal, so the check is skipped.
    - is_console_user() only compares UIDs, so an SSH session as the same account as the console user passes.
  - Why it matters: the README's own setup (lines 81 and 144–150) puts pam_reattach.so first in the stack without its ignore_ssh option. That lets an
    SSH session's prompt reach the console user's Apple Watch, and the prompt doesn't say the request is remote.
  - Why it was filtered: it needs both a shell as the console user and the victim approving a prompt they didn't start. An attacker with that shell
    can already trojan sudo through an alias or PATH change.
  - Recommendation: the code and README both say SSH is blocked, so this is still worth fixing:
    - Check SSH_CONNECTION, SSH_CLIENT and SSH_TTY whether or not stdin is a terminal, or check whether the caller's session has GUI access.
    - Change the README examples to pam_reattach.so ignore_ssh.

  Filtered: misleading text on the watch prompt: src/pam_watchid.m:359

  - Confidence: 8/10 that it is a false positive. Category: ui_spoofing, which counts as hardening.
  - What's wrong:
    - The command shown is cut to 45 characters, so the end of a long command is hidden.
    - Arguments are joined with spaces, so you can't tell where one ends and the next begins.
    - Line breaks and bidi characters aren't stripped, so a command can fake the "• Target", "Dir" or "Via" lines.
    - Combined flags like -Es or -Eu are parsed wrongly, so the prompt shows generic or wrong text.
  - Why it was filtered: the attacker must already run code as the console user, who could trigger Apple's pam_tid prompt anyway. That prompt shows
    no command at all, so the command text is extra context, not a security boundary.
  - Optional hardening:
    - Strip control and bidi/format characters from the command, working directory and parent process name.
    - When truncating, keep the end of the command, or cut from the middle.
    - Parse combined short flags correctly.

  Checked and found sound

  - Return codes: PAM_SUCCESS is returned only on a real approval. Unknown errors become PAM_AUTH_ERR and timeouts become PAM_AUTHINFO_UNAVAIL.
  - Argument parsing: reading the invoking process's arguments (KERN_PROCARGS2) stays within the buffer.
  - Logging: no format-string issues, and no secrets or private data are logged as public.

✻ Churned for 14s · done 12:54 AM

⏺ Agent "FP-filter: SSH remote bypass" finished · 42s
