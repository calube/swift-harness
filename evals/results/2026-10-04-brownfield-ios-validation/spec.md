# Confirm large chapter downloads

Readers sometimes queue hundreds of chapters by accident with "Download All" or a multi-select, and
there is no way to back out before the queue fills. Add an opt-in confirmation for large downloads.

## Requirements

1. **Setting.** Settings → Downloads gains a toggle titled "Confirm Large Downloads", off by default.
   It sits with the other download toggles and has a stable accessibility identifier so UI
   automation can find and switch it.
2. **Stored value.** The toggle's value is stored in the app's user defaults under its own key,
   registered with the other download settings, so it survives a relaunch. Switching it on in the
   UI writes `true` under that key.
3. **Threshold rule.** A pure function decides whether a download request needs confirmation from
   the number of chapters requested and the setting: with the setting on, more than 50 chapters
   needs confirmation; 50 or fewer, or the setting off, never does. It has unit tests in the app's
   existing test target.
4. **Prompt.** When a download from a manga's chapter list needs confirmation by that rule, the app
   asks "Download <n> chapters?" with Download and Cancel actions before queueing anything; Cancel
   queues nothing. Requests that don't need confirmation queue exactly as they do today.

## Out of scope

- Changing the download queue, its storage or its notifications.
- Any other setting or screen.
