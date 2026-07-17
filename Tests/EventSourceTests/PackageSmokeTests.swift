import Testing
@testable import EventSource

@Test func packageBuildsAndModuleIsImportable() {
    let state: ReadyState = .closed
    #expect(state == .closed)
}
