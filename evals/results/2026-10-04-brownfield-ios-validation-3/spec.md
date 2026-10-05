# Confirm large chapter downloads

Readers sometimes queue hundreds of chapters by accident with "Download All" or a multi-select, and
there is no way to back out before the queue fills. Add an opt-in confirmation for large downloads.

## Requirements

1. **Setting.** Settings → Downloads gains a toggle titled "Confirm Large Downloads", off by default.
   It sits with the other download toggles and has a stable accessibility identifier and a readable
   label, so UI automation can find and switch it.
2. **Stored value.** The toggle's value is stored in the app's user defaults under its own key,
   registered with the other download settings, so it survives a relaunch. Switching it on in the
   UI writes `true` under that key, which can be read back from the installed app's defaults.
3. **Download check.** One entry point decides whether a chapter-list download request needs
   confirmation, from the number of chapters requested and the setting as stored in the user
   defaults it is handed (not a global): with the setting stored on, more than 50 chapters needs
   confirmation; 50 or fewer, or the setting off or never stored, never does. This behaviour is
   accepted at that boundary by 1 test class in the app's existing `AidokuTests` target that stores
   the setting under its real key in a dedicated `UserDefaults` suite and asks about 50 and 51
   chapters, so the stored setting and the decision are proven to work together, not only the
   arithmetic. That test can be run on its own by its target, class and method name.
4. **Prompt.** When a download from a manga's chapter list needs confirmation by that check, the app
   asks "Download <n> chapters?" with Download and Cancel actions before queueing anything; Cancel
   queues nothing. Requests that don't need confirmation queue exactly as they do today.

## Out of scope

- Changing the download queue, its storage or its notifications.
- Any other setting or screen.
