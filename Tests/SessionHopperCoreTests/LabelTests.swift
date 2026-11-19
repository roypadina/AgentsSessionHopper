import XCTest
@testable import SessionHopperCore

final class LabelTests: XCTestCase {
    func testOldConfigDecodesWithoutLabelAndLabelRoundTrips() throws {
        let old = #"{"profiles":[{"name":"claude5","dir":"/x","exportConfigDir":true}]}"#
        var c = try JSONDecoder().decode(HopperConfig.self, from: Data(old.utf8))
        XCTAssertNil(c.profiles[0].label)
        XCTAssertEqual(c.display("claude5"), "claude5")
        c.profiles[0].label = "Work"
        let back = try JSONDecoder().decode(HopperConfig.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back.display("claude5"), "Work")
        XCTAssertEqual(back.profiles[0].name, "claude5")
        XCTAssertEqual(back.display("gone"), "gone")
    }

    func testLabelClashesWithAnotherProfilesNameOrLabel() throws {
        let json = #"{"profiles":[{"name":"a","dir":"/a","exportConfigDir":true,"label":"Work"},{"name":"b","dir":"/b","exportConfigDir":true}]}"#
        let c = try JSONDecoder().decode(HopperConfig.self, from: Data(json.utf8))
        XCTAssertTrue(c.labelClashes("B", for: "a"))
        XCTAssertTrue(c.labelClashes("work", for: "b"))
        XCTAssertFalse(c.labelClashes("Work", for: "a"))
        XCTAssertFalse(c.labelClashes("Home", for: "b"))
        XCTAssertFalse(c.labelClashes("", for: "b"))
    }
}
