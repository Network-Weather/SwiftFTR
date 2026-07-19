import Dispatch
import Foundation
import Testing

@testable import SwiftFTR

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

@Suite("TCP probe cancellation")
struct TCPProbeCancellationTests {
  @Test("an already-cancelled public probe throws CancellationError")
  func cancellationBeforePublicProbeStarts() async {
    let task = Task {
      withUnsafeCurrentTask { task in
        task?.cancel()
      }
      return try await tcpProbe(host: "127.0.0.1", port: 9, timeout: 60)
    }

    do {
      _ = try await task.value
      Issue.record("Expected the probe to throw CancellationError")
    } catch {
      #expect(error is CancellationError)
    }
  }

  @Test("setup cancellation cleans up its owned descriptor before throwing")
  func cancellationDuringSynchronousSetup() async {
    let outcome = await Task { () -> (threwCancellation: Bool, cleanedUp: Bool) in
      withUnsafeCurrentTask { task in
        task?.cancel()
      }

      var cleanedUp = false
      do {
        try checkTCPProbeSetupCancellation {
          cleanedUp = true
        }
        return (false, cleanedUp)
      } catch is CancellationError {
        return (true, cleanedUp)
      } catch {
        return (false, cleanedUp)
      }
    }.value

    #expect(outcome.threwCancellation)
    #expect(outcome.cleanedUp)
  }

  @Test("cancellation before operation start closes once without installing sources")
  func cancellationBeforeOperationStarts() async {
    let driver = TCPProbeTestDriver(socketError: 0)
    let operation = makeOperation(driver: driver, descriptor: 101)
    let task = Task {
      withUnsafeCurrentTask { task in
        task?.cancel()
      }
      return try await operation.run()
    }

    do {
      _ = try await task.value
      Issue.record("Expected the operation to throw CancellationError")
    } catch {
      #expect(error is CancellationError)
    }

    #expect(!driver.didInstallSources)
    #expect(driver.sourceCancellationCount == 0)
    #expect(driver.socketCloseCount == 1)
    #expect(driver.socketErrorReadCount == 0)
  }

  @Test("cancelling a pending connect beats timeout and cleans up before resuming")
  func cancellationWhileWaiting() async throws {
    let driver = TCPProbeTestDriver(socketError: 0)
    let operation = makeOperation(driver: driver, descriptor: 102)
    let task = Task { try await operation.run() }

    await driver.waitUntilInstalled()
    task.cancel()
    try await driver.triggerTimeout()

    do {
      _ = try await task.value
      Issue.record("Expected the operation to throw CancellationError")
    } catch {
      #expect(error is CancellationError)
    }

    #expect(driver.cleanupEvents == [.sourcesCancelled, .socketClosed])
    #expect(driver.sourceCancellationCount == 1)
    #expect(driver.socketCloseCount == 1)
    #expect(driver.socketErrorReadCount == 0)
  }

  @Test("socket close waits for the write source cancellation handler")
  func socketCloseWaitsForSourceCancellationHandler() async throws {
    let driver = TCPProbeTestDriver(
      socketError: 0,
      delaySourceCancellationHandler: true
    )
    let operation = makeOperation(driver: driver, descriptor: 103)
    let task = Task { try await operation.run() }

    await driver.waitUntilInstalled()
    task.cancel()
    await driver.waitUntilSourceCancellationRequested()
    try await driver.drainEventQueue()

    // DispatchSource.cancel() is asynchronous. Even after finish() returns,
    // the descriptor and continuation remain owned until the source's
    // cancellation handler confirms that Dispatch has released the descriptor.
    #expect(driver.sourceCancellationCount == 1)
    #expect(driver.socketCloseCount == 0)
    #expect(driver.cleanupEvents.isEmpty)
    #expect(driver.socketErrorReadCount == 0)

    try await driver.triggerSourceCancellationHandler()

    do {
      _ = try await task.value
      Issue.record("Expected the operation to throw CancellationError")
    } catch {
      #expect(error is CancellationError)
    }

    #expect(driver.cleanupEvents == [.sourcesCancelled, .socketClosed])
    #expect(driver.sourceCancellationCount == 1)
    #expect(driver.socketCloseCount == 1)
    #expect(driver.socketErrorReadCount == 0)
  }

  @Test("completion and cancellation races resume once and never inspect a reused descriptor")
  func completionCancellationRaces() async throws {
    for descriptor in 200..<250 {
      let driver = TCPProbeTestDriver(socketError: 0)
      let operation = makeOperation(driver: driver, descriptor: Int32(descriptor))
      let task = Task { try await operation.run() }

      await driver.waitUntilInstalled()

      await withTaskGroup(of: Void.self) { group in
        group.addTask {
          task.cancel()
        }
        group.addTask {
          try? await driver.triggerConnectCompletion()
        }
      }

      do {
        let result = try await task.value
        #expect(result.isReachable)
        #expect(result.connectionState == .open)
      } catch {
        #expect(error is CancellationError)
      }

      #expect(driver.sourceCancellationCount == 1)
      #expect(driver.socketCloseCount == 1)

      // Simulate old callbacks arriving after the numeric descriptor could have
      // been reused by another socket. They must observe completion before
      // calling the injected SO_ERROR operation.
      try await driver.triggerConnectCompletion()
      try await driver.triggerTimeout()

      #expect(driver.sourceCancellationCount == 1)
      #expect(driver.socketCloseCount == 1)
      #expect(driver.postCloseSocketErrorReadCount == 0)
    }
  }

  @Test("successful and refused connects retain their reachable semantics")
  func successSemantics() async throws {
    let cases: [(error: Int32, state: TCPConnectionState)] = [
      (0, .open),
      (ECONNREFUSED, .closed),
    ]

    for (index, testCase) in cases.enumerated() {
      let driver = TCPProbeTestDriver(socketError: testCase.error)
      let operation = makeOperation(driver: driver, descriptor: Int32(300 + index))
      let task = Task { try await operation.run() }

      await driver.waitUntilInstalled()
      try await driver.triggerConnectCompletion()
      let result = try await task.value

      #expect(result.isReachable)
      #expect(result.connectionState == testCase.state)
      #expect(result.rtt == 2)
      #expect(result.error == nil)
      #expect(driver.cleanupEvents == [.sourcesCancelled, .socketClosed])
      #expect(driver.sourceCancellationCount == 1)
      #expect(driver.socketCloseCount == 1)
      #expect(driver.socketErrorReadCount == 1)
      #expect(driver.postCloseSocketErrorReadCount == 0)
    }
  }

  private func makeOperation(
    driver: TCPProbeTestDriver,
    descriptor: Int32
  ) -> TCPProbeOperation {
    TCPProbeOperation(
      sockfd: descriptor,
      timeout: 60,
      probeStartTime: 10,
      dependencies: driver.dependencies
    )
  }
}

private enum TCPProbeTestDriverError: Error {
  case sourcesNotInstalled
  case sourceCancellationNotRequested
}

private enum TCPProbeCleanupEvent: Equatable, Sendable {
  case sourcesCancelled
  case socketClosed
}

/// A deterministic stand-in for Dispatch sources and socket syscalls.
private final class TCPProbeTestDriver: @unchecked Sendable {
  private struct State {
    var queue: DispatchQueue?
    var connectCompleted: (@Sendable () -> Void)?
    var timedOut: (@Sendable () -> Void)?
    var writeSourceDidCancel: (@Sendable () -> Void)?
    var didInstallSources = false
    var sourceCancellationCount = 0
    var socketCloseCount = 0
    var socketErrorReadCount = 0
    var postCloseSocketErrorReadCount = 0
    var cleanupEvents: [TCPProbeCleanupEvent] = []
  }

  private let socketErrorValue: Int32
  private let delaySourceCancellationHandler: Bool
  private let lock = NSLock()
  private var state = State()
  private let installedEvents: AsyncStream<Void>
  private let installedContinuation: AsyncStream<Void>.Continuation
  private let sourceCancellationRequests: AsyncStream<Void>
  private let sourceCancellationRequestContinuation: AsyncStream<Void>.Continuation

  init(socketError: Int32, delaySourceCancellationHandler: Bool = false) {
    socketErrorValue = socketError
    self.delaySourceCancellationHandler = delaySourceCancellationHandler

    let (stream, continuation) = AsyncStream<Void>.makeStream()
    installedEvents = stream
    installedContinuation = continuation

    let (cancellationStream, cancellationContinuation) = AsyncStream<Void>.makeStream()
    sourceCancellationRequests = cancellationStream
    sourceCancellationRequestContinuation = cancellationContinuation
  }

  var dependencies: TCPProbeOperationDependencies {
    TCPProbeOperationDependencies(
      makeEventSources: {
        [self] _, _, queue, connectCompleted, timedOut, writeSourceDidCancel in
        withState { state in
          state.queue = queue
          state.connectCompleted = connectCompleted
          state.timedOut = timedOut
          state.writeSourceDidCancel = writeSourceDidCancel
          state.didInstallSources = true
        }
        installedContinuation.yield()
        installedContinuation.finish()

        return TCPProbeEventSources { [self] in
          let immediateCancellationHandler: (@Sendable () -> Void)? = withState { state in
            state.sourceCancellationCount += 1
            guard !delaySourceCancellationHandler else {
              return nil
            }
            let handler = state.writeSourceDidCancel
            state.writeSourceDidCancel = nil
            return handler
          }

          sourceCancellationRequestContinuation.yield()
          sourceCancellationRequestContinuation.finish()

          if let immediateCancellationHandler {
            invokeSourceCancellationHandler(immediateCancellationHandler)
          }
        }
      },
      socketError: { [self] _ in
        withState { state in
          state.socketErrorReadCount += 1
          if state.socketCloseCount > 0 {
            state.postCloseSocketErrorReadCount += 1
          }
        }
        return socketErrorValue
      },
      closeSocket: { [self] _ in
        withState { state in
          state.socketCloseCount += 1
          state.cleanupEvents.append(.socketClosed)
        }
      },
      now: { 12 }
    )
  }

  var didInstallSources: Bool {
    withState { $0.didInstallSources }
  }

  var sourceCancellationCount: Int {
    withState { $0.sourceCancellationCount }
  }

  var socketCloseCount: Int {
    withState { $0.socketCloseCount }
  }

  var socketErrorReadCount: Int {
    withState { $0.socketErrorReadCount }
  }

  var postCloseSocketErrorReadCount: Int {
    withState { $0.postCloseSocketErrorReadCount }
  }

  var cleanupEvents: [TCPProbeCleanupEvent] {
    withState { $0.cleanupEvents }
  }

  func waitUntilInstalled() async {
    if didInstallSources {
      return
    }

    for await _ in installedEvents {
      return
    }
  }

  func waitUntilSourceCancellationRequested() async {
    if sourceCancellationCount > 0 {
      return
    }

    for await _ in sourceCancellationRequests {
      return
    }
  }

  func drainEventQueue() async throws {
    guard let queue = withState({ $0.queue }) else {
      throw TCPProbeTestDriverError.sourcesNotInstalled
    }
    await invoke({}, on: queue)
  }

  func triggerSourceCancellationHandler() async throws {
    let event: (queue: DispatchQueue, callback: @Sendable () -> Void)? = withState { state in
      guard
        state.sourceCancellationCount > 0,
        let queue = state.queue,
        let callback = state.writeSourceDidCancel
      else {
        return nil
      }

      state.writeSourceDidCancel = nil
      return (queue, callback)
    }
    guard let (queue, callback) = event else {
      throw TCPProbeTestDriverError.sourceCancellationNotRequested
    }

    await invoke(
      { [self] in
        invokeSourceCancellationHandler(callback)
      },
      on: queue
    )
  }

  func triggerConnectCompletion() async throws {
    let event = withState { state in
      state.queue.flatMap { queue in
        state.connectCompleted.map { callback in (queue, callback) }
      }
    }
    guard let (queue, callback) = event else {
      throw TCPProbeTestDriverError.sourcesNotInstalled
    }
    await invoke(callback, on: queue)
  }

  func triggerTimeout() async throws {
    let event = withState { state in
      state.queue.flatMap { queue in
        state.timedOut.map { callback in (queue, callback) }
      }
    }
    guard let (queue, callback) = event else {
      throw TCPProbeTestDriverError.sourcesNotInstalled
    }
    await invoke(callback, on: queue)
  }

  private func invoke(
    _ callback: @escaping @Sendable () -> Void,
    on queue: DispatchQueue
  ) async {
    await withCheckedContinuation { continuation in
      queue.async {
        callback()
        continuation.resume()
      }
    }
  }

  private func invokeSourceCancellationHandler(
    _ callback: @escaping @Sendable () -> Void
  ) {
    withState { state in
      state.cleanupEvents.append(.sourcesCancelled)
    }
    callback()
  }

  private func withState<T>(_ body: (inout State) -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body(&state)
  }
}
