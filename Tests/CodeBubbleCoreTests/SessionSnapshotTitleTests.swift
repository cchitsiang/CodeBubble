import XCTest
@testable import CodeBubbleCore

final class SessionSnapshotTitleTests: XCTestCase {
    func testProjectDisplayNameUsesFolderName() {
        var snapshot = SessionSnapshot()
        snapshot.cwd = "/Users/wangnov/CodeBubble"

        XCTAssertEqual(snapshot.projectDisplayName, "CodeBubble")
    }

    func testProjectDisplayNameIsNilWithNoCwd() {
        let snapshot = SessionSnapshot()
        XCTAssertNil(snapshot.projectDisplayName)
    }

    func testDefaultSource() {
        let snapshot = SessionSnapshot()
        XCTAssertEqual(snapshot.source, "claude")
    }

    func testDefaultStatus() {
        let snapshot = SessionSnapshot()
        XCTAssertEqual(snapshot.status, .idle)
    }
}
