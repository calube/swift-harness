import sys
p = sys.argv[1] + "/Packages/AppFeature/Sources/AppUI/AppView.swift"
s = open(p).read()
old = '''          Text("\\(postCount) posts available")
            .accessibilityIdentifier("app.status")
'''
new = '''          Text("\\(postCount) posts available")
            .accessibilityIdentifier("app.status")
          ShortLivedBadge()
'''
assert old in s
s = s.replace(old, new, 1)
s += '''
/// A badge on a clock: hidden for 3 s after the posts load, shown for 1 s, then hidden again.
private struct ShortLivedBadge: View {
  @State private var shown = false

  var body: some View {
    ZStack {
      if shown {
        Text("New")
          .accessibilityIdentifier("app.new")
      }
    }
    .task {
      try? await Task.sleep(for: .milliseconds(3000))
      shown = true
      try? await Task.sleep(for: .milliseconds(1000))
      shown = false
    }
  }
}
'''
open(p, "w").write(s)
