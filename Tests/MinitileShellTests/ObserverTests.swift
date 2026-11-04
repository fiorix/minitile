import ApplicationServices
import Testing
@testable import minitile

@Test func observerRegistrationRetriesFailuresWithoutDuplicatingSuccesses() {
    let required = [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXApplicationActivatedNotification]
    var registrations = ObserverRegistrations()
    var attempted: [String] = []
    let first = registrations.register(required) { name in
        attempted.append(name)
        return name == kAXFocusedWindowChangedNotification ? .cannotComplete : .success
    }
    #expect(!first)
    #expect(attempted == required)
    attempted = []
    let retry = registrations.register(required) { name in
        attempted.append(name)
        return .notificationAlreadyRegistered
    }
    #expect(retry)
    #expect(attempted == [kAXFocusedWindowChangedNotification])
    let complete = registrations.register(required) { _ in
        Issue.record("Successful registrations must not be repeated")
        return .failure
    }
    #expect(complete)
}

@Test func unsupportedAndInvalidObserversAreNotRecordedAsSuccessful() {
    for error: AXError in [.notificationUnsupported, .invalidUIElement, .invalidUIElementObserver, .cannotComplete] {
        var registrations = ObserverRegistrations()
        let complete = registrations.register([kAXWindowCreatedNotification]) { _ in error }
        #expect(!complete)
        #expect(registrations.names.isEmpty)
    }
}
