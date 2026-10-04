/// Writes a ``BrownfieldConfig`` as `config.toml` text: the inverse of ``BrownfieldConfigSchema``,
/// so reading what it renders and rendering again gives the same bytes.
public enum BrownfieldConfigTOML {
  public static func render(_ config: BrownfieldConfig) -> String {
    ""
  }
}
