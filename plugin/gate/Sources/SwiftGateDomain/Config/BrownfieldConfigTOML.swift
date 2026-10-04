/// Writes a ``BrownfieldConfig`` as `config.toml` text: the inverse of ``BrownfieldConfigSchema``,
/// so reading what it renders and rendering again gives the same bytes. Keys come in schema
/// order and presets by name, so 1 config has 1 rendering.
public enum BrownfieldConfigTOML {
  public static func render(_ config: BrownfieldConfig) -> String {
    var lines = ["schema = \(BrownfieldConfig.supportedSchema)", ""]
    lines += ["[harness]", "profile = \(quoted(BrownfieldConfigSchema.profileName))", ""]
    let settings = config.brownfield
    lines += [
      "[brownfield]",
      "discovered_at = \(quoted(settings.discoveredAt))",
      "slice_budget_s = \(settings.sliceBudgetSeconds)",
      "time_budget_min = \(settings.timeBudgetMinutes)",
      "sensitive = \(array(settings.sensitive))",
      "",
    ]
    for area in config.areas {
      lines += ["[[areas]]", "name = \(quoted(area.name))", "root = \(quoted(area.root))"]
      lines += [
        "language = \(quoted(area.language.rawValue))", "kind = \(quoted(area.kind.rawValue))",
      ]
      let commands: [(AreaStep, String?)] = [
        (.test, area.test), (.testFiles, area.testFiles), (.lint, area.lint),
        (.build, area.build), (.e2e, area.e2e),
      ]
      for case (let step, let command?) in commands {
        lines.append("\(step.rawValue) = \(quoted(command))")
      }
      lines += [
        "test_globs = \(array(area.testGlobs))", "packs = \(array(area.packs.map(\.rawValue)))",
        "",
      ]
      if let xcode = area.xcode {
        lines.append("[areas.xcode]")
        if let workspace = xcode.workspace { lines.append("workspace = \(quoted(workspace))") }
        if let project = xcode.project { lines.append("project = \(quoted(project))") }
        lines.append("inclusion = \(quoted(xcode.inclusion.rawValue))")
        if let manifest = xcode.manifest { lines.append("manifest = \(quoted(manifest))") }
        lines += ["schemes = \(array(xcode.schemes))", ""]
      }
    }
    for entry in config.allow {
      lines += [
        "[[allow]]", "rule = \(quoted(entry.rule))", "path = \(quoted(entry.path))",
        "line_sha = \(quoted(entry.lineSHA))", "reason = \(quoted(entry.reason))", "",
      ]
    }
    if case .enabled(let backend, let thresholds, let model) = config.judge {
      lines += ["[judge]", "backend = \(quoted(backend.rawValue))"]
      if let model { lines.append("model = \(quoted(model))") }
      if let host = backend.egressHost { lines.append("send_to = \(quoted(host))") }
      lines += [
        "advisory_threshold = \(thresholds.advisory)", "block_threshold = \(thresholds.block)", "",
      ]
    }
    for name in config.buildPresets.keys.sorted() {
      let preset = config.buildPresets[name]!
      let taskGate =
        switch preset.taskGate {
        case .ledger: "ledger"
        case .tier(let tier): tier.rawValue
        }
      lines += [
        "[build.presets.\(key(name))]",
        "design_tier = \(quoted(preset.designTier.rawValue))",
        "max_parallel = \(preset.maxParallel)",
        "review = \(quoted(preset.review.rawValue))",
        "task_gate = \(quoted(taskGate))",
        "merge_gate = \(quoted(preset.mergeGate.rawValue))",
        "worker_model = \(quoted(preset.workerModel.rawValue))",
        "time_budget_min = \(preset.timeBudgetMin)",
        "stop_starts_before_min = \(preset.stopStartsBeforeMin)",
        "on_design_conflict = \(quoted(preset.onDesignConflict.rawValue))",
        "task_proof = \(quoted(preset.taskProof.rawValue))",
      ]
      if let stallMin = preset.stallMin { lines.append("stall_min = \(stallMin)") }
      lines.append("")
    }
    return lines.joined(separator: "\n")
  }

  /// A TOML basic string.
  static func quoted(_ text: String) -> String {
    var out = "\""
    for scalar in text.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\t": out += "\\t"
      case "\r": out += "\\r"
      case _ where scalar.value < 0x20 || scalar.value == 0x7F:
        let hex = String(scalar.value, radix: 16, uppercase: true)
        out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
      default: out.unicodeScalars.append(scalar)
      }
    }
    return out + "\""
  }

  private static func array(_ values: [String]) -> String {
    "[" + values.map(quoted).joined(separator: ", ") + "]"
  }

  /// A bare key when TOML allows one, else a quoted one.
  private static func key(_ name: String) -> String {
    let bare =
      !name.isEmpty
      && name.unicodeScalars.allSatisfy {
        ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
          || $0 == "-" || $0 == "_"
      }
    return bare ? name : quoted(name)
  }
}
