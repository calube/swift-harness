import Darwin
import Foundation
import SwiftGateAdapters
import Synchronization
import Testing

/// Talks to a real ``LocalHTTPServer`` over BSD sockets, so nothing between the test and the
/// listener interprets the bytes.
@Suite("local HTTP server")
struct LocalHTTPServerTests {
  /// The first IPv4 address of an interface that is up and not loopback; `nil` on a machine
  /// with none.
  static let outwardAddress: String? = {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return nil }
    defer { freeifaddrs(list) }
    for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
      let flags = Int32(entry.pointee.ifa_flags)
      guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == AF_INET,
        flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0
      else { continue }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard
        getnameinfo(
          address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
          NI_NUMERICHOST) == 0
      else { continue }
      return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    return nil
  }()

  enum Exchange: Equatable {
    case answered(String)
    /// `connect` failed with this errno.
    case refused(Int32)
  }

  /// Sends `request` to `host:port` and reads until the server closes.
  static func exchange(_ request: String, host: String = "127.0.0.1", port: UInt16) -> Exchange {
    let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    defer { close(socket) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    inet_pton(AF_INET, host, &address.sin_addr)
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard connected == 0 else { return .refused(errno) }
    let bytes = Array(request.utf8)
    _ = bytes.withUnsafeBytes { write(socket, $0.baseAddress, $0.count) }
    var answer = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = read(socket, &buffer, buffer.count)
      guard count > 0 else { break }
      answer.append(contentsOf: buffer[0..<count])
    }
    return .answered(String(decoding: answer, as: UTF8.self))
  }

  static func get(_ target: String, host: String = "127.0.0.1", port: UInt16) -> String {
    "GET \(target) HTTP/1.1\r\nHost: \(host):\(port)\r\nConnection: close\r\n\r\n"
  }

  @Test(
    "a GET on 127.0.0.1 reaches the handler with its path and decoded query and returns its answer — catches a server that never answers or mangles the cursor"
  )
  func roundTrip() async throws {
    let server = LocalHTTPServer()
    defer { server.stop() }
    let seen = Mutex<[LocalHTTPRequest]>([])
    let port = try await server.start(port: 0) { request in
      seen.withLock { $0.append(request) }
      return LocalHTTPResponse(
        status: 200, contentType: "application/json", body: Data("{\"ok\":true}".utf8))
    }
    #expect(port != 0)

    let answer = Self.exchange(Self.get("/changes?after=c%2B1%20x", port: port), port: port)

    guard case .answered(let text) = answer else {
      Issue.record("the server refused 127.0.0.1: \(answer)")
      return
    }
    #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
    #expect(text.contains("Content-Type: application/json\r\n"))
    #expect(text.contains("Content-Length: 11\r\n"))
    #expect(text.contains("Cache-Control: no-store\r\n"))
    #expect(text.hasSuffix("\r\n\r\n{\"ok\":true}"))
    #expect(
      seen.withLock { $0 }
        == [LocalHTTPRequest(method: "GET", path: "/changes", query: ["after": "c+1 x"])])
  }

  @Test(
    "the server refuses a connection on this machine's outward address — catches a 0.0.0.0 bind",
    .enabled(if: outwardAddress != nil, "this machine has no non-loopback IPv4 address"))
  func refusesOutwardAddress() async throws {
    let address = try #require(Self.outwardAddress)
    let server = LocalHTTPServer()
    defer { server.stop() }
    let port = try await server.start(port: 0) { _ in .text(200, "ok") }

    #expect(
      Self.exchange(Self.get("/", host: address, port: port), host: address, port: port)
        == .refused(ECONNREFUSED))
    guard case .answered(let text) = Self.exchange(Self.get("/", port: port), port: port) else {
      Issue.record("the server refused 127.0.0.1 as well")
      return
    }
    #expect(text.hasPrefix("HTTP/1.1 200 OK"))
  }

  @Test(
    "a request naming another host is refused before the handler runs — catches a page another site can read through DNS rebinding"
  )
  func refusesForeignHost() async throws {
    let server = LocalHTTPServer()
    defer { server.stop() }
    let calls = Mutex(0)
    let port = try await server.start(port: 0) { _ in
      calls.withLock { $0 += 1 }
      return .text(200, "ok")
    }

    let foreign = "GET / HTTP/1.1\r\nHost: attacker.example:\(port)\r\n\r\n"
    let local = "GET / HTTP/1.1\r\nHost: localhost:\(port)\r\n\r\n"

    guard case .answered(let refused) = Self.exchange(foreign, port: port) else {
      Issue.record("the server dropped the connection")
      return
    }
    #expect(refused.hasPrefix("HTTP/1.1 403 "))
    #expect(calls.withLock { $0 } == 0)
    guard case .answered(let text) = Self.exchange(local, port: port) else {
      Issue.record("the server refused a localhost Host")
      return
    }
    #expect(text.hasPrefix("HTTP/1.1 200 OK"))
    #expect(calls.withLock { $0 } == 1)
  }

  @Test(
    "a request line that isn't HTTP gets 400 and never reaches the handler — catches a parser that guesses"
  )
  func rejectsMalformedRequest() async throws {
    let server = LocalHTTPServer()
    defer { server.stop() }
    let calls = Mutex(0)
    let port = try await server.start(port: 0) { _ in
      calls.withLock { $0 += 1 }
      return .text(200, "ok")
    }

    guard case .answered(let text) = Self.exchange("hello\r\n\r\n", port: port) else {
      Issue.record("the server refused the connection")
      return
    }
    #expect(text.hasPrefix("HTTP/1.1 400 "))
    #expect(calls.withLock { $0 } == 0)
  }

  @Test(
    "a port already taken fails start instead of hanging — catches a server that waits forever for readiness"
  )
  func takenPortFails() async throws {
    let first = LocalHTTPServer()
    defer { first.stop() }
    let port = try await first.start(port: 0) { _ in .text(200, "ok") }
    let second = LocalHTTPServer()
    defer { second.stop() }
    await #expect(throws: (any Error).self) {
      _ = try await second.start(port: port) { _ in .text(200, "ok") }
    }
  }
}
