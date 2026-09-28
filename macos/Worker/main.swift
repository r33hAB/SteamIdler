// SteamIdlerWorker (macOS) - holds a single Steam AppID in the "playing" state.
//
// Usage: SteamIdlerWorker <appid> [parentPid] [path/to/libsteam_api.dylib]
//
// The macOS counterpart of src/Worker.cs. The Steam API binds one AppID per
// process, so the app spawns one of these per game. Prints "OK" on stdout once
// Steam has accepted the session, or "ERR <reason>" on stderr and exits non-zero.
import Darwin
import Dispatch
import Foundation

typealias InitFlatFn = @convention(c) (UnsafeMutablePointer<CChar>?) -> Int32  // SDK 1.59+, 0 == OK
typealias InitFn = @convention(c) () -> Bool                                   // older SDKs
typealias VoidFn = @convention(c) () -> Void

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data(("ERR " + message + "\n").utf8))
    exit(code)
}

// The Steam client ships a universal (arm64 + x86_64) copy of the library, so
// nothing has to be copied out of a game. The app passes the path it resolved;
// this default only matters when the worker is run by hand.
let defaultLibrary = NSHomeDirectory() + "/Library/Application Support/Steam/Steam.AppBundle/Steam/"
    + "Contents/MacOS/Frameworks/Steam Helper.app/Contents/MacOS/libsteam_api.dylib"

let args = CommandLine.arguments
guard args.count >= 2 else { fail("usage: SteamIdlerWorker <appid> [parentPid] [libsteam_api.dylib]", 1) }
guard let appId = UInt32(args[1]), appId != 0 else { fail("invalid appid", 1) }
let parentPid: pid_t = args.count > 2 ? pid_t(args[2]) ?? -1 : -1
let libraryPath = args.count > 3 ? args[3] : defaultLibrary

// The Steam API resolves the AppID from steam_appid.txt in the working
// directory first, then the SteamAppId env var. Set both, and give each worker
// its own working directory so the txt files never collide.
setenv("SteamAppId", String(appId), 1)
setenv("SteamGameId", String(appId), 1)

let workDir = NSHomeDirectory() + "/Library/Application Support/SteamIdler/app_\(appId)"
do {
    try FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
    try String(appId).write(toFile: workDir + "/steam_appid.txt", atomically: true, encoding: .utf8)
} catch {
    fail("could not prepare working directory: \(error.localizedDescription)", 3)
}
guard FileManager.default.changeCurrentDirectoryPath(workDir) else {
    fail("could not enter working directory \(workDir)", 3)
}

guard FileManager.default.fileExists(atPath: libraryPath) else {
    fail("libsteam_api.dylib missing at \(libraryPath)", 4)
}
guard let library = dlopen(libraryPath, RTLD_NOW | RTLD_LOCAL) else {
    fail("dlopen failed: " + String(cString: dlerror()), 4)
}

func bind<T>(_ name: String, _ type: T.Type) -> T? {
    guard let symbol = dlsym(library, name) else { return nil }
    return unsafeBitCast(symbol, to: type)
}

func describeInitResult(_ result: Int32) -> String {
    // ESteamAPIInitResult from steam_api.h.
    switch result {
    case 1: return "SteamAPI init failed"
    case 2: return "Steam is not running, or you are not logged in"
    case 3: return "Steam client is out of date"
    default: return "SteamAPI init failed (code \(result))"
    }
}

let runCallbacks = bind("SteamAPI_RunCallbacks", VoidFn.self)
let shutdown = bind("SteamAPI_Shutdown", VoidFn.self)

if let initFlat = bind("SteamAPI_InitFlat", InitFlatFn.self) {
    var message = [CChar](repeating: 0, count: 1024)
    let result = initFlat(&message)
    if result != 0 {
        let detail = String(cString: message)
        fail(describeInitResult(result) + (detail.isEmpty ? "" : " - " + detail), 5)
    }
} else if let initLegacy = bind("SteamAPI_Init", InitFn.self) {
    if !initLegacy() { fail("SteamAPI_Init returned false (is Steam running and do you own this game?)", 5) }
} else {
    fail("libsteam_api.dylib exports no usable init function", 5)
}

print("OK")
fflush(stdout)

// Hold the session open. Steam ends the play session as soon as this process
// exits, so all that is left is to pump callbacks and to leave cleanly on
// SIGTERM (how the app stops a game) or when the app itself goes away.
func finish() -> Never {
    shutdown?()
    exit(0)
}

func isAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
}

signal(SIGPIPE, SIG_IGN)  // the app's end of stdout/stderr may already be gone
let signalSources = [SIGTERM, SIGINT, SIGHUP].map { sig -> DispatchSourceSignal in
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { finish() }
    source.resume()
    return source
}

var ticks = 0
let pump = DispatchSource.makeTimerSource(queue: .main)
pump.schedule(deadline: .now(), repeating: .milliseconds(200))
pump.setEventHandler {
    runCallbacks?()
    ticks += 1
    if parentPid > 0 && ticks % 10 == 0 && !isAlive(parentPid) { finish() }
}
pump.resume()

dispatchMain()
