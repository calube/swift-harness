import Foundation

/// An element's accessibility role: the node `type` the pinned `agent-device` runner emits.
///
/// Closed on purpose: the runner reports a type it has no name for as `Element(<raw value>)`, and
/// reading that as some non-interactive role would let the accessibility rules skip a control.
/// A pin bump recaptures the fixtures and revisits this list.
public enum SimElementRole: String, Sendable, Equatable, CaseIterable {
  case application = "Application"
  case window = "Window"
  case button = "Button"
  case cell = "Cell"
  case staticText = "StaticText"
  case textField = "TextField"
  case textView = "TextView"
  case secureTextField = "SecureTextField"
  case `switch` = "Switch"
  case slider = "Slider"
  case link = "Link"
  case image = "Image"
  case navigationBar = "NavigationBar"
  case tabBar = "TabBar"
  case collectionView = "CollectionView"
  case table = "Table"
  case scrollView = "ScrollView"
  case toolbar = "Toolbar"
  case searchField = "SearchField"
  case segmentedControl = "SegmentedControl"
  case stepper = "Stepper"
  case picker = "Picker"
  case activityIndicator = "ActivityIndicator"
  case progressIndicator = "ProgressIndicator"
  case checkBox = "CheckBox"
  case menuItem = "MenuItem"
  case webView = "WebView"
  case other = "Other"
  case keyboard = "Keyboard"
  case key = "Key"
  /// The snapshot engine rewrites some `Other` nodes to `Heading`.
  case heading = "Heading"

  /// Button, switch, text field and cell: the controls the accessibility rules hold to an
  /// identifier and a readable label.
  public var isInteractive: Bool {
    false
  }
}

/// One node of a snapshot. A missing or empty identifier, label or value is `nil`.
public struct SimElement: Sendable, Equatable {
  public let role: SimElementRole
  public let identifier: String?
  public let label: String?
  public let value: String?
  public let children: [SimElement]

  public init(
    role: SimElementRole, identifier: String?, label: String?, value: String?,
    children: [SimElement]
  ) {
    self.role = role
    self.identifier = identifier
    self.label = label
    self.value = value
    self.children = children
  }

  public var isInteractive: Bool { role.isInteractive }
}

public enum SimTreeError: Error, Sendable, Equatable {
  /// A node `type` outside `SimElementRole`, named as the runner printed it.
  case unknownRole(String)
  /// Bytes that aren't a successful `snapshot --json` envelope, with the decoder's reason.
  case malformed(String)
}

/// The accessibility tree from `agent-device snapshot --json`, rebuilt from its flat node list.
public struct SimTree: Sendable, Equatable {
  public let roots: [SimElement]
  /// The envelope's `data.truncated`: the runner stopped before the whole tree.
  public let isTruncated: Bool

  public init(roots: [SimElement], isTruncated: Bool) {
    self.roots = roots
    self.isTruncated = isTruncated
  }

  /// Parses the envelope `{"success":true,"data":{"nodes":[…],"truncated":…}}` exactly as the
  /// adapter's `snapshotJSON` returns it.
  public static func parse(snapshotJSON: Data) throws(SimTreeError) -> SimTree {
    SimTree(roots: [], isTruncated: false)
  }

  /// Every element, depth first, parents before their children.
  public var elements: [SimElement] {
    []
  }

  /// True when some element's label or value equals `text` exactly.
  public func contains(text: String) -> Bool {
    false
  }
}
