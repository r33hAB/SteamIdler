// Discovery of the local Steam install and the games in it.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Win32;

class SteamGame
{
    public uint AppId;
    public string Name;
    public bool Installed;
}

static class SteamLibrary
{
    // Tool/runtime AppIDs that are never worth idling.
    static readonly HashSet<uint> Excluded = new HashSet<uint>
    {
        228980, // Steamworks Common Redistributables
        1070560, 1391110, 1493710, 1628350, 2180100, // Steam Linux Runtime / Proton
    };

    public static string FindSteamPath()
    {
        foreach (var hive in new[] { Registry.CurrentUser, Registry.LocalMachine })
        {
            foreach (var sub in new[] { @"Software\Valve\Steam", @"SOFTWARE\WOW6432Node\Valve\Steam" })
            {
                try
                {
                    using (var key = hive.OpenSubKey(sub))
                    {
                        if (key == null) continue;
                        var val = (key.GetValue("SteamPath") ?? key.GetValue("InstallPath")) as string;
                        if (!string.IsNullOrEmpty(val))
                        {
                            val = val.Replace('/', '\\');
                            if (Directory.Exists(val)) return val;
                        }
                    }
                }
                catch { }
            }
        }

        string fallback = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Steam");
        return Directory.Exists(fallback) ? fallback : null;
    }

    /// <summary>Every steamapps folder across all configured library drives.</summary>
    public static List<string> FindLibraryFolders(string steamPath)
    {
        var result = new List<string>();
        if (string.IsNullOrEmpty(steamPath)) return result;

        string root = Path.Combine(steamPath, "steamapps");
        if (Directory.Exists(root)) result.Add(root);

        string vdf = Path.Combine(root, "libraryfolders.vdf");
        if (!File.Exists(vdf)) return result;

        try
        {
            string text = File.ReadAllText(vdf, Encoding.UTF8);
            foreach (Match m in Regex.Matches(text, "\"path\"\\s+\"([^\"]+)\""))
            {
                string p = m.Groups[1].Value.Replace("\\\\", "\\");
                string apps = Path.Combine(p, "steamapps");
                if (Directory.Exists(apps) &&
                    !result.Exists(x => string.Equals(x, apps, StringComparison.OrdinalIgnoreCase)))
                    result.Add(apps);
            }
        }
        catch { }

        return result;
    }

    public static List<SteamGame> FindInstalledGames(string steamPath)
    {
        var games = new List<SteamGame>();
        var seen = new HashSet<uint>();

        foreach (string apps in FindLibraryFolders(steamPath))
        {
            string[] manifests;
            try { manifests = Directory.GetFiles(apps, "appmanifest_*.acf"); }
            catch { continue; }

            foreach (string file in manifests)
            {
                try
                {
                    string text = File.ReadAllText(file, Encoding.UTF8);
                    var idMatch = Regex.Match(text, "\"appid\"\\s+\"(\\d+)\"");
                    var nameMatch = Regex.Match(text, "\"name\"\\s+\"([^\"]*)\"");
                    if (!idMatch.Success) continue;

                    uint appId = uint.Parse(idMatch.Groups[1].Value);
                    if (Excluded.Contains(appId) || !seen.Add(appId)) continue;

                    string name = nameMatch.Success ? nameMatch.Groups[1].Value : "App " + appId;
                    if (name.IndexOf("Redistributable", StringComparison.OrdinalIgnoreCase) >= 0) continue;

                    games.Add(new SteamGame { AppId = appId, Name = name, Installed = true });
                }
                catch { }
            }
        }

        games.Sort((a, b) => string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase));
        return games;
    }

    /// <summary>Locates a steam_api64.dll shipped with any installed game, to copy next to the worker.</summary>
    public static string FindSteamApiDll(string steamPath)
    {
        foreach (string apps in FindLibraryFolders(steamPath))
        {
            string common = Path.Combine(apps, "common");
            if (!Directory.Exists(common)) continue;
            foreach (string dir in SafeEnumerate(common))
            {
                try
                {
                    string candidate = Path.Combine(dir, "steam_api64.dll");
                    if (File.Exists(candidate)) return candidate;
                }
                catch { }
            }
        }
        return null;
    }

    static IEnumerable<string> SafeEnumerate(string root)
    {
        var stack = new Stack<string>();
        stack.Push(root);
        int visited = 0;

        while (stack.Count > 0 && visited < 20000)
        {
            string dir = stack.Pop();
            visited++;
            yield return dir;

            string[] children;
            try { children = Directory.GetDirectories(dir); }
            catch { continue; }
            foreach (string c in children) stack.Push(c);
        }
    }

    public static bool IsSteamRunning()
    {
        try { return Process.GetProcessesByName("steam").Length > 0; }
        catch { return false; }
    }
}
