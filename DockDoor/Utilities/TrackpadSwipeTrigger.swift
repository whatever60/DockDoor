import AppKit
import Defaults

struct SwipeTouch {
    let id: Int
    let position: CGPoint
}

enum TrackpadSwipeEvent: Equatable {
    case open
    case openBackward
    case quickForward
    case quickBackward
    case cycleForward
    case cycleBackward
    case release
    case cancel
}

struct TrackpadSwipePresentation {
    private var pending: (backward: Bool, start: TimeInterval)?
    private var opened = false
    static let holdTime: TimeInterval = 0.18

    mutating func receive(_ event: TrackpadSwipeEvent?, backward: Bool, now: TimeInterval) -> [TrackpadSwipeEvent] {
        switch event {
        case .open:
            pending = (backward, now)
            return []
        case .release:
            defer { self = Self() }
            if opened { return [.release] }
            if let pending { return [pending.backward ? .quickBackward : .quickForward] }
            return []
        case .cancel:
            defer { self = Self() }
            return opened ? [.cancel] : []
        case .cycleForward, .cycleBackward, nil:
            if let pending, now - pending.start >= Self.holdTime {
                self.pending = nil
                opened = true
                return [pending.backward ? .openBackward : .open]
            }
            return (opened ? event.map { [$0] } : nil) ?? []
        default:
            return []
        }
    }
}

struct TrackpadSwipeDetector {
    static let openDistance: CGFloat = 0.03
    static let firstCycleDistance: CGFloat = 0.15
    static let cycleDistance: CGFloat = 0.04
    static let maxOffAxisDistance: CGFloat = 0.1
    static let axisDominanceRatio: CGFloat = 1.5

    private var startPositions: [Int: CGPoint] = [:]
    private var isSpent = false
    private var hasCycled = false
    private(set) var isSwitching = false
    private(set) var initialBackward = false

    mutating func handle(_ touches: [SwipeTouch], fingers: Int, horizontal: Bool) -> TrackpadSwipeEvent? {
        if isSwitching {
            if touches.count > fingers {
                isSwitching = false
                isSpent = true
                startPositions.removeAll()
                return .cancel
            }
            if touches.count < fingers {
                isSwitching = false
                isSpent = touches.count > 1
                startPositions.removeAll()
                return .release
            }
            guard let deltas = travel(touches) else { return nil }
            let averageAlong = deltas.map { horizontal ? $0.x : $0.y }.reduce(0, +) / CGFloat(deltas.count)
            let threshold = hasCycled ? Self.cycleDistance : Self.firstCycleDistance
            guard abs(averageAlong) >= threshold else { return nil }
            hasCycled = true
            rebase(touches)
            return averageAlong > 0 ? .cycleForward : .cycleBackward
        }

        if touches.count <= 1 {
            isSpent = false
            startPositions.removeAll()
            return nil
        }
        if isSpent {
            return nil
        }
        if touches.count > fingers {
            isSpent = true
            return nil
        }
        guard touches.count == fingers else {
            startPositions.removeAll()
            return nil
        }
        guard let deltas = travel(touches) else { return nil }

        let alongAxis = deltas.map { horizontal ? $0.x : $0.y }
        let acrossAxis = deltas.map { horizontal ? abs($0.y) : abs($0.x) }
        if acrossAxis.contains(where: { $0 >= Self.maxOffAxisDistance }) {
            isSpent = true
            return nil
        }
        let allPositive = alongAxis.allSatisfy { $0 >= Self.openDistance }
        let allNegative = alongAxis.allSatisfy { $0 <= -Self.openDistance }
        guard allPositive || allNegative else { return nil }
        guard zip(alongAxis.map(abs), acrossAxis).allSatisfy({ $0 > $1 * Self.axisDominanceRatio }) else { return nil }

        isSwitching = true
        initialBackward = allNegative
        hasCycled = false
        rebase(touches)
        return .open
    }

    private mutating func travel(_ touches: [SwipeTouch]) -> [CGPoint]? {
        let deltas = touches.compactMap { touch -> CGPoint? in
            guard let start = startPositions[touch.id] else { return nil }
            return CGPoint(x: touch.position.x - start.x, y: touch.position.y - start.y)
        }
        guard !deltas.isEmpty, deltas.count == touches.count else {
            rebase(touches)
            return nil
        }
        return deltas
    }

    private mutating func rebase(_ touches: [SwipeTouch]) {
        startPositions = Dictionary(touches.map { ($0.id, $0.position) }, uniquingKeysWith: { first, _ in first })
    }
}

final class TrackpadSwipeTrigger {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var unmanagedSelf: Unmanaged<TrackpadSwipeTrigger>?
    private var detector = TrackpadSwipeDetector()
    private var presentation = TrackpadSwipePresentation()
    private var expiry: DispatchWorkItem?
    private var holdWake: DispatchWorkItem?
    private var lastFrame: TimeInterval?
    private let onSwipe: @MainActor (TrackpadSwipeEvent) -> Void

    init(onSwipe: @escaping @MainActor (TrackpadSwipeEvent) -> Void) {
        self.onSwipe = onSwipe
        setupEventTap()
    }

    func reset() {
        expireSession()
        removeEventTap()
        setupEventTap()
    }

    deinit { expiry?.cancel(); holdWake?.cancel() }

    private static let eventCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let trigger = Unmanaged<TrackpadSwipeTrigger>.fromOpaque(refcon).takeUnretainedValue()
        if let passthrough = reEnableIfNeeded(tap: trigger.eventTap, type: type, event: event) {
            return passthrough
        }
        if type.rawValue == NSEvent.EventType.gesture.rawValue {
            trigger.handle(event)
        }
        return Unmanaged.passUnretained(event)
    }

    private func setupEventTap() {
        guard eventTap == nil else { return }
        let retainedSelf = Unmanaged.passRetained(self)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: NSEvent.EventTypeMask.gesture.rawValue,
            callback: TrackpadSwipeTrigger.eventCallback,
            userInfo: retainedSelf.toOpaque()
        ) else {
            retainedSelf.release()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.setupEventTap()
            }
            return
        }

        unmanagedSelf = retainedSelf
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    private func removeEventTap() {
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CFMachPortInvalidate(eventTap)
        unmanagedSelf?.release()
        unmanagedSelf = nil
        self.eventTap = nil
        runLoopSource = nil
    }

    private func handle(_ cgEvent: CGEvent) {
        guard let nsEvent = NSEvent(cgEvent: cgEvent) else { return }
        let touches = nsEvent.allTouches().filter { $0.type == .indirect }
        guard !touches.isEmpty else { return }

        let down = touches.filter { NSTouch.Phase.touching.contains($0.phase) && !$0.isResting }
        let swipeTouches = down.count > 1
            ? down.map { SwipeTouch(id: $0.identity.hash, position: $0.normalizedPosition) }
            : []

        let fingers = min(max(Defaults[.trackpadSwitcherSwipeFingers], 3), 4)
        let horizontal = Defaults[.trackpadSwitcherSwipeDirection] == .horizontal
        let now = ProcessInfo.processInfo.systemUptime
        if let lastFrame, now - lastFrame > 0.24 { expireSession() }
        let event = detector.handle(swipeTouches, fingers: fingers, horizontal: horizontal)
        lastFrame = now
        publish(presentation.receive(event, backward: detector.initialBackward, now: now))
        if event == .open {
            holdWake?.cancel()
            let wake = DispatchWorkItem { [weak self] in self?.checkHold() }
            holdWake = wake
            DispatchQueue.main.asyncAfter(deadline: .now() + TrackpadSwipePresentation.holdTime + 0.005, execute: wake)
        }

        if detector.isSwitching {
            if expiry == nil {
                let check = DispatchWorkItem { [weak self] in self?.checkExpiry() }
                expiry = check
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: check)
            }
        } else {
            expiry?.cancel()
            expiry = nil
            holdWake?.cancel()
            holdWake = nil
        }
    }

    private func checkHold() {
        holdWake = nil
        let now = ProcessInfo.processInfo.systemUptime
        guard let lastFrame, detector.isSwitching, now - lastFrame < 0.14 else { return }
        publish(presentation.receive(nil, backward: detector.initialBackward, now: now))
    }

    private func checkExpiry() {
        expiry = nil
        guard let lastFrame, detector.isSwitching else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - lastFrame
        if elapsed >= 0.24 {
            expireSession()
        } else {
            let check = DispatchWorkItem { [weak self] in self?.checkExpiry() }
            expiry = check
            DispatchQueue.main.asyncAfter(deadline: .now() + (0.25 - elapsed), execute: check)
        }
    }

    private func expireSession() {
        expiry?.cancel()
        expiry = nil
        holdWake?.cancel()
        holdWake = nil
        lastFrame = nil
        detector = TrackpadSwipeDetector()
        publish(presentation.receive(.cancel, backward: false, now: ProcessInfo.processInfo.systemUptime))
    }

    private func publish(_ events: [TrackpadSwipeEvent]) {
        guard !events.isEmpty else { return }
        let onSwipe = onSwipe
        Task { @MainActor in
            for event in events { onSwipe(event) }
        }
    }
}
