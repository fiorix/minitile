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

@Test func failedObserversAreNotRecordedAsSuccessful() {
    for error: AXError in [.invalidUIElement, .invalidUIElementObserver, .cannotComplete, .failure] {
        var registrations = ObserverRegistrations()
        let complete = registrations.register([kAXWindowCreatedNotification]) { _ in error }
        #expect(!complete)
        #expect(registrations.names.isEmpty)
    }
}

@Test func unsupportedNotificationsSettleWithoutRetry() {
    let required = [kAXWindowCreatedNotification, kAXApplicationActivatedNotification]
    var registrations = ObserverRegistrations()
    let first = registrations.register(required) { name in
        name == kAXApplicationActivatedNotification ? .notificationUnsupported : .success
    }
    #expect(first)
    #expect(registrations.names == [kAXWindowCreatedNotification])
    #expect(registrations.unsupported == [kAXApplicationActivatedNotification])
    let again = registrations.register(required) { _ in
        Issue.record("Settled registrations must not be repeated")
        return .failure
    }
    #expect(again)
}
