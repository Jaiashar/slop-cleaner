import Foundation

/// Runs a command with an explicit executable path (never through a shell) and a timeout.
enum Shell {
    struct Result { let status: Int32; let output: String }

    static func run(_ executable: String, _ args: [String], timeout: TimeInterval = 20) -> Result? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }

        // Read while it runs so a full pipe can't stall the child.
        var data = Data()
        let reader = DispatchQueue(label: "watcher.shell.read")
        let done = DispatchSemaphore(value: 0)
        reader.async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
        _ = done.wait(timeout: .now() + 2)
        return Result(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    static var adbPath: String? {
        let env = ProcessInfo.processInfo.environment
        let candidates = [env["ANDROID_HOME"], env["ANDROID_SDK_ROOT"], NSHomeDirectory() + "/Library/Android/sdk"]
            .compactMap { $0 }
            .map { $0 + "/platform-tools/adb" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
