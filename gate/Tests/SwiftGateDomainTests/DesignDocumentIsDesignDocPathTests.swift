import SwiftGateDomain
import Testing

/// `DesignDocument.isDesignDocPath` is the one place `design-lint`'s and `docs-lint`'s doc
/// discovery, the known-id feed and push's evidence gate all agree on what counts as a design doc.
@Suite("DesignDocument.isDesignDocPath")
struct DesignDocumentIsDesignDocPathTests {
  @Test(
    "an .md file directly under a designs directory matches; a subdirectory, a same-named file or a non-.md file doesn't — catches the shape drifting for any one caller"
  )
  func matchesOnlyAnMdFileDirectlyUnderDesigns() {
    let cases: [(path: String, expected: Bool)] = [
      ("docs/designs/x.md", true),
      ("docs/designs/sub/x.md", false),
      ("docs/designs.md", false),
      ("designs/x.txt", false),
      // Relative to `docs/` itself, as the known-id feed and push's evidence gate call it.
      ("designs/x.md", true),
      // A path component named `designs` that isn't the immediate parent doesn't count.
      ("docs/redesigns/x.md", false),
    ]
    for (path, expected) in cases {
      #expect(DesignDocument.isDesignDocPath(path) == expected, "\(path)")
    }
  }
}
