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
    #expect(await eventually(within: 10) { released.value == 3 })
  }

  @Test("The watchdog fails an operation that never returns, without waiting for it")
  func watchdogFires() async throws {
    // The operation ignores cancellation and is held by a gate that opens only once the watchdog
    // has returned, so a watchdog that returns at all did so without waiting for it. The gate's
    // own limit ends the operation if a watchdog that waits holds the gate shut.
    let gate = StallGate()
    defer { gate.open() }
    let finished = FaultCounter()
    await #expect(throws: WatchdogExpired.self) {
      _ = try await measure(within: 0.2) {
        await gate.waitAsync(limit: 20)
        finished.increment()
      }
    }
    #expect(finished.value == 0, "the watchdog returned only after the operation had ended")

    // Released, the abandoned operation ends, so nothing is stranded.
    gate.open()
    #expect(
      await eventually(within: 10) { finished.value == 1 }, "the abandoned operation never ended")
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
    // Non-blocking, so a SYN that is dropped rather than reset fails the poll's 10 s watchdog
    // instead of holding the test for the minute and more a blocking connect would wait.
    _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL, 0) | O_NONBLOCK)
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, length) }
    }
    var code = errno
    if result == -1 && code == EINPROGRESS {
      var pending = pollfd(fd: client, events: Int16(POLLOUT), revents: 0)
      let ready = poll(&pending, 1, 10_000)
      #expect(ready == 1, "the connect was neither refused nor accepted within 10 s")
      var soError: Int32 = 0
      var soErrorLength = socklen_t(MemoryLayout<Int32>.size)
      _ = getsockopt(client, SOL_SOCKET, SO_ERROR, &soError, &soErrorLength)
      code = soError
    }
    #expect(code == ECONNREFUSED, "connect returned \(result), errno \(code)")

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
    let exitGate = StallGate()
    defer { exitGate.open() }
    let server = try LoopbackTCPServer(behavior: behavior, exitGate: exitGate)
    let client = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(client) }
    var (address, length) = loopbackAddress(family: AF_INET, port: server.port)
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, length) }
    }
    #expect(connected == 0)
    _ = Darwin.send(client, "GET / HTTP/1.1\r\n\r\n", 18, 0)
    #expect(await eventually(within: 10) { server.accepted.value == 1 })

    // stop() runs on its own thread. The handler is held at the exit gate, so stop() must not
    // return until the gate opens: returning earlier means it did not wait for the handler.
    let stopped = FaultCounter()
    Thread.detachNewThread {
      server.stop()
      stopped.increment()
    }
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(stopped.value == 0, "stop() returned while a handler was still running")

    // Released, the handler finishes and stop() returns, without waiting for the handler's own
    // 30 s behavior.
    exitGate.open()
    #expect(await eventually(within: 10) { stopped.value == 1 }, "stop() did not return")

    // The connection was shut down, so the client sees end-of-file: 0, not a receive timeout.
    setReceiveTimeout(client, seconds: 1)
    var buffer = [UInt8](repeating: 0, count: 16)
    let received = recv(client, &buffer, buffer.count, 0)
    #expect(received == 0, "recv returned \(received), errno \(errno)")
  }
}
