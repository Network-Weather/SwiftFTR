import Foundation

/// Handle for managing and cancelling an in-flight trace operation.
///
/// This actor provides a thread-safe mechanism to cancel ongoing trace operations,
/// particularly useful when network conditions change or when the trace is no longer needed.
///
/// Uses Swift 6's actor isolation for thread safety.
public actor TraceHandle {
  /// Why the operation was cancelled, and the cleanup to run when it is. Lock-protected rather
  /// than actor-isolated so that a task-cancellation handler can record its reason synchronously.
  nonisolated let cancelState = TraceCancelState()

  /// Whether this trace has been cancelled, by the tracer or by its caller.
  public var isCancelled: Bool {
    cancelState.reason != nil
  }

  /// Cancel this trace operation.
  ///
  /// Once cancelled, the trace will stop at the next cancellation check point
  /// and throw `TracerouteError.cancelled`.
  public func cancel() {
    cancelState.cancel(.library)
  }

  /// Records that `reason` ended the operation, from any context, without suspending.
  nonisolated func cancel(for reason: TraceCancellationReason) {
    cancelState.cancel(reason)
  }

  /// Installs the operation-specific cleanup invoked by `cancel()`.
  ///
  /// If cancellation already happened, the handler is invoked immediately so
  /// setup cannot race ahead with an already-cancelled trace.
  ///
  /// - Returns: A monotonically increasing registration ID identifying this handler.
  @discardableResult
  internal func installCancellationHandler(_ handler: @escaping @Sendable () -> Void) -> UInt64 {
    cancelState.installHandler(handler)
  }

  /// Removes an operation-specific cleanup handler after the operation ends.
  ///
  /// If `id` is provided, the handler is only cleared if it matches the specified
  /// registration ID. This prevents an asynchronous or delayed cleanup from clearing
  /// a subsequent phase's newly installed cancellation handler.
  internal func clearCancellationHandler(id: UInt64? = nil) {
    cancelState.clearHandler(id: id)
  }

  /// Whether an in-flight receive operation is currently attached.
  internal var hasCancellationHandler: Bool {
    cancelState.hasHandler
  }

  /// The error the operation must report if it stops now, or `nil` if nothing has cancelled it.
  ///
  /// The recorded reason decides. The calling task's own cancelled flag stands in for the caller's
  /// reason, because a task is marked cancelled before its cancellation handlers run.
  nonisolated func cancellationError() -> Error? {
    if let reason = cancelState.reason { return reason.error }
    return Task.isCancelled ? CancellationError() : nil
  }

  /// Throws the error ``cancellationError()`` names, if any.
  nonisolated func checkCancellation() throws {
    if let error = cancellationError() { throw error }
  }

  /// The error to report for an operation that failed with `error`: the cancellation that ended
  /// it, if one did, otherwise `error` itself.
  nonisolated func reportedError(for error: Error) -> Error {
    if let reason = cancelState.reason { return reason.error }
    if Task.isCancelled, error.isCancellation { return CancellationError() }
    return error
  }

  init() {}
}

/// What ended an operation. When more than one applies, the one of highest precedence is reported.
enum TraceCancellationReason: Sendable, Equatable {
  /// The caller cancelled its own task, or a stream's consumer stopped iterating.
  case callerTask
  /// The tracer ended it: `cancelActiveTraces()` or `networkChanged()`.
  case library

  /// Higher wins. A reason never gives way to one of lower precedence.
  var precedence: Int {
    switch self {
    case .callerTask: 0
    case .library: 1
    }
  }

  /// The error an operation ended for this reason throws.
  var error: Error {
    switch self {
    case .callerTask: CancellationError()
    case .library: TracerouteError.cancelled
    }
  }
}

extension Error {
  /// Whether this is one of the two errors that report a cancellation.
  var isCancellation: Bool {
    if self is CancellationError { return true }
    if case TracerouteError.cancelled? = self as? TracerouteError { return true }
    return false
  }
}

/// A trace handle's cancellation reason and cleanup handler, settable from any context.
final class TraceCancelState: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedReason: TraceCancellationReason?
  private var handler: (@Sendable () -> Void)?
  private var handlerRegistrationID: UInt64 = 0

  /// The reason recorded so far, or `nil` if nothing has cancelled the operation.
  var reason: TraceCancellationReason? {
    lock.lock()
    defer { lock.unlock() }
    return recordedReason
  }

  /// Records `reason` unless one of higher precedence is already recorded. The first cancellation,
  /// whatever its reason, runs the installed handler, outside the lock.
  func cancel(_ reason: TraceCancellationReason) {
    lock.lock()
    guard let current = recordedReason else {
      recordedReason = reason
      let pending = handler
      handler = nil
      lock.unlock()
      pending?()
      return
    }
    if reason.precedence > current.precedence { recordedReason = reason }
    lock.unlock()
  }

  /// Installs `handler`, or runs it at once if the operation is already cancelled.
  func installHandler(_ newHandler: @escaping @Sendable () -> Void) -> UInt64 {
    lock.lock()
    handlerRegistrationID &+= 1
    let id = handlerRegistrationID
    guard recordedReason == nil else {
      lock.unlock()
      newHandler()
      return id
    }
    handler = newHandler
    lock.unlock()
    return id
  }

  /// Clears the handler, if `id` is `nil` or still names the latest registration.
  func clearHandler(id: UInt64?) {
    lock.lock()
    defer { lock.unlock() }
    if let id, id != handlerRegistrationID { return }
    handler = nil
  }

  var hasHandler: Bool {
    lock.lock()
    defer { lock.unlock() }
    return handler != nil
  }
}

// Extension to make TraceHandle Hashable for use in Set
extension TraceHandle: Hashable {
  nonisolated public static func == (lhs: TraceHandle, rhs: TraceHandle) -> Bool {
    ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
  }

  nonisolated public func hash(into hasher: inout Hasher) {
    ObjectIdentifier(self).hash(into: &hasher)
  }
}

/// A thread-safe box that synchronizes task completion with cancellation.
private final class CancellationContinuationBox<T: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<T, Error>?
  private var isCancelled = false
  private var hasResumed = false

  func cancel() {
    lock.lock()
    guard !hasResumed else {
      lock.unlock()
      return
    }
    isCancelled = true
    if let cont = continuation {
      continuation = nil
      hasResumed = true
      lock.unlock()
      cont.resume(throwing: TracerouteError.cancelled)
    } else {
      lock.unlock()
    }
  }

  func attach(continuation: CheckedContinuation<T, Error>, task: Task<T, Error>) {
    lock.lock()
    if isCancelled {
      hasResumed = true
      lock.unlock()
      continuation.resume(throwing: TracerouteError.cancelled)
      return
    }
    self.continuation = continuation
    lock.unlock()

    Task {
      do {
        let value = try await task.value
        self.resume(with: .success(value))
      } catch {
        self.resume(with: .failure(error))
      }
    }
  }

  private func resume(with result: Result<T, Error>) {
    lock.lock()
    guard !hasResumed else {
      lock.unlock()
      return
    }
    hasResumed = true
    let cont = continuation
    continuation = nil
    lock.unlock()
    cont?.resume(with: result)
  }
}

/// Executes an async throwing operation wrapped in an interruptible cancellation race with a `TraceHandle`.
///
/// If `handle` is cancelled (e.g. via `cancelActiveTraces()`) or the calling task is cancelled while the
/// operation is in flight, the operation task is cancelled and this function immediately throws
/// without stranding the caller: `TracerouteError.cancelled` for the tracer's cancellation,
/// `CancellationError` for the caller's (see ``TraceHandle/reportedError(for:)``).
internal func withTraceCancellation<T: Sendable>(
  handle: TraceHandle?,
  _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  guard let handle else {
    return try await operation()
  }
  try handle.checkCancellation()

  let task = Task {
    try await operation()
  }

  let box = CancellationContinuationBox<T>()
  let registrationID = await handle.installCancellationHandler {
    task.cancel()
    box.cancel()
  }

  do {
    let result = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        box.attach(continuation: continuation, task: task)
      }
    } onCancel: {
      task.cancel()
      box.cancel()
    }
    await handle.clearCancellationHandler(id: registrationID)
    return result
  } catch {
    await handle.clearCancellationHandler(id: registrationID)
    task.cancel()
    box.cancel()
    throw handle.reportedError(for: error)
  }
}

/// Returns once `handle` is cancelled or the calling task is, whichever comes first.
///
/// Occupies the handle's single cancellation-handler slot, so use it only on a handle that no other
/// phase installs a handler on.
internal func waitForCancellation(of handle: TraceHandle) async {
  let signal = OneShotSignal()
  let registrationID = await handle.installCancellationHandler { signal.fire() }
  await withTaskCancellationHandler {
    await signal.wait()
  } onCancel: {
    signal.fire()
  }
  await handle.clearCancellationHandler(id: registrationID)
}

/// Resumes one waiter once `fire()` has been called, however the two are ordered.
private final class OneShotSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var fired = false
  private var waiter: CheckedContinuation<Void, Never>?

  func wait() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if fired {
        lock.unlock()
        continuation.resume()
      } else {
        waiter = continuation
        lock.unlock()
      }
    }
  }

  func fire() {
    lock.lock()
    fired = true
    let pending = waiter
    waiter = nil
    lock.unlock()
    pending?.resume()
  }
}
