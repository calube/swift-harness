# Exercise 3: Offline drafts that sync

Thanks for making time today. You have about 45 minutes. This one is bigger on purpose: we'd
rather see 3 parts done well than all 4 half-done, so tell us what you'd do next if time runs out.

## Setup

You start from the project we sent you. It builds, launches, and loads posts from
[JSONPlaceholder](https://jsonplaceholder.typicode.com), a free fake REST API. Today the first
screen only shows how many posts it loaded. Keep the existing tests passing.

Endpoints you'll need:

- `GET https://jsonplaceholder.typicode.com/posts`: every post (`id`, `userId`, `title`, `body`)
- `POST https://jsonplaceholder.typicode.com/posts` with a JSON body of `title`, `body` and
  `userId`: creates a post. The API answers `201` with the post and a new `id`, but it doesn't
  keep it, so a later `GET` won't return it. Treat the `201` as success and keep the post on the
  device.

Our users are field staff who lose signal often. Nothing they write may get lost.

## What to build

### 1. Posts list that works offline

- Show the posts as a list of titles.
- Save the last list that loaded. When a load fails because the device is offline, show the saved
  list with an "Offline" banner at the top instead of an error.
- With nothing saved and no connection, show "You're offline" and a "Try again" button.

### 2. Write a post

- A "New post" button opens a form with a title and a body. Keep "Post" disabled while either
  field is empty after trimming spaces.
- Posting adds the post to the top of the list at once, marked "Sending…", and closes the form.
- When the server accepts it, the mark goes away.

### 3. Offline queue

- A post written while offline, or whose request fails, goes into a queue and shows "Waiting to
  send" in the list.
- The queue survives quitting and relaunching the app.
- Queued posts send in the order the user wrote them, one at a time.
- A post the server rejects with a `4xx` status leaves the queue and shows "Couldn't send" with a
  "Delete" action. Any other failure keeps it in the queue.

### 4. Sync when back online

- When the device comes back online, the app sends the queue without the user doing anything.
- It also tries once at launch, and when the user pulls to refresh.
- Only one send runs at a time, even if the connection flaps.

## Acceptance criteria

- [ ] With a saved list and the network off, launching shows the saved posts under an "Offline"
      banner.
- [ ] A post written offline shows "Waiting to send", is still there after a relaunch, and sends
      by itself within a few seconds of the network coming back.
- [ ] Three posts written offline reach the server in the order the user wrote them.
- [ ] A `400` response marks that post "Couldn't send" and the next queued post still sends.
- [ ] A `500` response or a timeout keeps the post queued for the next attempt.
- [ ] Toggling the network off and on 5 times in a few seconds never sends the same post twice.
- [ ] The queue, the ordering and the retry rules have unit tests that use no network, no real
      clock and no real disk.

## Out of scope

Editing or deleting posts that already sent, conflict resolution, and background app refresh.
