import Foundation

/// Reads `Gemfile` roots: RSpec or Minitest, RuboCop when configured.
///
/// Each `Gemfile` outside a vendored or sample directory is a `command` area run through
/// `bundle exec`. RSpec is found from `.rspec` or an `rspec` gem, and guessed from `*_spec.rb`
/// files alone. Minitest is found from a `test` task in the `Rakefile`, and guessed from
/// `test/**/*_test.rb` files alone; it gets a `test_files` command only through `bin/rails`, the
/// one runner that takes test paths without a load path set up by hand. RuboCop is found from the
/// nearest `.rubocop.yml` or a `rubocop` gem.
public struct RubyReader: EcosystemReader {
  public init() {}

  public func areas(in tree: TrackedTreeSnapshot) -> [ProposedArea] {
    let listed = Set(tree.paths)
    let directories = tree.paths.filter { CICommandMining.basename($0) == "Gemfile" }
      .map(CICommandMining.dirname).filter { !ManifestPaths.isSample($0) }
    return directories.sorted().map { directory in
      area(
        directory: directory, gemfile: ManifestPaths.join(directory, "Gemfile"), tree: tree,
        listed: listed)
    }
  }

  private func area(
    directory: String, gemfile: String, tree: TrackedTreeSnapshot, listed: Set<String>
  ) -> ProposedArea {
    let path = { ManifestPaths.join(directory, $0) }
    let gems = ManifestPaths.text(tree, gemfile) ?? ""
    let mine = tree.paths.filter { ManifestPaths.isUnder($0, directory) }
    var commands: [AreaStep: Sourced<String>] = [:]
    var missing: [AreaStep: String] = [:]
    var testGlobs: [String] = []
    let prefix = directory == "." ? "" : directory + "/"

    let specs = mine.contains { $0.hasPrefix(prefix + "spec/") && $0.hasSuffix("_spec.rb") }
    let rspec: (String, Confidence)? =
      listed.contains(path(".rspec"))
      ? (path(".rspec"), .found)
      : Self.namesGem("rspec", in: gems) || Self.namesGem("rspec-rails", in: gems)
        ? (gemfile, .found) : specs ? (gemfile, .guessed) : nil
    let minitests = mine.contains { $0.hasPrefix(prefix + "test/") && $0.hasSuffix("_test.rb") }
    let rakeTest = ManifestPaths.text(tree, path("Rakefile")).flatMap {
      Self.definesTestTask($0) ? path("Rakefile") : nil
    }

    if let (source, confidence) = rspec {
      commands[.test] = Sourced(value: "bundle exec rspec", source: source, confidence: confidence)
      commands[.testFiles] = Sourced(
        value: "bundle exec rspec {files}", source: source, confidence: confidence)
      testGlobs = [prefix + "spec/**/*_spec.rb"]
    } else if rakeTest != nil || minitests {
      commands[.test] = Sourced(
        value: "bundle exec rake test", source: rakeTest ?? gemfile,
        confidence: rakeTest == nil ? .guessed : .found)
      if listed.contains(path("bin/rails")) {
        commands[.testFiles] = Sourced(
          value: "bin/rails test {files}", source: path("bin/rails"), confidence: .guessed)
      }
      if minitests { testGlobs = [prefix + "test/**/*_test.rb"] }
    } else {
      missing[.test] = "no RSpec or Minitest tests in \(directory)"
    }

    let rubocopConfig = ManifestPaths.ancestors(directory).lazy
      .map { ManifestPaths.join($0, ".rubocop.yml") }.first { listed.contains($0) }
    if let source = rubocopConfig ?? (Self.namesGem("rubocop", in: gems) ? gemfile : nil) {
      commands[.lint] = Sourced(
        value: "bundle exec rubocop {files}", source: source, confidence: .found)
    } else {
      missing[.lint] = "no .rubocop.yml at or above \(directory) and no rubocop gem"
    }

    return ProposedArea(
      name: directory == "." ? "ruby" : CICommandMining.basename(directory), root: directory,
      language: .ruby, kind: .command, source: gemfile, commands: commands, missing: missing,
      testGlobs: testGlobs, xcode: nil, generatedProjectTracked: nil)
  }

  /// Whether a `gem` line names `name` or a gem that starts with `name-`, such as
  /// `rubocop-rails-omakase`.
  static func namesGem(_ name: String, in gemfile: String) -> Bool {
    gemfile.split(separator: "\n").contains { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("gem ") else { return false }
      let argument = trimmed.dropFirst(4).trimmingCharacters(in: .whitespaces)
      guard let quote = argument.first, quote == "\"" || quote == "'" else { return false }
      let gem = argument.dropFirst().prefix { $0 != quote }
      return gem == name || gem.hasPrefix(name + "-")
    }
  }

  /// Whether a `Rakefile` declares a `test` task: `Rake::TestTask` or `task test` in any spelling.
  static func definesTestTask(_ rakefile: String) -> Bool {
    rakefile.split(separator: "\n").contains { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("#") { return false }
      if trimmed.contains("Rake::TestTask.new") {
        return !trimmed.contains("Rake::TestTask.new(") || trimmed.contains("(:test")
          || trimmed.contains("(\"test\"") || trimmed.contains("('test'")
      }
      return ["task test:", "task :test", "task \"test\"", "task 'test'", "task(:test"]
        .contains { prefix in
          guard trimmed.hasPrefix(prefix) else { return false }
          let rest = trimmed.dropFirst(prefix.count)
          return prefix.hasSuffix(":") || rest.first.map { !$0.isLetter && $0 != "_" } ?? true
        }
    }
  }
}
