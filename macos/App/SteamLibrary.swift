// Discovery of the local Steam install and the games in it (macOS).
import AppKit
import Foundation

struct SteamGame: Equatable {
    var appId: UInt32
    var name: String
    var installed: Bool
}

enum SteamLibrary {
    // Tool/runtime AppIDs that are never worth idling.
    static let excluded: Set<UInt32> = [
        228980, // Steamworks Common Redistributables
        1070560, 1391110, 1493710, 1628350, 2180100, // Steam Linux Runtime / Proton
    ]

    static func findSteamPath() -> String? {
        let path = NSHomeDirectory() + "/Library/Application Support/Steam"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Every steamapps folder across all configured library drives.
    static func findLibraryFolders(_ steamPath: String) -> [String] {
        var result: [String] = []
        let root = steamPath + "/steamapps"
        if FileManager.default.fileExists(atPath: root) { result.append(root) }

        guard let text = try? String(contentsOfFile: root + "/libraryfolders.vdf", encoding: .utf8) else { return result }
        for path in matches(#""path"\s+"([^"]+)""#, in: text) {
            let apps = (path.replacingOccurrences(of: "\\\\", with: "\\") as NSString)
                .appendingPathComponent("steamapps")
            let known = result.contains { ($0 as NSString).standardizingPath == (apps as NSString).standardizingPath }
            if FileManager.default.fileExists(atPath: apps) && !known { result.append(apps) }
        }
        return result
    }

    static func findInstalledGames(_ steamPath: String) -> [SteamGame] {
        var games: [SteamGame] = []
        var seen = Set<UInt32>()

        for apps in findLibraryFolders(steamPath) {
            let manifests = (try? FileManager.default.contentsOfDirectory(atPath: apps)) ?? []
            for file in manifests where file.hasPrefix("appmanifest_") && file.hasSuffix(".acf") {
                guard let text = try? String(contentsOfFile: apps + "/" + file, encoding: .utf8),
                      let idText = matches(#""appid"\s+"(\d+)""#, in: text).first,
                      let appId = UInt32(idText) else { continue }
                if excluded.contains(appId) || !seen.insert(appId).inserted { continue }

                let name = matches(#""name"\s+"([^"]*)""#, in: text).first ?? "App \(appId)"
                if name.range(of: "Redistributable", options: .caseInsensitive) != nil { continue }

                games.append(SteamGame(appId: appId, name: name, installed: true))
            }
        }

        return games.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Locates a libsteam_api.dylib for the worker to load in place. The Steam client
    /// ships its own universal copy, so a game is only searched as a fallback.
    static func findSteamApi(_ steamPath: String?) -> String? {
        guard let steamPath else { return nil }
        let fm = FileManager.default

        let clientCopy = steamPath + "/Steam.AppBundle/Steam/Contents/MacOS/Frameworks/"
            + "Steam Helper.app/Contents/MacOS/libsteam_api.dylib"
        if fm.fileExists(atPath: clientCopy) { return clientCopy }

        var roots = [steamPath + "/Steam.AppBundle"]
        roots += findLibraryFolders(steamPath).map { $0 + "/common" }
        for root in roots {
            guard let walk = fm.enumerator(atPath: root) else { continue }
            var visited = 0
            while let item = walk.nextObject() as? String, visited < 200_000 {
                visited += 1
                if (item as NSString).lastPathComponent == "libsteam_api.dylib" { return root + "/" + item }
            }
        }
        return nil
    }

    static func isSteamRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.executableURL?.lastPathComponent == "steam_osx" }
    }

    /// First capture group of every match.
    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
