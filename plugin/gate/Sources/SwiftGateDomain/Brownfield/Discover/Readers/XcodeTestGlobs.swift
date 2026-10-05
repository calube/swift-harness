import Foundation

/// An Xcode area's `test_globs`, from where its tests really are: the folders each shared
/// scheme's test targets compile from, as the project's synchronized folders and Sources phases
/// say, and the `Tests` folder of every local package whose tests no area of its own runs. A
/// target whose project isn't tracked, as a generator writes it, falls back to a folder named
/// after the target.
extension XcodeReader.Unit {
  func testGlobs(
    _ schemes: [XcodeReader.Scheme], _ tree: TrackedTreeSnapshot,
    packagesTestedApart: Set<String>
  ) -> [String] {
    var folders: Set<String> = []
    var named: Set<String> = []
    var memberships: [String: TargetMembership?] = [:]
    for scheme in schemes {
      for testable in scheme.testables {
        let container = testable.container.flatMap {
          SwiftDiscoverPaths.resolve($0, in: SwiftDiscoverPaths.dirname(scheme.container))
        }
        guard let container, container.hasSuffix(".xcodeproj") else {
          // A package's test target sits in that package's `Tests`, globbed below.
          if container.map({ tree.paths.contains(SwiftDiscoverPaths.join($0, "Package.swift")) })
            != true
          {
            named.insert(testable.name)
          }
          continue
        }
        if memberships[container] == nil {
          memberships[container] = XcodeReader.text(tree, container + "/project.pbxproj")
            .flatMap { try? PBXProject(parsing: $0) }
            .map { TargetMembership(project: $0, projectPath: container) }
        }
        // A target compiling from the repository root names no folder of its own.
        let found = memberships[container]??.folders(of: testable.name)?.filter { !$0.isEmpty }
        if let found, !found.isEmpty {
          folders.formUnion(found)
        } else {
          named.insert(testable.name)
        }
      }
    }
    var globs = Set(folders.map { $0 + "/**/*.swift" })
    globs.formUnion(named.map { SwiftDiscoverPaths.join(root, "**/\($0)/**/*.swift") })
    globs.formUnion(
      localPackages(tree).filter { !packagesTestedApart.contains($0) }.map {
        SwiftDiscoverPaths.join($0, "Tests/**/*.swift")
      })
    return globs.sorted()
  }

  /// The tracked `Package.swift` directories this area builds: its root, the packages its
  /// projects reference and the ones its workspace lists.
  func localPackages(_ tree: TrackedTreeSnapshot) -> [String] {
    var directories: Set<String> = [root]
    for project in projects {
      guard let text = XcodeReader.text(tree, project.pbxproj) else { continue }
      for relative in XcodeReader.localPackagePaths(in: text) {
        if let path = SwiftDiscoverPaths.resolve(relative, in: project.directory) {
          directories.insert(path)
        }
      }
    }
    directories.formUnion(workspaceReferences)
    return directories.filter {
      tree.paths.contains(SwiftDiscoverPaths.join($0, "Package.swift"))
    }.sorted()
  }
}
