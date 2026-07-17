import Foundation
import Testing

@testable import SwiftFTR

#if canImport(Darwin)
  import Darwin
#endif

@Suite("Ping Lifecycle Tests")
struct PingLifecycleTests {
  @Test("Setup failure closes the socket exactly once")
  func setupFailureClosesSocketExactlyOnce() async throws {
    let closes = SocketCloseRecorder()
    let executor = PingExecutor(
      config: SwiftFTRConfig(),
      closeSocket: { closes.closeAndRecord($0) }
    )

    await #expect {
      try await executor.ping(
        to: "127.0.0.1",
        config: PingConfig(
          count: 1,
          interval: 0,
          timeout: 1,
          sourceIP: "not-an-ip-address",
          preferredFamily: .v4
        )
      )
    } throws: { error in
      guard case TracerouteError.sourceIPBindFailed = error else { return false }
      return true
    }

    #expect(closes.count == 1)
    #expect(closes.allSucceeded)
  }

  @Test("Cancellation before setup skips sends and closes once")
  func cancellationBeforeSetupSkipsSendsAndClosesOnce() async throws {
    let fixture = try PingOperationFixture(
      config: PingConfig(count: 3, interval: 60, timeout: 1, preferredFamily: .v4)
    )

    fixture.operation.cancel()
    fixture.operation.cancel()

    await #expect {
      try await fixture.operation.run()
    } throws: { isPingCancellation($0) }

    #expect(fixture.sends.count == 0)
    #expect(fixture.closes.count == 1)
    #expect(fixture.closes.allSucceeded)
  }

  @Test("Already-cancelled task skips setup and throws cancellation")
  func alreadyCancelledTaskSkipsSetupAndThrowsCancellation() async throws {
    let fixture = try PingOperationFixture(
      config: PingConfig(count: 3, interval: 60, timeout: 1, preferredFamily: .v4)
    )
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await fixture.operation.run()
    }

    await #expect {
      try await task.value
    } throws: { isPingCancellation($0) }

    #expect(fixture.sends.count == 0)
    #expect(fixture.closes.count == 1)
    #expect(fixture.closes.allSucceeded)
  }

  @Test("In-flight cancellation stops the sender and closes before returning")
  func inFlightCancellationStopsSenderAndClosesBeforeReturning() async throws {
    let fixture = try PingOperationFixture(
      config: PingConfig(count: 3, interval: 60, timeout: 1, preferredFamily: .v4)
    )
    let task = Task { try await fixture.operation.run() }

    await fixture.sends.waitForFirstSend()
    task.cancel()

    await #expect {
      try await task.value
    } throws: { isPingCancellation($0) }

    // `run()` resumes only after the stored sender task has exited. A leaked or
    // uncancelled sender would enqueue later sequences after this point.
    #expect(fixture.sends.count == 1)
    #expect(fixture.closes.count == 1)
    #expect(fixture.closes.allSucceeded)
  }

  @Test("Normal completion releases sources, sender, and socket once")
  func normalCompletionReleasesResourcesOnce() async throws {
    let fixture = try PingOperationFixture(
      config: PingConfig(count: 1, interval: 0, timeout: 0, preferredFamily: .v4)
    )

    let result = try await fixture.operation.run()
    fixture.operation.cancel()

    #expect(result.responses.count == 1)
    #expect(result.statistics.sent == 1)
    #expect(fixture.sends.count == 1)
    #expect(fixture.closes.count == 1)
    #expect(fixture.closes.allSucceeded)
  }
}

private struct PingOperationFixture {
  let sends: PingSendRecorder
  let closes: SocketCloseRecorder
  let operation: PingOperation

  init(config: PingConfig) throws {
    let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    try #require(descriptor >= 0)

    let sends = PingSendRecorder()
    let closes = SocketCloseRecorder()
    let resolved = try resolveHost(host: "127.0.0.1", prefer: .v4)

    self.sends = sends
    self.closes = closes
    self.operation = PingOperation(
      sockfd: descriptor,
      target: "127.0.0.1",
      resolved: resolved,
      config: config,
      identifier: 0x1234,
      sendPacket: { _, _, _ in sends.recordSend() },
      monotonicTime: { monotonicNow() },
      closeSocket: { closes.closeAndRecord($0) }
    )
  }
}

private final class PingSendRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var sendCount = 0
  private var firstSendContinuation: CheckedContinuation<Void, Never>?

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return sendCount
  }

  func recordSend() {
    lock.lock()
    sendCount += 1
    let continuation = sendCount == 1 ? firstSendContinuation : nil
    if continuation != nil { firstSendContinuation = nil }
    lock.unlock()

    continuation?.resume()
  }

  func waitForFirstSend() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if sendCount > 0 {
        lock.unlock()
        continuation.resume()
      } else {
        precondition(firstSendContinuation == nil)
        firstSendContinuation = continuation
        lock.unlock()
      }
    }
  }
}

private final class SocketCloseRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var calls: [(descriptor: Int32, result: Int32)] = []

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return calls.count
  }

  var allSucceeded: Bool {
    lock.lock()
    defer { lock.unlock() }
    return calls.allSatisfy { $0.result == 0 }
  }

  func closeAndRecord(_ descriptor: Int32) {
    let result = Darwin.close(descriptor)
    lock.lock()
    calls.append((descriptor, result))
    lock.unlock()
  }
}

private func isPingCancellation(_ error: any Error) -> Bool {
  guard case TracerouteError.cancelled = error else { return false }
  return true
}
