import Foundation

/// Handle for managing and cancelling an in-flight trace operation.
///
/// This actor provides a thread-safe mechanism to cancel ongoing trace operations,
/// particularly useful when network conditions change or when the trace is no longer needed.
///
/// Uses Swift 6's actor isolation for thread safety.
public actor TraceHandle {
  private var _isCancelled = false
  private var cancellationHandler: (@Sendable () -> Void)?
  private var handlerRegistrationID: UInt64 = 0

  /// Whether this trace has been cancelled.
  public var isCancelled: Bool {
    _isCancelled
  }

  /// Cancel this trace operation.
  ///
  /// Once cancelled, the trace will stop at the next cancellation check point
  /// and throw `TracerouteError.cancelled`.
  public func cancel() {
    guard !_isCancelled else { return }
    _isCancelled = true
    let handler = cancellationHandler
    cancellationHandler = nil
    handler?()
  }

  /// Installs the operation-specific cleanup invoked by `cancel()`.
  ///
  /// If cancellation already happened, the handler is invoked immediately so
  /// setup cannot race ahead with an already-cancelled trace.
  ///
  /// - Returns: A monotonically increasing registration ID identifying this handler.
  @discardableResult
  internal func installCancellationHandler(_ handler: @escaping @Sendable () -> Void) -> UInt64 {
    handlerRegistrationID &+= 1
    let id = handlerRegistrationID
    if _isCancelled {
      handler()
    } else {
      cancellationHandler = handler
    }
    return id
  }

  /// Removes an operation-specific cleanup handler after the operation ends.
  ///
  /// If `id` is provided, the handler is only cleared if it matches the specified
  /// registration ID. This prevents an asynchronous or delayed cleanup from clearing
  /// a subsequent phase's newly installed cancellation handler.
  internal func clearCancellationHandler(id: UInt64? = nil) {
    if let id {
      guard id == handlerRegistrationID else { return }
    }
    cancellationHandler = nil
  }

  /// Whether an in-flight receive operation is currently attached.
  internal var hasCancellationHandler: Bool {
    cancellationHandler != nil
  }

  init() {}
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
