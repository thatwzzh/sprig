import XCTest
@testable import SprigCore

final class StoragePathsTests: XCTestCase {
    private let home = "/Users/someone"

    func testProtectedFolders() {
        for folder in ["Documents", "Desktop", "Downloads", "Pictures", "Music", "Movies"] {
            XCTAssertTrue(StoragePaths.isProtected(URL(fileURLWithPath: "\(home)/\(folder)/x"),
                                                   home: home), folder)
        }
    }

    func testApplicationSupportIsFree() {
        XCTAssertFalse(StoragePaths.isProtected(
            URL(fileURLWithPath: "\(home)/Library/Application Support/Sprig/repository"), home: home))
        XCTAssertFalse(StoragePaths.isProtected(URL(fileURLWithPath: "\(home)/code/Sprig"), home: home))
    }

    /// 名字里带 Documents 但不在家目录顶层，不该误报
    func testLookalikeIsNotProtected() {
        XCTAssertFalse(StoragePaths.isProtected(URL(fileURLWithPath: "\(home)/code/Documents"), home: home))
    }

    func testICloudDriveIsProtected() {
        XCTAssertTrue(StoragePaths.isProtected(
            URL(fileURLWithPath: "\(home)/Library/Mobile Documents/com~apple~CloudDocs/notes"), home: home))
    }
}
