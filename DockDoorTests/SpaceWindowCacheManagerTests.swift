import ApplicationServices
import Cocoa
@testable import DockDoor
import Testing

struct SpaceWindowCacheManagerTests {
    private let pid: pid_t = 123456

    private func window(_ id: CGWindowID) -> WindowInfo {
        // An invalid PID avoids querying any real window or requiring TCC.
        let ax = AXUIElementCreateApplication(Int32.max)
        let provider = MockPreviewWindow(
            windowID: id, frame: .zero, title: "test",
            owningApplicationBundleIdentifier: nil,
            owningApplicationProcessID: nil, isOnScreen: false, windowLayer: 0
        )
        return WindowInfo(
            windowProvider: provider, app: .current, image: nil,
            axElement: ax, appAxElement: ax, closeButton: nil,
            lastAccessedTime: .distantPast, isMinimized: false, isHidden: false
        )
    }

    private func race(
        _ cache: SpaceWindowCacheManager,
        transform: @escaping (inout Set<WindowInfo>) -> Void,
        concurrent: @escaping () -> Void
    ) {
        let started = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let concurrentFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var firstAttempt = true
            cache.updateCache(pid: pid) { windows in
                if firstAttempt {
                    firstAttempt = false
                    started.signal()
                    _ = resume.wait(timeout: .now() + 5)
                }
                transform(&windows)
            }
            finished.signal()
        }
        #expect(started.wait(timeout: .now() + 2) == .success)
        DispatchQueue.global().async {
            concurrent()
            concurrentFinished.signal()
        }
        let accessibleWhileAXWorkWaits = concurrentFinished.wait(timeout: .now() + 1)
        resume.signal()
        #expect(accessibleWhileAXWorkWaits == .success)
        #expect(finished.wait(timeout: .now() + 2) == .success)
    }

    @Test func readersDoNotWaitForAnAXTransform() {
        let cache = SpaceWindowCacheManager()
        let existing = window(1)
        cache.writeCache(pid: pid, windowSet: [existing])
        race(cache, transform: { _ in }, concurrent: {
            #expect(cache.readCache(pid: pid).count == 1)
            #expect(cache.getAllWindows().count == 1)
        })
    }

    @Test func concurrentInsertionsAreNotLost() {
        let cache = SpaceWindowCacheManager()
        let first = window(1), second = window(2), third = window(3)
        cache.writeCache(pid: pid, windowSet: [first])
        race(cache, transform: { $0.insert(third) }, concurrent: {
            cache.updateCache(pid: pid) { $0.insert(second) }
        })
        #expect(Set(cache.readCache(pid: pid).map(\.id)) == [1, 2, 3])
    }

    @Test func metadataOnlyWritesAlsoInvalidateSnapshots() throws {
        let cache = SpaceWindowCacheManager()
        let first = window(1)
        cache.writeCache(pid: pid, windowSet: [first])
        race(cache, transform: { windows in
            windows = Set(windows.map { window in
                var updated = window
                updated.isMinimized = true
                return updated
            })
        }, concurrent: {
            var hidden = first
            hidden.isHidden = true
            // WindowInfo equality ignores metadata; a Set equality check
            // cannot replace the revision check in the cache transaction.
            #expect(hidden == first)
            cache.writeCache(pid: pid, windowSet: [hidden])
        })
        let final = try #require(cache.readCache(pid: pid).first)
        #expect(final.isHidden)
        #expect(final.isMinimized)
    }

    @Test func concurrentRemovalCannotResurrectAWindow() {
        let cache = SpaceWindowCacheManager()
        cache.writeCache(pid: pid, windowSet: [window(1)])
        race(cache, transform: { windows in
            windows = Set(windows.map { window in
                var updated = window
                updated.isHidden = true
                return updated
            })
        }, concurrent: {
            cache.removeFromCache(pid: pid, windowId: 1)
        })
        #expect(cache.readCache(pid: pid).isEmpty)
    }
}
