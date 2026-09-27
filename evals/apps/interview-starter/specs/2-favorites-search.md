# Exercise 2: Favorites and search

Thanks for making time today. You have about 45 minutes. We care more about how you structure the
work and test it than about pixel-perfect screens.

## Setup

You start from the project we sent you. It builds, launches, and loads posts from
[JSONPlaceholder](https://jsonplaceholder.typicode.com), a free fake REST API. Today the first
screen only shows how many posts it loaded. Keep the existing tests passing.

The one endpoint you need: `GET https://jsonplaceholder.typicode.com/posts` returns every post
(`id`, `userId`, `title`, `body`).

## What to build

### 1. Posts list and detail

Replace the post count with a scrolling list of posts: each row shows the title. Tapping a row opens
a detail screen with the post's title and full body. While the list loads, show a spinner. If the
load fails, show a message and a "Try again" button.

### 2. Favorites

People want to keep the posts they like.

- The detail screen has a star button that marks or unmarks the post as a favorite.
- The list shows a filled star on favorite rows.
- A "Favorites" tab lists only the favorite posts, newest star first.
  Tapping one opens the same detail screen.
- Favorites survive quitting and relaunching the app. Store them on the device; there's no server
  side for this.
- If a favorite post no longer comes back from the API, drop it from the Favorites tab rather than
  showing a broken row.

### 3. Search

The list is long, so add search.

- A search field at the top of the list filters posts as the user types.
- A post matches when its title or body contains the search text, ignoring case and extra spaces
  at either end.
- An empty search shows every post. A search with no matches shows "No posts match" and the text
  the user typed.
- Search filters the posts already loaded. It doesn't make a new request per keystroke.

## Acceptance criteria

- [ ] Starring a post on its detail screen fills the star on its list row and adds it to the
      Favorites tab at the top.
- [ ] Unstarring removes it from the Favorites tab and clears the star on its row.
- [ ] Favorites are still there after the app quits and relaunches.
- [ ] Typing "dolor" narrows the list to posts whose title or body contains "dolor"; typing
      "DOLOR  " gives the same result.
- [ ] A search with no matches shows the empty message; clearing the field shows every post.
- [ ] The favorites store and the search matching have unit tests that don't touch the network or
      the real disk.

## Out of scope

Syncing favorites between devices, searching the Favorites tab, and highlighting the matched text.
