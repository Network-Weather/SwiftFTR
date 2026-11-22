import Foundation
import Testing

@testable import SwiftFTR

#if canImport(Darwin)
  import Darwin
#endif

/// The fault-injection fixtures themselves: a fixture that misbehaves in the wrong way would make
/// every test built on it mean something else.
@Suite("FaultInjection: fixtures")
struct FaultInjectionFixtureTests {

  @Test("A stall gate that timed out does not release the next waiter; open() releases all")
  func stallGate() async throws {
    let gate = StallGate()
    gate.wait(limit: 0.01)
    let start = monotonicNow()
    gate.wait(limit: 0.25)
    #expect(monotonicNow() - start >= 0.2, "a timed-out wait released the next one")

    let released = FaultCounter()
    for _ in 0..<3 {
      Thread.detachNewThread {
        gate.wait(limit: 5)
        released.increment()
      }
    }
    try await Task.sleep(nanoseconds: 50_000_000)
    gate.open()
    #expect(await eventually(within: 1) { released.value == 3 })
  }

  @Test("The watchdog fails an operation that never returns, without waiting for it")
  func watchdogFires() async throws {
    let start = monotonicNow()
    await #expect(throws: WatchdogExpired.self) {
      _ = try await measure(within: 0.2) {
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
      }
    }
    #expect(monotonicNow() - start < 1.0)
  }

  @Test("The UDP responder hands a zero-byte request to its script")
  func udpZeroByteRequest() async throws {
    let responder = try LoopbackUDPResponder { _ in ([0x2A], 0) }
    defer { responder.stop() }
    let client = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    defer { close(client) }
    setReceiveTimeout(client, seconds: 1)
    var (address, length) = responder.address
    let sent = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(client, nil, 0, 0, $0, length) }
    }
    #expect(sent == 0)
    var reply = [UInt8](repeating: 0, count: 8)
    let received = recv(client, &reply, reply.count, 0)
    #expect(received == 1)
    #expect(responder.requests.value == 1)
  }

  @Test("The refusing TCP port resets connections and stays reserved")
  func refusingPort() throws {
    let refusing = try RefusingTCPPort()

    let client = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(client) }
    var (address, length) = loopbackAddress(family: AF_INET, port: refusing.port)
    let start = monotonicNow()
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, length) }
    }
    let code = errno
    #expect(result == -1 && code == ECONNREFUSED, "connect returned \(result), errno \(code)")
    #expect(monotonicNow() - start < 0.5, "the refusal was not immediate")

    // Nothing else may take the port while the fixture holds it.
    let rival = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(rival) }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(rival, $0, length) }
    }
    #expect(bound == -1 && errno == EADDRINUSE, "another socket could bind the refusing port")
  }

  @Test(
    "Stopping the TCP server ends every handler before it returns",
    arguments: [
      LoopbackTCPServer.Behavior.silent,
      .respond(response: Array("late".utf8), after: 30),
    ])
  func tcpServerStopJoinsHandlers(behavior: LoopbackTCPServer.Behavior) async throws {
    let server = try LoopbackTCPServer(behavior: behavior)
    let client = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(client) }
    var (address, length) = loopbackAddress(family: AF_INET, port: server.port)
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, length) }
    }
    #expect(connected == 0)
    _ = Darwin.send(client, "GET / HTTP/1.1\r\n\r\n", 18, 0)
    #expect(await eventually(within: 2) { server.accepted.value == 1 })

    // Run on its own thread under a watchdog, so a stop() that never returns fails the test
    // instead of hanging the run.
    let stoppedPromptly = await returnsWithin(1.0) { server.stop() }
    #expect(stoppedPromptly, "stop() waited for a handler's own timeout")

    // The handler closed its end, so the client sees end-of-file rather than a live peer.
    setReceiveTimeout(client, seconds: 1)
    var buffer = [UInt8](repeating: 0, count: 16)
    #expect(recv(client, &buffer, buffer.count, 0) <= 0)
  }
}
