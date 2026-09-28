// The supervisor: game list, one SteamIdlerWorker process per idling game,
// timers and persistence. The macOS counterpart of the logic in src/MainForm.cs.
// Everything here runs on the main thread; worker callbacks hop back onto it.
import Foundation

final class Entry {
    var game: SteamGame
    var process: Process?
    var startedAt = Date()
    var accumulated: TimeInterval   // carried over from previous sessions
    var status = "Idle"
    var confirmed = false
    var checked: Bool

    init(game: SteamGame, checked: Bool, accumulated: TimeInterval) {
        self.game = game
        self.checked = checked
        self.accumulated = accumulated
    }

    var running: Bool { process?.isRunning == true }
    var session: TimeInterval { running && confirmed ? Date().timeIntervalSince(startedAt) : 0 }
    var total: TimeInterval { accumulated + session }
    var failed: Bool { status.hasPrefix("Failed") }

    func owns(_ token: ObjectIdentifier) -> Bool {
        process.map(ObjectIdentifier.init) == token
    }
}

/// One table row: a value snapshot, so SwiftUI sees every change.
struct GameRow: Identifiable, Equatable {
    enum Tone { case normal, active, failed }

    let id: UInt32   // AppID
    let name: String
    let installed: Bool
    let checked: Bool
    let status: String
    let tone: Tone
    let session: String
    let total: String
}

struct Notice: Equatable {
    let title: String
    let message: String
}

final class Idler: ObservableObject {
    static let maxConcurrent = 32   // Steam refuses further sessions past roughly this many

    @Published private(set) var rows: [GameRow] = []
    @Published private(set) var runningCount = 0
    @Published private(set) var steamRunning = false
    @Published private(set) var steamPath: String?
    @Published private(set) var statusLine = "Ready."
    @Published var selection: UInt32?
    @Published var notice: Notice?
    @Published var autoStopEnabled: Bool {
        didSet { settings.autoStopEnabled = autoStopEnabled; settings.save() }
    }
    @Published var autoStopHours: Double {
        didSet {
            autoStopHours = min(1000, max(0.1, autoStopHours))
            settings.autoStopHours = autoStopHours
            settings.save()
        }
    }

    private var settings: Settings
    private var entries: [UInt32: Entry] = [:]
    private var timer: Timer?

    init() {
        settings = Settings.load()
        autoStopEnabled = settings.autoStopEnabled
        autoStopHours = settings.autoStopHours
        refreshGames()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    // ------------------------------------------------------- game list

    func refreshGames() {
        steamPath = SteamLibrary.findSteamPath()
        if SteamLibrary.findSteamApi(steamPath) == nil {
            setStatus("libsteam_api.dylib not found. Install Steam and sign in, then press Refresh.")
        }

        var games = steamPath.map(SteamLibrary.findInstalledGames) ?? []
        for custom in settings.customGames where !games.contains(where: { $0.appId == custom.appId }) {
            games.append(custom)
        }

        // Keep entries for anything currently running even if it vanished from disk.
        for game in games {
            if let entry = entries[game.appId] {
                entry.game = game
            } else {
                entries[game.appId] = Entry(game: game,
                                            checked: settings.checked.contains(game.appId),
                                            accumulated: settings.totals[game.appId] ?? 0)
            }
        }
        publish()
    }

    /// Adds an owned-but-not-installed game. Returns an error message, or nil on success.
    func addCustom(appId: UInt32, name: String) -> String? {
        if entries[appId] != nil { return "AppID \(appId) is already in the list." }
        settings.customGames.append(SteamGame(appId: appId, name: name.isEmpty ? "App \(appId)" : name, installed: false))
        settings.save()
        refreshGames()
        setStatus("Added AppID \(appId).")
        return nil
    }

    var canRemoveSelection: Bool {
        selection.flatMap { entries[$0] }.map { !$0.game.installed } ?? false
    }

    func removeSelected() {
        guard let id = selection, let entry = entries[id] else { setStatus("Select a row to remove."); return }
        if entry.game.installed {
            setStatus("Installed games are detected automatically and cannot be removed.")
            return
        }

        stop(entry)
        settings.customGames.removeAll { $0.appId == id }
        settings.checked.remove(id)
        entries[id] = nil
        selection = nil
        settings.save()
        refreshGames()
    }

    func setChecked(_ id: UInt32, _ checked: Bool) {
        entries[id]?.checked = checked
        saveChecked()
        publish()
    }

    // ------------------------------------------------------ idling

    func startChecked() {
        guard let worker = Bundle.main.url(forAuxiliaryExecutable: "SteamIdlerWorker") else {
            notice = Notice(title: "Worker missing",
                            message: "SteamIdlerWorker is missing from the app bundle.\n\nRe-run build.sh.")
            return
        }
        if !SteamLibrary.isSteamRunning() {
            notice = Notice(title: "Steam is not running", message: "Start Steam, sign in, then try again.")
            return
        }
        guard let library = SteamLibrary.findSteamApi(steamPath ?? SteamLibrary.findSteamPath()) else {
            notice = Notice(title: "libsteam_api.dylib not found",
                            message: "The Steam client normally ships it. Reinstall Steam, or install any Mac game that uses Steamworks.")
            return
        }

        let toStart = sortedEntries().filter { $0.checked && !$0.running }
        if toStart.isEmpty { setStatus("Nothing checked that isn't already running."); return }

        let alreadyRunning = countRunning()
        if alreadyRunning + toStart.count > Self.maxConcurrent {
            notice = Notice(title: "Too many games",
                            message: "Steam only accepts about \(Self.maxConcurrent) simultaneous games per account.\n\n"
                                + "You have \(alreadyRunning) running and asked for \(toStart.count) more. Uncheck some games first.")
            return
        }

        for entry in toStart { start(entry, worker: worker, library: library) }
        saveChecked()
        setStatus("Starting \(toStart.count) game(s)...")
    }

    private func start(_ entry: Entry, worker: URL, library: String) {
        let process = Process()
        process.executableURL = worker
        process.arguments = [String(entry.game.appId), String(getpid()), library]
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let appId = entry.game.appId
        let token = ObjectIdentifier(process)
        readLines(out) { [weak self] line in
            if line == "OK" { self?.workerReady(appId, token) }
        }
        readLines(err) { [weak self] line in
            // steam_api writes its own chatter ("Setting breakpad minidump...")
            // to stderr, so only our own ERR lines count as failures.
            if line.hasPrefix("ERR ") { self?.workerFailed(appId, token, String(line.dropFirst(4))) }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.workerExited(appId, token) }
        }

        do {
            try process.run()
            entry.process = process
            entry.confirmed = false
            entry.status = "Connecting..."
        } catch {
            entry.process = nil
            entry.status = "Failed: \(error.localizedDescription)"
        }
        publish()
    }

    private func workerReady(_ appId: UInt32, _ token: ObjectIdentifier) {
        guard let entry = entries[appId], entry.owns(token) else { return }
        entry.confirmed = true
        entry.startedAt = Date()
        entry.status = "Idling"
        // Note: init also succeeds for games the account does not own, but Steam
        // only credits playtime for owned apps - so this is "session open", not
        // "hours guaranteed".
        setStatus("\(entry.game.name) - session open.")
        publish()
    }

    private func workerFailed(_ appId: UInt32, _ token: ObjectIdentifier, _ message: String) {
        // The ERR line can arrive after the exit has already been handled.
        guard let entry = entries[appId], entry.process == nil || entry.owns(token) else { return }
        entry.status = "Failed: " + message
        setStatus("\(entry.game.name): \(message)")
        publish()
    }

    private func workerExited(_ appId: UInt32, _ token: ObjectIdentifier) {
        guard let entry = entries[appId], entry.owns(token) else { return }

        if entry.confirmed {
            entry.accumulated += Date().timeIntervalSince(entry.startedAt)
            settings.totals[appId] = entry.accumulated
            settings.save()
        }

        entry.confirmed = false
        entry.process = nil
        if !entry.failed && entry.status != "Auto-stopped" { entry.status = "Stopped" }
        publish()
    }

    private func stop(_ entry: Entry) {
        if let process = entry.process, process.isRunning { process.terminate() }
    }

    func stopAll() {
        for entry in entries.values { stop(entry) }
        setStatus("Stopped all games.")
    }

    /// Called as the app quits: bank the running sessions and stop every worker.
    func shutdown() {
        timer?.invalidate()
        for entry in entries.values {
            if entry.running && entry.confirmed {
                entry.accumulated += Date().timeIntervalSince(entry.startedAt)
                settings.totals[entry.game.appId] = entry.accumulated
                entry.confirmed = false
            }
            stop(entry)
        }

        // Give the workers a moment to call SteamAPI_Shutdown; kill any that hang.
        let deadline = Date().addingTimeInterval(2)
        while entries.values.contains(where: \.running) && Date() < deadline { usleep(50_000) }
        for entry in entries.values where entry.running {
            if let pid = entry.process?.processIdentifier { kill(pid, SIGKILL) }
        }

        saveChecked()
        settings.save()
    }

    private func countRunning() -> Int {
        entries.values.filter(\.running).count
    }

    // ------------------------------------------------------ tick / render

    private func tick() {
        if autoStopEnabled {
            let limit = autoStopHours * 3600
            for entry in entries.values where entry.running && entry.confirmed && entry.session >= limit {
                entry.status = "Auto-stopped"
                stop(entry)
            }
        }

        if !SteamLibrary.isSteamRunning() && countRunning() > 0 {
            stopAll()
            setStatus("Steam closed - stopped all idling.")
        }

        publish()
    }

    private func sortedEntries() -> [Entry] {
        entries.values.sorted { $0.game.name.localizedCaseInsensitiveCompare($1.game.name) == .orderedAscending }
    }

    private func publish() {
        let newRows = sortedEntries().map { entry in
            GameRow(id: entry.game.appId,
                    name: entry.game.name,
                    installed: entry.game.installed,
                    checked: entry.checked,
                    status: entry.status,
                    tone: entry.running && entry.confirmed ? .active : entry.failed ? .failed : .normal,
                    session: Self.format(entry.session),
                    total: Self.format(entry.total))
        }
        if newRows != rows { rows = newRows }

        let running = countRunning()
        if running != runningCount { runningCount = running }
        let steamUp = SteamLibrary.isSteamRunning()
        if steamUp != steamRunning { steamRunning = steamUp }
    }

    private func saveChecked() {
        settings.checked = Set(entries.values.filter(\.checked).map(\.game.appId))
        settings.save()
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private func setStatus(_ text: String) {
        statusLine = Self.clock.string(from: Date()) + "  " + text
    }

    static func format(_ interval: TimeInterval) -> String {
        guard interval > 0 else { return "-" }
        let seconds = Int(interval)
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}

/// Splits a pipe's output into lines and hands each one to `onLine` on the main queue.
private func readLines(_ pipe: Pipe, _ onLine: @escaping (String) -> Void) {
    var buffer = Data()
    pipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        if chunk.isEmpty { handle.readabilityHandler = nil; return }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(buffer.startIndex...newline)
            DispatchQueue.main.async { onLine(line) }
        }
    }
}
