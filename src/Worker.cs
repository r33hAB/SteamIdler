// SteamIdlerWorker - holds a single Steam AppID in the "playing" state.
//
// Usage: SteamIdlerWorker.exe <appid> <parentPid>
//
// The Steam API binds one AppID per process, so the GUI spawns one of these
// per game. Prints "OK" on stdout once Steam has accepted the session, or
// "ERR <reason>" on stderr and exits non-zero.
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

static class Worker
{
    [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Ansi)]
    static extern IntPtr LoadLibrary(string fileName);

    [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Ansi)]
    static extern IntPtr GetProcAddress(IntPtr module, string procName);

    // SDK 1.59+: ESteamAPIInitResult SteamAPI_InitFlat(SteamErrMsg *pOutErrMsg)  (0 == OK)
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate int InitFlatFn(IntPtr errMsg);

    // Older SDKs: bool SteamAPI_Init()
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    delegate bool InitFn();

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate void VoidFn();

    static VoidFn _runCallbacks;
    static VoidFn _shutdown;

    static int Main(string[] args)
    {
        if (args.Length < 1)
        {
            Console.Error.WriteLine("ERR usage: SteamIdlerWorker.exe <appid> [parentPid]");
            return 1;
        }

        uint appId;
        if (!uint.TryParse(args[0], out appId) || appId == 0)
        {
            Console.Error.WriteLine("ERR invalid appid");
            return 1;
        }

        int parentPid = -1;
        if (args.Length > 1) int.TryParse(args[1], out parentPid);

        // The Steam API resolves the AppID from steam_appid.txt in the working
        // directory first, then the SteamAppId env var. Set both, and give each
        // worker its own working directory so the txt files never collide.
        Environment.SetEnvironmentVariable("SteamAppId", appId.ToString());
        Environment.SetEnvironmentVariable("SteamGameId", appId.ToString());

        string exeDir = AppDomain.CurrentDomain.BaseDirectory;
        try
        {
            string workDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "SteamIdler", "app_" + appId);
            Directory.CreateDirectory(workDir);
            File.WriteAllText(Path.Combine(workDir, "steam_appid.txt"), appId.ToString());
            Directory.SetCurrentDirectory(workDir);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("ERR could not prepare working directory: " + ex.Message);
            return 3;
        }

        string dllPath = Path.Combine(exeDir, "steam_api64.dll");
        if (!File.Exists(dllPath))
        {
            Console.Error.WriteLine("ERR steam_api64.dll missing next to SteamIdlerWorker.exe");
            return 4;
        }

        IntPtr lib = LoadLibrary(dllPath);
        if (lib == IntPtr.Zero)
        {
            Console.Error.WriteLine("ERR LoadLibrary failed (win32 " + Marshal.GetLastWin32Error() + ")");
            return 4;
        }

        _runCallbacks = Bind<VoidFn>(lib, "SteamAPI_RunCallbacks");
        _shutdown = Bind<VoidFn>(lib, "SteamAPI_Shutdown");

        string initError;
        if (!TryInit(lib, out initError))
        {
            Console.Error.WriteLine("ERR " + initError);
            return 5;
        }

        Console.Out.WriteLine("OK");
        Console.Out.Flush();

        // Hold the session open. Steam ends the play session as soon as this
        // process exits, so the loop only needs to pump callbacks and watch
        // for the GUI going away.
        var parentCheck = Stopwatch.StartNew();
        try
        {
            while (true)
            {
                if (_runCallbacks != null) _runCallbacks();

                if (parentPid > 0 && parentCheck.ElapsedMilliseconds > 2000)
                {
                    parentCheck.Restart();
                    if (!IsAlive(parentPid)) break;
                }

                Thread.Sleep(200);
            }
        }
        finally
        {
            if (_shutdown != null) { try { _shutdown(); } catch { } }
        }

        return 0;
    }

    static bool TryInit(IntPtr lib, out string error)
    {
        var initFlat = Bind<InitFlatFn>(lib, "SteamAPI_InitFlat");
        if (initFlat != null)
        {
            IntPtr buf = Marshal.AllocHGlobal(1024);
            try
            {
                for (int i = 0; i < 1024; i++) Marshal.WriteByte(buf, i, 0);
                int result = initFlat(buf);
                if (result == 0) { error = null; return true; }
                string msg = Marshal.PtrToStringAnsi(buf);
                error = DescribeInitResult(result) + (string.IsNullOrEmpty(msg) ? "" : " - " + msg);
                return false;
            }
            finally { Marshal.FreeHGlobal(buf); }
        }

        var init = Bind<InitFn>(lib, "SteamAPI_Init");
        if (init != null)
        {
            if (init()) { error = null; return true; }
            error = "SteamAPI_Init returned false (is Steam running and do you own this game?)";
            return false;
        }

        error = "steam_api64.dll exports no usable init function";
        return false;
    }

    static string DescribeInitResult(int result)
    {
        switch (result)
        {
            case 1: return "Steam is not running, or you are not logged in";
            case 2: return "This Steam account does not own that AppID";
            case 3: return "Steam client is out of date";
            default: return "SteamAPI init failed (code " + result + ")";
        }
    }

    static T Bind<T>(IntPtr lib, string name) where T : class
    {
        IntPtr addr = GetProcAddress(lib, name);
        if (addr == IntPtr.Zero) return null;
        return Marshal.GetDelegateForFunctionPointer(addr, typeof(T)) as T;
    }

    static bool IsAlive(int pid)
    {
        try
        {
            var p = Process.GetProcessById(pid);
            return !p.HasExited;
        }
        catch { return false; }
    }
}
