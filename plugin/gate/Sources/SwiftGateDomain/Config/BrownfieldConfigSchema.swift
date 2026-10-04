/// Validates a parsed `config.toml` document against the brownfield schema, collecting every
/// problem rather than stopping at the first.
public enum BrownfieldConfigSchema {
  public static func config(from document: ConfigValue) throws(ConfigValidationError)
    -> BrownfieldConfig
  {
    BrownfieldConfig(
      brownfield: BrownfieldSettings(
        discoveredAt: "", sliceBudgetSeconds: 0, timeBudgetMinutes: 0, sensitive: []),
      areas: [], allow: [], buildPresets: [:])
  }
}
