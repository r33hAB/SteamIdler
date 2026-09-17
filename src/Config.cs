// Flat key=value config stored next to the exe. Avoids any JSON dependency
// so the app stays buildable with the in-box .NET Framework compiler.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;

class Config
{
    public readonly List<SteamGame> CustomGames = new List<SteamGame>();
    public readonly HashSet<uint> Checked = new HashSet<uint>();
    public readonly Dictionary<uint, TimeSpan> Totals = new Dictionary<uint, TimeSpan>();
    public bool AutoStopEnabled;
    public double AutoStopHours = 4;
    public bool MinimizeToTray = true;

    static string Path_
    {
        get
        {
            return System.IO.Path.Combine(
                AppDomain.CurrentDomain.BaseDirectory, "SteamIdler.cfg");
        }
    }

    public static Config Load()
    {
        var cfg = new Config();
        if (!File.Exists(Path_)) return cfg;

        foreach (string raw in File.ReadAllLines(Path_, Encoding.UTF8))
        {
            string line = raw.Trim();
            if (line.Length == 0 || line.StartsWith("#")) continue;

            int eq = line.IndexOf('=');
            if (eq <= 0) continue;
            string key = line.Substring(0, eq).Trim();
            string value = line.Substring(eq + 1).Trim();

            try
            {
                switch (key)
                {
                    case "custom":
                        {
                            int bar = value.IndexOf('|');
                            uint id = uint.Parse(bar < 0 ? value : value.Substring(0, bar));
                            string name = bar < 0 ? "App " + id : value.Substring(bar + 1);
                            cfg.CustomGames.Add(new SteamGame { AppId = id, Name = name, Installed = false });
                            break;
                        }
                    case "checked":
                        cfg.Checked.Add(uint.Parse(value));
                        break;
                    case "total":
                        {
                            int bar = value.IndexOf('|');
                            uint id = uint.Parse(value.Substring(0, bar));
                            double seconds = double.Parse(value.Substring(bar + 1), CultureInfo.InvariantCulture);
                            cfg.Totals[id] = TimeSpan.FromSeconds(seconds);
                            break;
                        }
                    case "autostop":
                        cfg.AutoStopEnabled = value == "1";
                        break;
                    case "autostophours":
                        cfg.AutoStopHours = double.Parse(value, CultureInfo.InvariantCulture);
                        break;
                    case "tray":
                        cfg.MinimizeToTray = value == "1";
                        break;
                }
            }
            catch { }
        }

        return cfg;
    }

    public void Save()
    {
        var sb = new StringBuilder();
        sb.AppendLine("# SteamIdler settings - edit while the app is closed");
        foreach (var g in CustomGames)
            sb.AppendLine("custom=" + g.AppId + "|" + g.Name.Replace("\r", "").Replace("\n", ""));
        foreach (uint id in Checked)
            sb.AppendLine("checked=" + id);
        foreach (var kv in Totals)
            sb.AppendLine("total=" + kv.Key + "|" +
                kv.Value.TotalSeconds.ToString("0.##", CultureInfo.InvariantCulture));
        sb.AppendLine("autostop=" + (AutoStopEnabled ? "1" : "0"));
        sb.AppendLine("autostophours=" + AutoStopHours.ToString("0.##", CultureInfo.InvariantCulture));
        sb.AppendLine("tray=" + (MinimizeToTray ? "1" : "0"));

        try { File.WriteAllText(Path_, sb.ToString(), new UTF8Encoding(false)); }
        catch { }
    }
}
