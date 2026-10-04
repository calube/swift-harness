import Foundation
import Network
import Synchronization

/// 1 HTTP request a local server read: its method, path and decoded query.
public struct LocalHTTPRequest: Sendable, Equatable {
  public var method: String
  /// The target's path, still percent-encoded, without its query.
  public var path: String
  /// The query's items, percent-decoded; a repeated name keeps its last value.
  public var query: [String: String]

  public init(method: String, path: String, query: [String: String] = [:]) {
    self.method = method
    self.path = path
    self.query = query
  }
}

/// What a local server answers.
public struct LocalHTTPResponse: Sendable, Equatable {
  public var status: Int
  public var contentType: String
  public var body: Data

  public init(status: Int, contentType: String, body: Data) {
    self.status = status
    self.contentType = contentType
    self.body = body
  }

  /// A plain-text answer, such as an error line.
  public static func text(_ status: Int, _ message: String) -> LocalHTTPResponse {
    LocalHTTPResponse(
      status: status, contentType: "text/plain; charset=utf-8", body: Data("\(message)\n".utf8))
  }
}

/// Why a local server didn't start.
public struct LocalHTTPServerError: Error, Sendable, Equatable, CustomStringConvertible {
  public let description: String

  public init(_ description: String) { self.description = description }
}

/// Serves HTTP on 127.0.0.1 only, so nothing off this machine can reach it.
public protocol LocalHTTPServing: Sendable {
  /// Starts listening and returns once connections are accepted, with the port bound.
  /// - Parameter port: 0 picks a free port.
  func start(
    port: UInt16, handler: @escaping @Sendable (LocalHTTPRequest) -> LocalHTTPResponse
  ) async throws -> UInt16

  func stop()
}

/// ``LocalHTTPServing`` over Network.framework: 1 request per connection, then close.
public final class LocalHTTPServer: LocalHTTPServing {
  /// A request head longer than this is refused rather than buffered.
  static let maxHeadBytes = 16 * 1024

  private let queue = DispatchQueue(label: "LocalHTTPServer")
  private let listener = Mutex<NWListener?>(nil)

  public init() {}

  public func start(
    port: UInt16, handler: @escaping @Sendable (LocalHTTPRequest) -> LocalHTTPResponse
  ) async throws -> UInt16 {
    let parameters = NWParameters.tcp
    // Bound to the loopback address itself, not to every interface, so another machine's
    // connection is refused by the kernel before any request is read.
    parameters.requiredLocalEndpoint = .hostPort(
      host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
    let listener: NWListener
    do {
      listener = try NWListener(using: parameters)
    } catch {
      throw LocalHTTPServerError("can't listen on 127.0.0.1:\(port): \(error)")
    }
    self.listener.withLock { $0 = listener }
    let queue = self.queue
    listener.newConnectionHandler = { connection in
      let served = ServedConnection(connection: connection, handler: handler)
      connection.start(queue: queue)
      served.receive(Data())
    }
    let resumed = Mutex(false)
    return try await withCheckedThrowingContinuation { continuation in
      let once: @Sendable (Result<UInt16, any Error>) -> Void = { result in
        guard
          resumed.withLock({ done in
            defer { done = true }
            return !done
          })
        else { return }
        continuation.resume(with: result)
      }
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
          once(.success(listener.port?.rawValue ?? 0))
        case .failed(let error), .waiting(let error):
          listener.cancel()
          once(.failure(LocalHTTPServerError("can't listen on 127.0.0.1:\(port): \(error)")))
        case .cancelled:
          once(.failure(LocalHTTPServerError("stopped before listening on 127.0.0.1:\(port)")))
        default:
          break
        }
      }
      listener.start(queue: queue)
    }
  }

  public func stop() {
    listener.withLock { listener in
      listener?.cancel()
      listener = nil
    }
  }
}

/// 1 accepted connection: reads the request head, answers, closes.
private struct ServedConnection: Sendable {
  let connection: NWConnection
  let handler: @Sendable (LocalHTTPRequest) -> LocalHTTPResponse

  func receive(_ buffered: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
      content, _, complete, error in
      var head = buffered
      if let content { head.append(content) }
      if head.range(of: Data("\r\n\r\n".utf8)) != nil {
        answer(LocalHTTPHead.parse(head))
      } else if head.count > LocalHTTPServer.maxHeadBytes {
        respond(.text(431, "view: request head too large"))
      } else if complete || error != nil {
        connection.cancel()
      } else {
        receive(head)
      }
    }
  }

  private func answer(_ parsed: LocalHTTPHead?) {
    guard let parsed else { return respond(.text(400, "view: not an HTTP request")) }
    // A page on another site that rebinds its name to 127.0.0.1 still sends its own Host.
    let port = localPort ?? 0
    guard LocalHTTPHead.isLocal(parsed.host, port: port) else {
      return respond(.text(403, "view: only 127.0.0.1:\(port) and localhost:\(port) are served"))
    }
    respond(handler(parsed.request))
  }

  private var localPort: UInt16? {
    guard case .hostPort(_, let port) = connection.currentPath?.localEndpoint else { return nil }
    return port.rawValue
  }

  private func respond(_ response: LocalHTTPResponse) {
    var head = "HTTP/1.1 \(response.status) \(LocalHTTPHead.reason(response.status))\r\n"
    head += "Content-Type: \(response.contentType)\r\n"
    head += "Content-Length: \(response.body.count)\r\n"
    head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
    connection.send(
      content: Data(head.utf8) + response.body,
      completion: .contentProcessed { [connection] _ in connection.cancel() })
  }
}

/// A request head's parts the server acts on.
struct LocalHTTPHead: Sendable, Equatable {
  var request: LocalHTTPRequest
  var host: String?

  /// `nil` for anything that isn't `<METHOD> <origin-form target> HTTP/1.x`.
  static func parse(_ data: Data) -> LocalHTTPHead? {
    guard let end = data.range(of: Data("\r\n\r\n".utf8)),
      let text = String(data: data[..<end.lowerBound], encoding: .utf8)
    else { return nil }
    let lines = text.components(separatedBy: "\r\n")
    let parts = lines[0].split(separator: " ", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[2].hasPrefix("HTTP/1."), !parts[0].isEmpty,
      parts[0].allSatisfy({ $0.isASCII && $0.isUppercase }), parts[1].hasPrefix("/"),
      let components = URLComponents(string: String(parts[1]))
    else { return nil }
    var query: [String: String] = [:]
    for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
    var host: String?
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      if line[..<colon].lowercased() == "host" {
        host = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      }
    }
    return LocalHTTPHead(
      request: LocalHTTPRequest(
        method: String(parts[0]), path: components.percentEncodedPath, query: query),
      host: host)
  }

  /// Whether `host`, a `Host` header, names this machine's loopback at `port`.
  static func isLocal(_ host: String?, port: UInt16) -> Bool {
    guard let host else { return false }
    return ["127.0.0.1:\(port)", "localhost:\(port)"].contains(host.lowercased())
  }

  static func reason(_ status: Int) -> String {
    switch status {
    case 200: "OK"
    case 400: "Bad Request"
    case 403: "Forbidden"
    case 404: "Not Found"
    case 405: "Method Not Allowed"
    case 431: "Request Header Fields Too Large"
    case 500: "Internal Server Error"
    default: "Status"
    }
  }
}
