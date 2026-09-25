func handle(items: [Int], user: User) -> Int {
  // Check if the list is empty
  if items.isEmpty { return 0 }
  // Bail out when the user is not logged in
  guard user.isLoggedIn else { return 0 }
  // Return the item count
  return items.count
}
