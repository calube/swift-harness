import SwiftSyntax

/// Calls that hold their thread until something else happens, and whether a call sits where a
/// cooperative-pool thread runs it (standards C6).
enum BlockingCalls {
  /// The blocking call `call` makes, named for the message, or `nil`. An awaited call is an
  /// async API of the same name, which suspends instead.
  static func name(of call: FunctionCallExprSyntax) -> String? {
    if call.parent?.is(AwaitExprSyntax.self) == true { return nil }
    if let member = call.calledMember {
      let name = member.declName.baseName.text
      switch name {
      case "waitUntilExit", "readDataToEndOfFile":
        return call.hasNoArguments ? name : nil
      case "wait":
        let labels = call.argumentLabels
        return labels.isEmpty || labels == ["timeout"] || labels == ["wallTimeout"] ? "wait" : nil
      case "sleep":
        return member.base?.refersToType("Thread") == true ? "Thread.sleep" : nil
      default:
        break
      }
    }
    if call.callsFreeFunction(in: ["sleep", "usleep", "nanosleep", "pthread_join", "lockf"]) {
      return call.calledName
    }
    if call.callsFreeFunction(in: ["flock"]), !argument(1, of: call, mentions: "LOCK_NB") {
      return "flock"
    }
    if call.callsFreeFunction(in: ["waitpid", "wait4"]), !argument(2, of: call, mentions: "WNOHANG")
    {
      return call.calledName
    }
    return nil
  }

  private static func argument(_ index: Int, of call: FunctionCallExprSyntax, mentions name: String)
    -> Bool
  {
    let arguments = Array(call.arguments)
    guard index < arguments.count else { return false }
    return arguments[index].expression.tokens(viewMode: .sourceAccurate).contains {
      $0.text == name
    }
  }

  /// Whether a pool thread runs `node`. In production code: the nearest enclosing function is
  /// `async`, or the nearest closure is a task body. In a test file every function counts, since
  /// Swift Testing runs synchronous tests on the pool too and helpers run where their tests do. A
  /// closure handed to a thread or a dispatch queue runs elsewhere in both.
  static func runsOnPool(_ node: some SyntaxProtocol, isTestFile: Bool) -> Bool {
    var current = node.parent
    while let syntax = current {
      if let closure = syntax.as(ClosureExprSyntax.self) {
        if closure.signature?.effectSpecifiers?.asyncSpecifier != nil { return true }
        switch launcher(of: closure) {
        case .task: return true
        case .otherThread: return false
        case nil: break
        }
      } else if let function = syntax.as(FunctionDeclSyntax.self) {
        return isTestFile || function.signature.effectSpecifiers?.asyncSpecifier != nil
      } else if let initializer = syntax.as(InitializerDeclSyntax.self) {
        return isTestFile || initializer.signature.effectSpecifiers?.asyncSpecifier != nil
      } else if let accessor = syntax.as(AccessorDeclSyntax.self) {
        return isTestFile || accessor.effectSpecifiers?.asyncSpecifier != nil
      }
      current = syntax.parent
    }
    return isTestFile
  }

  private enum Launcher { case task, otherThread }

  private static let taskLaunchers: Set<String> = [
    "Task", "detached", "addTask", "addTaskUnlessCancelled", "addDiscardingTask",
    "addDiscardingTaskUnlessCancelled",
  ]
  private static let threadLaunchers: Set<String> = [
    "Thread", "detachNewThread", "async", "asyncAfter", "OffPool",
  ]

  /// The call `closure` is a trailing closure or argument of, classified by what runs it.
  private static func launcher(of closure: ClosureExprSyntax) -> Launcher? {
    var node = Syntax(closure).parent
    if node?.is(LabeledExprSyntax.self) == true { node = node?.parent?.parent }
    guard let call = node?.as(FunctionCallExprSyntax.self) else { return nil }
    var names: [String] = []
    if let name = call.calledName { names.append(name) }
    if let base = call.calledMember?.base?.as(DeclReferenceExprSyntax.self) {
      names.append(base.baseName.text)
    }
    if names.contains(where: taskLaunchers.contains) { return .task }
    if names.contains(where: threadLaunchers.contains) { return .otherThread }
    return nil
  }
}
