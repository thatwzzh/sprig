import XCTest
@testable import SprigCore

final class AcpHostLocateTests: XCTestCase {
    func testPicksFirstExecutable() {
        let candidates = ["/no/such/file", "/bin/sh", "/usr/bin/true"]
        XCTAssertEqual(AcpHostClient.firstExecutable(candidates), "/bin/sh")
    }

    func testReturnsNilWhenNoneExecutable() {
        XCTAssertNil(AcpHostClient.firstExecutable(["/no/such/file", "/also/missing"]))
    }

    /// 配置了不存在的路径时不应该把它当成可用路径
    func testConfiguredPathMustExist() {
        let bogus = "/tmp/definitely-not-acp-host-\(UUID().uuidString)"
        XCTAssertNotEqual(AcpHostClient.locateBinary(configured: bogus), bogus)
    }
}
