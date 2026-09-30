@testable import DockDoor
import Foundation
import Testing

struct DockClickPreviewStateTests {
    private let icon = CGRect(x: 400, y: 0, width: 60, height: 60)
    private let preview = CGRect(x: 200, y: 70, width: 500, height: 220)

    private func start(_ state: inout DockClickPreviewState, bundle: String = "browser", frame: CGRect? = nil) throws -> UUID {
        let token = state.begin(bundleIdentifier: bundle, dockItemFrame: frame ?? icon)
        return try #require(token)
    }

    @Test func hoverHasNoPersistentSession() {
        let state = DockClickPreviewState()
        #expect(!state.isPersistent)
        #expect(state.acceptsDisplay(sessionID: nil, revision: state.revision))
        #expect(!state.shouldDismiss(forMouseDownAt: .zero, previewFrame: nil))
    }

    @Test func clickPinsAndBlocksHoverDisplays() throws {
        var state = DockClickPreviewState()
        let hoverRevision = state.revision
        let session = try start(&state)
        #expect(state.isPersistent)
        #expect(state.matches(session))
        #expect(state.acceptsDisplay(sessionID: session, revision: state.revision))
        #expect(!state.acceptsDisplay(sessionID: nil, revision: state.revision))
        #expect(!state.acceptsDisplay(sessionID: nil, revision: hoverRevision))
    }

    @Test func repeatedClickTogglesOffIncludingPendingFetch() throws {
        var state = DockClickPreviewState()
        let session = try start(&state)
        let revision = state.revision
        let toggled = state.begin(bundleIdentifier: "browser", dockItemFrame: icon)
        #expect(toggled == nil)
        #expect(!state.isPersistent)
        #expect(state.bundleIdentifier == nil)
        #expect(state.dockItemFrame == nil)
        #expect(!state.matches(session))
        #expect(!state.acceptsDisplay(sessionID: session, revision: revision))
    }

    @Test func clickingAnotherGroupInvalidatesOldAsyncResult() throws {
        var state = DockClickPreviewState()
        let old = try start(&state)
        let revision = state.revision
        let next = try start(&state, bundle: "editor", frame: icon.offsetBy(dx: 70, dy: 0))
        #expect(state.bundleIdentifier == "editor")
        #expect(!state.matches(old))
        #expect(state.matches(next))
        #expect(!state.acceptsDisplay(sessionID: old, revision: revision))
    }

    @Test func queuedOutsideDismissalCannotDismissNewSession() throws {
        var state = DockClickPreviewState()
        let old = try start(&state)
        #expect(state.shouldDismiss(forMouseDownAt: .zero, previewFrame: preview))
        _ = state.begin(bundleIdentifier: "editor", dockItemFrame: nil)
        #expect(!state.matches(old))
    }

    @Test func outsideClicksDismissButOwnerAndThumbnailsDoNot() {
        var state = DockClickPreviewState()
        _ = state.begin(bundleIdentifier: "browser", dockItemFrame: icon)
        #expect(!state.shouldDismiss(forMouseDownAt: CGPoint(x: 420, y: 20), previewFrame: preview))
        #expect(!state.shouldDismiss(forMouseDownAt: CGPoint(x: 230, y: 140), previewFrame: preview))
        #expect(state.shouldDismiss(forMouseDownAt: CGPoint(x: 490, y: 20), previewFrame: preview))
        #expect(state.shouldDismiss(forMouseDownAt: CGPoint(x: 100, y: 500), previewFrame: preview))
    }

    @Test func dismissInvalidatesPreviouslyQueuedHoverAfterPinEnds() {
        var state = DockClickPreviewState()
        let oldHoverRevision = state.revision
        _ = state.begin(bundleIdentifier: "browser", dockItemFrame: icon)
        state.dismiss()
        #expect(!state.acceptsDisplay(sessionID: nil, revision: oldHoverRevision))
        #expect(state.acceptsDisplay(sessionID: nil, revision: state.revision))
    }

    @Test func rightClickOnOwnerDismissesForNativeDockMenu() {
        var state = DockClickPreviewState()
        _ = state.begin(bundleIdentifier: "browser", dockItemFrame: icon)
        #expect(state.shouldDismiss(forMouseDownAt: CGPoint(x: 420, y: 20), previewFrame: preview, allowOwnerIcon: false))
        #expect(!state.shouldDismiss(forMouseDownAt: CGPoint(x: 230, y: 140), previewFrame: preview, allowOwnerIcon: false))
    }

    @Test func pendingPreviewWithoutFrameStillClosesOnOutsideClick() {
        var state = DockClickPreviewState()
        _ = state.begin(bundleIdentifier: "browser", dockItemFrame: nil)
        #expect(state.shouldDismiss(forMouseDownAt: .zero, previewFrame: nil))
    }

    @Test func convertsPrimaryAndOffsetMonitorFrames() {
        #expect(DockClickPreviewState.cocoaFrame(fromQuartz: CGRect(x: 400, y: 940, width: 60, height: 60), primaryScreenHeight: 1000) == icon)
        let upperMonitorIcon = CGRect(x: -1200, y: -60, width: 60, height: 60)
        #expect(DockClickPreviewState.cocoaFrame(fromQuartz: upperMonitorIcon, primaryScreenHeight: 1000) == CGRect(x: -1200, y: 1000, width: 60, height: 60))
        #expect(DockClickPreviewState.cocoaPoint(fromQuartz: CGPoint(x: 420, y: 980), primaryScreenHeight: 1000) == CGPoint(x: 420, y: 20))
    }
}
