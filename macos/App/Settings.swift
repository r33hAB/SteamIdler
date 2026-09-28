// Settings and tracked totals, kept in the app's defaults domain. Inspect them
// with `defaults read com.r33hab.steamidler`.
import Foundation

struct Settings {
    var customGames: [SteamGame] = []
    var checked: Set<UInt32> = []
    var totals: [UInt32: TimeInterval] = [:]
    var autoStopEnabled = false
    var autoStopHours = 4.0

    static func load() -> Settings {
        let defaults = UserDefaults.standard
        var settings = Settings()

        if let games = defaults.array(forKey: "customGames") as? [[String: Any]] {
            settings.customGames = games.compactMap { game in
                guard let id = (game["appId"] as? NSNumber)?.uint32Value, id != 0 else { return nil }
                return SteamGame(appId: id, name: game["name"] as? String ?? "App \(id)", installed: false)
            }
        }
        if let ids = defaults.array(forKey: "checked") as? [NSNumber] {
            settings.checked = Set(ids.map(\.uint32Value))
        }
        if let totals = defaults.dictionary(forKey: "totals") as? [String: NSNumber] {
            for (key, seconds) in totals {
                if let id = UInt32(key) { settings.totals[id] = seconds.doubleValue }
            }
        }
        if defaults.object(forKey: "autoStopEnabled") != nil {
            settings.autoStopEnabled = defaults.bool(forKey: "autoStopEnabled")
        }
        if defaults.object(forKey: "autoStopHours") != nil {
            settings.autoStopHours = max(0.1, defaults.double(forKey: "autoStopHours"))
        }
        return settings
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(customGames.map { ["appId": Int($0.appId), "name": $0.name] }, forKey: "customGames")
        defaults.set(checked.sorted().map { Int($0) }, forKey: "checked")
        defaults.set(Dictionary(uniqueKeysWithValues: totals.map { (String($0.key), $0.value) }), forKey: "totals")
        defaults.set(autoStopEnabled, forKey: "autoStopEnabled")
        defaults.set(autoStopHours, forKey: "autoStopHours")
    }
}
