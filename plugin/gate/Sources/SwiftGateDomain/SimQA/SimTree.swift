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
    switch self {
    case .button, .switch, .textField, .cell: true
    default: false
    }
  }
}

/// One node of a snapshot. A missing or empty identifier, label or value is `nil`.
public struct SimElement: Sendable, Equatable {
  public let role: SimElementRole
  public let identifier: String?
  public let label: String?
  public let value: String?
  public let children: [SimElement]
  /// Where the snapshot drew it, in points; `nil` when the node carries no `rect`.
  public let frame: SimFrame?

  public init(
    role: SimElementRole, identifier: String?, label: String?, value: String?,
    children: [SimElement], frame: SimFrame? = nil
  ) {
    self.role = role
    self.identifier = identifier
    self.label = label
    self.value = value
    self.children = children
    self.frame = frame
  }

  public var isInteractive: Bool { role.isInteractive }
}

/// A node's `rect`: its origin and size in points.
public struct SimFrame: Sendable, Equatable {
  public let x: Double
  public let y: Double
  public let width: Double
  public let height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  /// Whether the frame's centre lies inside `other`.
  public func centred(in other: SimFrame) -> Bool {
    false
  }
}

/// What keeps a checked element from the user.
public enum SimCover: Sendable, Equatable {
  /// A search field, tab bar, toolbar or keyboard drawn after it, over its centre.
  case bar(SimElement)
  /// Its centre lies outside the app's frame.
  case offScreen
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
    let envelope: Envelope
    do {
      envelope = try JSONDecoder().decode(Envelope.self, from: snapshotJSON)
    } catch {
      throw .malformed(String(describing: error))
    }
    guard envelope.success, let data = envelope.data else {
      throw .malformed("the envelope is not a successful snapshot")
    }

    var childIndexes: [Int: [Int]] = [:]
    var rootIndexes: [Int] = []
    var nodesByIndex: [Int: Node] = [:]
    for node in data.nodes {
      guard nodesByIndex.updateValue(node, forKey: node.index) == nil else {
        throw .malformed("node index \(node.index) appears twice")
      }
      if let parent = node.parentIndex {
        childIndexes[parent, default: []].append(node.index)
      } else {
        rootIndexes.append(node.index)
      }
    }
    if let orphan = data.nodes.first(where: {
      $0.parentIndex.map { nodesByIndex[$0] == nil } ?? false
    }) {
      throw .malformed("node \(orphan.index) names a parent index that no node has")
    }

    // Each node has one parent, so a walk from the roots terminates; a cycle is a set of nodes
    // the walk never reaches.
    func element(_ index: Int) throws(SimTreeError) -> SimElement {
      guard let node = nodesByIndex[index] else {
        throw .malformed("node \(index) is missing")
      }
      guard let role = SimElementRole(rawValue: node.type) else { throw .unknownRole(node.type) }
      var children: [SimElement] = []
      for child in childIndexes[index, default: []] {
        children.append(try element(child))
      }
      return SimElement(
        role: role, identifier: node.identifier.nonEmpty, label: node.label.nonEmpty,
        value: node.value.nonEmpty, children: children)
    }

    var roots: [SimElement] = []
    for index in rootIndexes {
      roots.append(try element(index))
    }
    let reached = roots.reduce(0) { $0 + 1 + Self.descendantCount($1) }
    guard reached == data.nodes.count else {
      throw .malformed("some nodes' parent indexes form a cycle that no root reaches")
    }
    return SimTree(roots: roots, isTruncated: data.truncated)
  }

  /// Every element, depth first, parents before their children.
  public var elements: [SimElement] {
    var result: [SimElement] = []
    func visit(_ element: SimElement) {
      result.append(element)
      element.children.forEach(visit)
    }
    roots.forEach(visit)
    return result
  }

  /// Why every element `selector` matches is hidden from the user; `nil` when some match is in
  /// view, or when no match carries a frame to judge.
  public func cover(of selector: SimSelector) -> SimCover? {
    nil
  }

  /// True when some element's label or value equals `text` exactly.
  public func contains(text: String) -> Bool {
    elements.contains { $0.label == text || $0.value == text }
  }

  private static func descendantCount(_ element: SimElement) -> Int {
    element.children.reduce(0) { $0 + 1 + descendantCount($1) }
  }

  private struct Envelope: Decodable {
    let success: Bool
    let data: Payload?
  }

  private struct Payload: Decodable {
    let nodes: [Node]
    let truncated: Bool
  }

  private struct Node: Decodable {
    let index: Int
    let parentIndex: Int?
    let type: String
    let identifier: String?
    let label: String?
    let value: String?
  }
}

extension Optional where Wrapped == String {
  fileprivate var nonEmpty: String? {
    switch self {
    case .some(let text) where !text.isEmpty: text
    default: nil
    }
  }
}
