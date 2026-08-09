# Install and first run

Requirements: macOS 14+, Apple Silicon. Free while in alpha.

1. Download from [arrayapp.dev](https://arrayapp.dev) (the button serves the
   newest release) and drag **Array** to Applications. The app is notarized —
   no Gatekeeper warnings.
2. First launch asks you to pick a project folder, then opens your workspace
   and the **Environment Setup** panel: what Array found (claude, codex, pi,
   tmux, git), copy-paste install commands for anything missing, and one-click
   buttons to open a real tile where each CLI runs its own sign-in.
   Reopen it anytime: **Help → Environment Setup…**
3. Signing in to providers always happens in the CLI itself (e.g. `claude`
   walks you through its login; pi uses `/login <provider>`). Array never
   asks for API keys.

## Updating

From 0.2.1 on, Array updates itself: **Array → Check for Updates…**, or allow
automatic checks when asked (second launch) and updates arrive on their own.
Release notes live on the
[releases page](https://github.com/dylanreedx/array-releases/releases).

## Problems

**Help → Report a Problem…** or
[github.com/dylanreedx/array-releases/issues](https://github.com/dylanreedx/array-releases/issues).
