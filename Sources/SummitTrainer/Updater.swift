import Foundation
import AppKit

/// Checks GitHub Releases for a newer SummitRoad.zip and can replace the running app with it.
@MainActor
final class Updater: ObservableObject {
    static let repo = "trommy76/SUMMITRoad"
    static let assetName = "SummitRoad.zip"

    struct Available {
        let version: String
        let downloadURL: URL
        let pageURL: URL
    }

    @Published var available: Available?
    @Published var status = ""
    @Published var busy = false

    private struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        let tag_name: String
        let html_url: String
        let assets: [Asset]
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// True when `a` is a newer dotted version than `b` (e.g. 1.0.10 > 1.0.9).
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    func check(silent: Bool = false) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        if !silent { status = "Checking for updates…" }
        do {
            var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Updater.repo)/releases/latest")!)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 15
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { if !silent { status = "No releases published yet." }; return }
            guard (200..<300).contains(code) else { if !silent { status = "Update check failed (HTTP \(code))." }; return }
            let rel = try JSONDecoder().decode(Release.self, from: data)
            let version = rel.tag_name.hasPrefix("v") ? String(rel.tag_name.dropFirst()) : rel.tag_name
            guard Updater.isNewer(version, than: Updater.currentVersion) else {
                available = nil
                if !silent { status = "You're up to date (v\(Updater.currentVersion))." }
                return
            }
            guard let asset = rel.assets.first(where: { $0.name == Updater.assetName }),
                  let url = URL(string: asset.browser_download_url), let page = URL(string: rel.html_url) else {
                if !silent { status = "Version \(version) exists but has no \(Updater.assetName) attached." }
                return
            }
            available = Available(version: version, downloadURL: url, pageURL: page)
            status = "Version \(version) is available."
        } catch {
            if !silent { status = "Update check failed: \(error.localizedDescription)" }
        }
    }

    /// Downloads the release, then hands off to a small script that swaps the app bundle after we quit.
    func install() async {
        guard let a = available, !busy else { return }
        let dest = Bundle.main.bundleURL
        if dest.path.contains("AppTranslocation") || dest.pathExtension != "app" {
            status = "Move SummitRoad.app into Applications and reopen it, then update."
            return
        }
        guard FileManager.default.isWritableFile(atPath: dest.deletingLastPathComponent().path) else {
            status = "Can't write to \(dest.deletingLastPathComponent().path). Download manually from the release page."
            return
        }
        busy = true
        defer { busy = false }
        do {
            status = "Downloading v\(a.version)…"
            let (tmpZip, resp) = try await URLSession.shared.download(from: a.downloadURL)
            guard (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
                status = "Download failed."
                return
            }
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("summitroad-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let zip = work.appendingPathComponent("update.zip")
            try FileManager.default.moveItem(at: tmpZip, to: zip)
            let out = work.appendingPathComponent("out")
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

            status = "Unpacking…"
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", zip.path, out.path]
            try unzip.run()
            unzip.waitUntilExit()
            guard unzip.terminationStatus == 0,
                  let newApp = try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
                    .first(where: { $0.pathExtension == "app" }) else {
                status = "The downloaded update was not a valid app."
                return
            }

            let script = work.appendingPathComponent("swap.sh")
            let body = """
            #!/bin/bash
            while kill -0 "$1" 2>/dev/null; do sleep 0.3; done
            rm -rf "$3"
            /usr/bin/ditto "$2" "$3"
            /usr/bin/xattr -dr com.apple.quarantine "$3"
            /usr/bin/open "$3"
            rm -rf "$4"
            """
            try body.write(to: script, atomically: true, encoding: .utf8)
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/bin/bash")
            helper.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), newApp.path, dest.path, work.path]
            helper.standardOutput = FileHandle.nullDevice
            helper.standardError = FileHandle.nullDevice
            try helper.run()
            status = "Installing v\(a.version) and restarting…"
            NSApplication.shared.terminate(nil)
        } catch {
            status = "Update failed: \(error.localizedDescription)"
        }
    }
}
