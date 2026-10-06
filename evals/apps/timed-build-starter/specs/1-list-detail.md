# Exercise 1: Posts list and detail

This exercise fits a short time box. We care more about how you structure the
work and test it than about pixel-perfect screens.

## Setup

You start from the project we sent you. It builds, launches, and loads posts from
[JSONPlaceholder](https://jsonplaceholder.typicode.com), a free fake REST API. Today the first
screen only shows how many posts it loaded. Keep the existing tests passing.

Endpoints you'll need:

- `GET https://jsonplaceholder.typicode.com/posts`: every post (`id`, `userId`, `title`, `body`)
- `GET https://jsonplaceholder.typicode.com/users/{id}`: the author of a post (`name`, `email`)
- `GET https://jsonplaceholder.typicode.com/posts/{id}/comments`: a post's comments (`name`,
  `email`, `body`)

## What to build

### 1. Posts list

Replace the post count with a scrolling list of posts.

- Each row shows the post's title, and the first line of its body in a smaller, secondary style.
- A spinner shows while the first load runs.
- If the load fails, show a short message and a "Try again" button. Tapping it loads again.
- Pull to refresh reloads the list.

### 2. Post detail

Tapping a row opens a detail screen for that post.

- It shows the full title and body right away, from the post the list already has.
- It loads the author's name and the post's comments, and shows each as it arrives. The comments
  show the commenter's name and the comment text.
- If the author or the comments fail to load, the rest of the screen still works, and that section
  shows its own error with a way to try again.
- Going back to the list keeps the list's scroll position and doesn't reload it.

## Acceptance criteria

- [ ] Launching the app shows the list of posts, in the order the API returns them.
- [ ] With the network off, launching shows the error message; turning it back on and tapping
      "Try again" shows the list.
- [ ] Tapping a post opens its detail screen, with the title and body visible before any new
      request finishes.
- [ ] The detail screen shows the right author's name for that post, and that post's comments.
- [ ] A failed author request doesn't hide the comments, and a failed comments request doesn't
      hide the author.
- [ ] The list and detail logic have unit tests that run without the network.

## Out of scope

Styling beyond the system defaults, iPad layouts, and caching.
