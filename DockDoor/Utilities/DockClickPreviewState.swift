import CoreGraphics
import Foundation

struct DockClickPreviewState {
    enum Intent: Equatable {
        case dismiss, pinDisplayedHover, showNew
    }

    private(set) var revision = UUID()
    private(set) var sessionID: UUID?
    private(set) var bundleIdentifier: String?
    private(set) var dockItemFrame: CGRect?

    var isPersistent: Bool { sessionID != nil }

    func intent(for bundleIdentifier: String, displayedHoverBundleIdentifier: String?) -> Intent {
        if self.bundleIdentifier == bundleIdentifier { return .dismiss }
        if !isPersistent, displayedHoverBundleIdentifier == bundleIdentifier { return .pinDisplayedHover }
        return .showNew
    }

    mutating func begin(bundleIdentifier: String, dockItemFrame: CGRect?) -> UUID? {
        if self.bundleIdentifier == bundleIdentifier {
            dismiss()
            return nil
        }
        revision = UUID()
        sessionID = revision
        self.bundleIdentifier = bundleIdentifier
        self.dockItemFrame = dockItemFrame
        return sessionID
    }

    mutating func dismiss() {
        revision = UUID()
        sessionID = nil
        bundleIdentifier = nil
        dockItemFrame = nil
    }

    func matches(_ sessionID: UUID) -> Bool {
        self.sessionID == sessionID
    }

    func acceptsDisplay(sessionID: UUID?, revision: UUID) -> Bool {
        self.revision == revision && self.sessionID == sessionID
    }

    func shouldDismiss(forMouseDownAt point: CGPoint, previewFrame: CGRect?, allowOwnerIcon: Bool = true) -> Bool {
        guard isPersistent else { return false }
        if let previewFrame, previewFrame.contains(point) { return false }
        if allowOwnerIcon, let dockItemFrame, dockItemFrame.contains(point) { return false }
        return true
    }

    static func cocoaPoint(fromQuartz point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    static func cocoaFrame(fromQuartz frame: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryScreenHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}

struct DockThumbnailPeekState {
    private(set) var owner: UUID?

    mutating func begin(_ request: UUID) {
        owner = request
    }

    func accepts(_ request: UUID) -> Bool {
        owner == request
    }

    @discardableResult
    mutating func end(_ request: UUID? = nil) -> Bool {
        if let request, request != owner { return false }
        owner = nil
        return true
    }
}
