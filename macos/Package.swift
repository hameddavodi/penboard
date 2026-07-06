// swift-tools-version: 6.2
import Foundation
import PackageDescription

// Xcode Command Line Tools (no Xcode.app) ship `Testing.framework` (Swift Testing)
// under the CLT's own Developer dir, but it isn't on the default framework/library
// search paths `swift test` uses — and CLT-only installs have no `XCTest.framework`
// at all, so Swift Testing is the only test runner available here. When Xcode.app is
// installed instead, `xcode-select -p` points elsewhere and these extra paths simply
// won't exist, so they're added only when found (harmless no-op under full Xcode).
func developerDir() -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    process.arguments = ["-p"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return "/Library/Developer/CommandLineTools"
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (path?.isEmpty == false ? path! : nil) ?? "/Library/Developer/CommandLineTools"
}

let cltTestingFrameworksDir = developerDir() + "/Library/Developer/Frameworks"
let cltTestingLibDir = developerDir() + "/Library/Developer/usr/lib"
let fileManager = FileManager.default

var testSwiftSettings: [SwiftSetting] = []
var testLinkerSettings: [LinkerSetting] = []

if fileManager.fileExists(atPath: cltTestingFrameworksDir) {
    testSwiftSettings.append(.unsafeFlags(["-F", cltTestingFrameworksDir]))
    testLinkerSettings.append(
        .unsafeFlags([
            "-F", cltTestingFrameworksDir,
            "-Xlinker", "-rpath", "-Xlinker", cltTestingFrameworksDir,
        ])
    )
}
if fileManager.fileExists(atPath: cltTestingLibDir) {
    testLinkerSettings.append(
        .unsafeFlags([
            "-L", cltTestingLibDir,
            "-Xlinker", "-rpath", "-Xlinker", cltTestingLibDir,
        ])
    )
}

let package = Package(
    name: "PenBoard",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "PenBoard",
            path: "Sources/PenBoard"
        ),
        .testTarget(
            name: "PenBoardTests",
            dependencies: ["PenBoard"],
            path: "Tests/PenBoardTests",
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        ),
    ]
)
