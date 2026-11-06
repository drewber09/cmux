import Foundation
import Testing

/// DIAGNOSTIC ONLY (fix/freed-pointer-diag-nomerge, never merged). Run after a suite that aborted with
/// "freed pointer was not the last allocation": prints this host's OS and Swift runtime, and the
/// crashed thread of the newest test-helper crash report (.ips) in DiagnosticReports.
@Suite(.serialized)
struct FreedPointerDiagTests {
    static func say(_ text: String) { print("FREED-POINTER-DIAG: \(text)") }

    static func run(_ path: String, _ arguments: [String]) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
            do { try process.run() } catch { continuation.resume(returning: "cannot run \(path): \(error)") }
        }
    }

    static func reports(newerThan cutoff: Date) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folders = [home.appending(path: "Library/Logs/DiagnosticReports"), URL(fileURLWithPath: "/Library/Logs/DiagnosticReports")]
        var found: [(URL, Date)] = []
        for folder in folders {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names where name.hasSuffix(".ips")
                && (name.contains("swiftpm-testing-helper") || name.contains("CmuxNextPackageTests") || name.contains("xctest")) {
                let url = folder.appending(path: name)
                let date = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? .distantPast
                if date > cutoff { found.append((url, date)) }
            }
        }
        return found.sorted { $0.1 > $1.1 }.map(\.0)
    }

    static func describe(_ url: URL) {
        say("report \(url.path)")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return say("unreadable") }
        let parts = text.split(separator: "\n", maxSplits: 1).map(String.init)
        if let first = parts.first { say("header \(first)") }
        guard parts.count == 2, let body = try? JSONSerialization.jsonObject(with: Data(parts[1].utf8)) as? [String: Any] else {
            return say("body not JSON; first 4000 chars:\n\(text.prefix(4000))")
        }
        for key in ["osVersion", "asi", "exception", "termination", "faultingThread", "captureTime", "modelCode", "cpuType", "procPath"] {
            if let value = body[key] { say("\(key) = \(value)") }
        }
        let images = body["usedImages"] as? [[String: Any]] ?? []
        for image in images {
            let name = image["name"] as? String ?? image["path"] as? String ?? "?"
            if name.contains("swift_Concurrency") || name.contains("libswiftCore") || name.contains("Testing") || name.contains("libswift_Builtin") {
                say("image \(name) path=\(image["path"] ?? "?") uuid=\(image["uuid"] ?? "?") base=\(image["base"] ?? "?")")
            }
        }
        let threads = body["threads"] as? [[String: Any]] ?? []
        let faulting = body["faultingThread"] as? Int ?? -1
        for (index, thread) in threads.enumerated() where index == faulting || (thread["triggered"] as? Bool) == true {
            say("crashed thread \(index) queue=\(thread["queue"] ?? "-") name=\(thread["name"] ?? "-")")
            for (number, frame) in ((thread["frames"] as? [[String: Any]]) ?? []).prefix(80).enumerated() {
                let imageIndex = frame["imageIndex"] as? Int ?? -1
                let image = imageIndex >= 0 && imageIndex < images.count ? (images[imageIndex]["name"] as? String ?? "?") : "?"
                say("  #\(number) \(image) +\(frame["imageOffset"] ?? "?") \(frame["symbol"] ?? "?") + \(frame["symbolLocation"] ?? "?")")
            }
        }
    }

    @Test func hostAndNewestTestHelperCrashReport() async throws {
        Self.say("os \(ProcessInfo.processInfo.operatingSystemVersionString) host \(ProcessInfo.processInfo.hostName)")
        Self.say("sw_vers:\n" + (await Self.run("/usr/bin/sw_vers", [])))
        Self.say("swift --version:\n" + (await Self.run("/usr/bin/xcrun", ["swift", "--version"])))
        Self.say("xcode-select -p: " + (await Self.run("/usr/bin/xcode-select", ["-p"])))
        Self.say("DEVELOPER_DIR=\(ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? "-")")
        if let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "swift_task_alloc") {
            var info = Dl_info()
            if dladdr(symbol, &info) != 0, let name = info.dli_fname { Self.say("swift_task_alloc from \(String(cString: name))") }
        }
        let cutoff = Date().addingTimeInterval(-20 * 60)
        var found = Self.reports(newerThan: cutoff)
        var waited = 0
        while found.isEmpty, waited < 90 {
            try await Task.sleep(for: .seconds(5))
            waited += 5
            found = Self.reports(newerThan: cutoff)
        }
        Self.say("\(found.count) test-helper crash reports in the last 20 minutes (waited \(waited) s)")
        for url in found.prefix(3) { Self.describe(url) }
    }
}
