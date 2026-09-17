// SteamIdler - keeps one or more owned Steam games in the "playing" state.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

class Entry
{
    public SteamGame Game;
    public Process Proc;
    public DateTime StartedUtc;
    public TimeSpan Accumulated;   // carried over from previous sessions
    public string Status = "Idle";
    public bool Confirmed;
    public bool Checked;

    public bool Running { get { return Proc != null && !Proc.HasExited; } }

    public TimeSpan Session
    {
        get { return Running && Confirmed ? DateTime.UtcNow - StartedUtc : TimeSpan.Zero; }
    }

    public TimeSpan Total { get { return Accumulated + Session; } }
}

class MainForm : Form
{
    const int MaxConcurrent = 32;   // Steam refuses further sessions past roughly this many

    readonly Config _cfg = Config.Load();
    readonly Dictionary<uint, Entry> _entries = new Dictionary<uint, Entry>();
    readonly ListView _list = new ListView();
    readonly Button _startBtn = new Button();
    readonly Button _stopBtn = new Button();
    readonly CheckBox _autoStop = new CheckBox();
    readonly NumericUpDown _autoStopHours = new NumericUpDown();
    readonly Label _steamStatus = new Label();
    readonly StatusStrip _status = new StatusStrip();
    readonly ToolStripStatusLabel _statusLabel = new ToolStripStatusLabel();
    readonly NotifyIcon _tray = new NotifyIcon();
    // Fully qualified: System.Threading is imported for Mutex, and both
    // namespaces define a Timer.
    readonly System.Windows.Forms.Timer _timer = new System.Windows.Forms.Timer();

    string _steamPath;
    string _workerPath;
    bool _populating;
    bool _reallyClosing;

    public MainForm()
    {
        Text = "Steam Idler";
        Width = 760;
        Height = 560;
        MinimumSize = new Size(620, 400);
        StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Segoe UI", 9f);

        BuildUi();

        _steamPath = SteamLibrary.FindSteamPath();
        _workerPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "SteamIdlerWorker.exe");

        EnsureSteamApiDll();
        RefreshGames();

        _timer.Interval = 1000;
        _timer.Tick += (s, e) => Tick();
        _timer.Start();
    }

    // ---------------------------------------------------------------- UI

    void BuildUi()
    {
        var header = new Panel { Dock = DockStyle.Top, Height = 34, Padding = new Padding(10, 8, 10, 0) };
        _steamStatus.Dock = DockStyle.Fill;
        _steamStatus.TextAlign = ContentAlignment.MiddleLeft;
        header.Controls.Add(_steamStatus);

        _list.Dock = DockStyle.Fill;
        _list.View = View.Details;
        _list.CheckBoxes = true;
        _list.FullRowSelect = true;
        _list.GridLines = true;
        _list.HideSelection = false;
        _list.Columns.Add("Game", 280);
        _list.Columns.Add("AppID", 80, HorizontalAlignment.Right);
        _list.Columns.Add("Status", 150);
        _list.Columns.Add("Session", 90, HorizontalAlignment.Right);
        _list.Columns.Add("Tracked total", 100, HorizontalAlignment.Right);
        // Checked state is mirrored onto the Entry, because ListView.Items cannot
        // be safely enumerated from inside ItemChecked - the event fires while the
        // native control is still realizing items and the collection yields nulls.
        _list.ItemChecked += (s, e) =>
        {
            var entry = e.Item.Tag as Entry;
            if (entry != null) entry.Checked = e.Item.Checked;
            if (!_populating) UpdateButtons();
        };

        var listHost = new Panel { Dock = DockStyle.Fill, Padding = new Padding(10, 6, 10, 6) };
        listHost.Controls.Add(_list);

        var bottom = new Panel { Dock = DockStyle.Bottom, Height = 92, Padding = new Padding(10, 4, 10, 8) };

        _startBtn.Text = "Start idling";
        _startBtn.Size = new Size(120, 30);
        _startBtn.Location = new Point(10, 8);
        _startBtn.Click += (s, e) => StartChecked();

        _stopBtn.Text = "Stop all";
        _stopBtn.Size = new Size(100, 30);
        _stopBtn.Location = new Point(138, 8);
        _stopBtn.Click += (s, e) => StopAll();

        var addBtn = new Button { Text = "Add AppID...", Size = new Size(110, 30), Location = new Point(248, 8) };
        addBtn.Click += (s, e) => AddCustom();

        var removeBtn = new Button { Text = "Remove", Size = new Size(85, 30), Location = new Point(366, 8) };
        removeBtn.Click += (s, e) => RemoveSelectedCustom();

        var refreshBtn = new Button { Text = "Refresh", Size = new Size(85, 30), Location = new Point(459, 8) };
        refreshBtn.Click += (s, e) => { EnsureSteamApiDll(); RefreshGames(); };

        _autoStop.Text = "Stop automatically after";
        _autoStop.AutoSize = true;
        _autoStop.Location = new Point(13, 50);
        _autoStop.Checked = _cfg.AutoStopEnabled;
        _autoStop.CheckedChanged += (s, e) => _cfg.AutoStopEnabled = _autoStop.Checked;

        _autoStopHours.Location = new Point(165, 48);
        _autoStopHours.Size = new Size(60, 24);
        _autoStopHours.DecimalPlaces = 1;
        _autoStopHours.Minimum = 0.1m;
        _autoStopHours.Maximum = 1000m;
        _autoStopHours.Increment = 0.5m;
        _autoStopHours.Value = (decimal)Math.Max(0.1, _cfg.AutoStopHours);
        _autoStopHours.ValueChanged += (s, e) => _cfg.AutoStopHours = (double)_autoStopHours.Value;

        var hoursLabel = new Label { Text = "hours per game", AutoSize = true, Location = new Point(231, 52) };

        var trayCheck = new CheckBox
        {
            Text = "Minimize to tray",
            AutoSize = true,
            Location = new Point(360, 50),
            Checked = _cfg.MinimizeToTray
        };
        trayCheck.CheckedChanged += (s, e) => _cfg.MinimizeToTray = trayCheck.Checked;

        bottom.Controls.AddRange(new Control[] {
            _startBtn, _stopBtn, addBtn, removeBtn, refreshBtn,
            _autoStop, _autoStopHours, hoursLabel, trayCheck
        });

        _status.Items.Add(_statusLabel);
        _statusLabel.Text = "Ready.";

        Controls.Add(listHost);
        Controls.Add(bottom);
        Controls.Add(header);
        Controls.Add(_status);

        Icon = AppIcon;
        _tray.Icon = AppIcon;
        _tray.Text = "Steam Idler";
        _tray.Visible = false;
        _tray.DoubleClick += (s, e) => RestoreFromTray();
        _tray.MouseClick += (s, e) => { if (e.Button == MouseButtons.Left) RestoreFromTray(); };

        var menu = new ContextMenuStrip();
        menu.Items.Add("Show", null, (s, e) => RestoreFromTray());
        menu.Items.Add("Stop all", null, (s, e) => StopAll());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Exit", null, (s, e) => { _reallyClosing = true; Close(); });
        _tray.ContextMenuStrip = menu;

        Resize += (s, e) =>
        {
            if (WindowState == FormWindowState.Minimized && _cfg.MinimizeToTray)
            {
                Hide();
                _tray.Visible = true;
            }
        };

        FormClosing += OnFormClosing;
    }

    void RestoreFromTray()
    {
        Show();
        WindowState = FormWindowState.Normal;
        _tray.Visible = false;
        Activate();
    }

    // ------------------------------------------------------- game list

    void EnsureSteamApiDll()
    {
        string target = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "steam_api64.dll");
        if (File.Exists(target)) return;

        string source = SteamLibrary.FindSteamApiDll(_steamPath);
        if (source == null)
        {
            SetStatus("steam_api64.dll not found. Copy one from any installed game folder next to this exe.");
            return;
        }

        try
        {
            File.Copy(source, target, false);
            SetStatus("Copied steam_api64.dll from " + Path.GetFileName(Path.GetDirectoryName(source)) + ".");
        }
        catch (Exception ex)
        {
            SetStatus("Could not copy steam_api64.dll: " + ex.Message);
        }
    }

    void RefreshGames()
    {
        _steamStatus.Text = SteamLibrary.IsSteamRunning()
            ? "Steam is running.   Library: " + (_steamPath ?? "not found")
            : "Steam is NOT running - start Steam and log in before idling.";
        _steamStatus.ForeColor = SteamLibrary.IsSteamRunning()
            ? Color.FromArgb(0, 110, 40) : Color.FromArgb(170, 30, 30);

        var games = new List<SteamGame>();
        if (_steamPath != null) games.AddRange(SteamLibrary.FindInstalledGames(_steamPath));
        foreach (var custom in _cfg.CustomGames)
            if (!games.Exists(g => g.AppId == custom.AppId)) games.Add(custom);

        // Keep entries for anything currently running even if it vanished from disk.
        foreach (var g in games)
        {
            if (!_entries.ContainsKey(g.AppId))
            {
                var entry = new Entry { Game = g, Checked = _cfg.Checked.Contains(g.AppId) };
                TimeSpan stored;
                if (_cfg.Totals.TryGetValue(g.AppId, out stored)) entry.Accumulated = stored;
                _entries[g.AppId] = entry;
            }
            else
            {
                _entries[g.AppId].Game = g;
            }
        }

        _populating = true;
        _list.BeginUpdate();
        _list.Items.Clear();

        var ordered = new List<Entry>(_entries.Values);
        ordered.Sort((a, b) => string.Compare(a.Game.Name, b.Game.Name, StringComparison.OrdinalIgnoreCase));

        foreach (var entry in ordered)
        {
            var item = new ListViewItem(entry.Game.Name);
            item.SubItems.Add(entry.Game.AppId.ToString());
            item.SubItems.Add(entry.Status);
            item.SubItems.Add(Fmt(entry.Session));
            item.SubItems.Add(Fmt(entry.Total));
            item.Tag = entry;
            item.Checked = entry.Checked;
            if (!entry.Game.Installed) item.ForeColor = Color.FromArgb(70, 70, 140);
            _list.Items.Add(item);
        }

        _list.EndUpdate();
        _populating = false;
        UpdateButtons();
    }

    void AddCustom()
    {
        using (var dlg = new AddAppForm())
        {
            if (dlg.ShowDialog(this) != DialogResult.OK) return;
            if (_entries.ContainsKey(dlg.AppId))
            {
                SetStatus("AppID " + dlg.AppId + " is already in the list.");
                return;
            }

            _cfg.CustomGames.Add(new SteamGame
            {
                AppId = dlg.AppId,
                Name = string.IsNullOrEmpty(dlg.GameName) ? "App " + dlg.AppId : dlg.GameName,
                Installed = false
            });
            _cfg.Save();
            RefreshGames();
            SetStatus("Added AppID " + dlg.AppId + ".");
        }
    }

    void RemoveSelectedCustom()
    {
        if (_list.SelectedItems.Count == 0) { SetStatus("Select a row to remove."); return; }
        var entry = (Entry)_list.SelectedItems[0].Tag;

        if (entry.Game.Installed)
        {
            SetStatus("Installed games are detected automatically and cannot be removed.");
            return;
        }

        Stop(entry);
        _cfg.CustomGames.RemoveAll(g => g.AppId == entry.Game.AppId);
        _cfg.Checked.Remove(entry.Game.AppId);
        _entries.Remove(entry.Game.AppId);
        _cfg.Save();
        RefreshGames();
    }

    // ------------------------------------------------------ idling

    void StartChecked()
    {
        if (!File.Exists(_workerPath))
        {
            MessageBox.Show(this, "SteamIdlerWorker.exe is missing from " +
                AppDomain.CurrentDomain.BaseDirectory + ".\n\nRe-run build.ps1.",
                "Steam Idler", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        if (!SteamLibrary.IsSteamRunning())
        {
            MessageBox.Show(this, "Steam is not running. Start Steam, log in, then try again.",
                "Steam Idler", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }

        var toStart = new List<Entry>();
        foreach (var entry in _entries.Values)
            if (entry.Checked && !entry.Running) toStart.Add(entry);

        if (toStart.Count == 0) { SetStatus("Nothing checked that isn't already running."); return; }

        int alreadyRunning = CountRunning();
        if (alreadyRunning + toStart.Count > MaxConcurrent)
        {
            MessageBox.Show(this,
                "Steam only accepts about " + MaxConcurrent + " simultaneous games per account.\n\n" +
                "You have " + alreadyRunning + " running and asked for " + toStart.Count + " more. " +
                "Uncheck some games first.",
                "Too many games", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }

        foreach (var entry in toStart) Start(entry);
        SaveChecked();
        SetStatus("Starting " + toStart.Count + " game(s)...");
    }

    void Start(Entry entry)
    {
        try
        {
            var psi = new ProcessStartInfo(_workerPath,
                entry.Game.AppId + " " + Process.GetCurrentProcess().Id)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                WorkingDirectory = AppDomain.CurrentDomain.BaseDirectory
            };

            var proc = new Process { StartInfo = psi, EnableRaisingEvents = true };
            uint appId = entry.Game.AppId;

            proc.OutputDataReceived += (s, e) =>
            {
                if (e.Data == null) return;
                if (e.Data.Trim() == "OK") BeginInvoke((Action)(() => OnWorkerReady(appId)));
            };
            proc.ErrorDataReceived += (s, e) =>
            {
                // steam_api writes its own banner ("Setting breakpad minidump...")
                // to stderr, so only our own ERR lines count as failures.
                if (string.IsNullOrEmpty(e.Data) || !e.Data.StartsWith("ERR ")) return;
                string msg = e.Data.Substring(4);
                BeginInvoke((Action)(() => OnWorkerError(appId, msg)));
            };
            proc.Exited += (s, e) => BeginInvoke((Action)(() => OnWorkerExited(appId)));

            proc.Start();
            proc.BeginOutputReadLine();
            proc.BeginErrorReadLine();

            entry.Proc = proc;
            entry.Confirmed = false;
            entry.Status = "Connecting...";
        }
        catch (Exception ex)
        {
            entry.Proc = null;
            entry.Status = "Failed: " + ex.Message;
        }

        UpdateRows();
    }

    void OnWorkerReady(uint appId)
    {
        Entry entry;
        if (!_entries.TryGetValue(appId, out entry)) return;
        entry.Confirmed = true;
        entry.StartedUtc = DateTime.UtcNow;
        entry.Status = "Idling";
        // Note: init also succeeds for games the account does not own, but Steam
        // only credits playtime for owned apps - so this is "session open", not
        // "hours guaranteed".
        SetStatus(entry.Game.Name + " - session open.");
        UpdateRows();
    }

    void OnWorkerError(uint appId, string message)
    {
        Entry entry;
        if (!_entries.TryGetValue(appId, out entry)) return;
        entry.Status = "Failed: " + message;
        SetStatus(entry.Game.Name + ": " + message);
        UpdateRows();
    }

    void OnWorkerExited(uint appId)
    {
        Entry entry;
        if (!_entries.TryGetValue(appId, out entry)) return;

        if (entry.Confirmed)
        {
            entry.Accumulated += DateTime.UtcNow - entry.StartedUtc;
            _cfg.Totals[appId] = entry.Accumulated;
            _cfg.Save();
        }

        entry.Confirmed = false;
        if (entry.Proc != null) { try { entry.Proc.Dispose(); } catch { } }
        entry.Proc = null;
        if (!entry.Status.StartsWith("Failed") && entry.Status != "Auto-stopped")
            entry.Status = "Stopped";
        UpdateRows();
    }

    void Stop(Entry entry)
    {
        if (entry.Proc == null) return;
        try { if (!entry.Proc.HasExited) entry.Proc.Kill(); }
        catch { }
    }

    void StopAll()
    {
        foreach (var entry in _entries.Values) Stop(entry);
        SetStatus("Stopped all games.");
    }

    int CountRunning()
    {
        int n = 0;
        foreach (var e in _entries.Values) if (e.Running) n++;
        return n;
    }

    // ------------------------------------------------------ tick / render

    void Tick()
    {
        if (_cfg.AutoStopEnabled)
        {
            var limit = TimeSpan.FromHours(_cfg.AutoStopHours);
            foreach (var entry in _entries.Values)
            {
                if (entry.Running && entry.Confirmed && entry.Session >= limit)
                {
                    entry.Status = "Auto-stopped";
                    Stop(entry);
                }
            }
        }

        bool steamUp = SteamLibrary.IsSteamRunning();
        if (!steamUp && CountRunning() > 0)
        {
            StopAll();
            SetStatus("Steam closed - stopped all idling.");
        }

        UpdateRows();
    }

    void UpdateRows()
    {
        foreach (ListViewItem item in _list.Items)
        {
            if (item == null) continue;
            var entry = item.Tag as Entry;
            if (entry == null) continue;
            item.SubItems[2].Text = entry.Status;
            item.SubItems[3].Text = Fmt(entry.Session);
            item.SubItems[4].Text = Fmt(entry.Total);
            item.SubItems[2].ForeColor = entry.Running && entry.Confirmed
                ? Color.FromArgb(0, 110, 40)
                : entry.Status.StartsWith("Failed") ? Color.FromArgb(170, 30, 30) : SystemColors.ControlText;
        }

        int running = CountRunning();
        _tray.Text = running > 0 ? "Steam Idler - " + running + " game(s) idling" : "Steam Idler";
        UpdateButtons();
    }

    void UpdateButtons()
    {
        int running = CountRunning();
        _stopBtn.Enabled = running > 0;

        int checkedCount = 0;
        foreach (var entry in _entries.Values) if (entry.Checked) checkedCount++;
        _startBtn.Enabled = checkedCount > 0;

        Text = running > 0 ? "Steam Idler - " + running + " idling" : "Steam Idler";
    }

    void SaveChecked()
    {
        _cfg.Checked.Clear();
        foreach (var entry in _entries.Values)
            if (entry.Checked) _cfg.Checked.Add(entry.Game.AppId);
        _cfg.Save();
    }

    void SetStatus(string text)
    {
        _statusLabel.Text = DateTime.Now.ToString("HH:mm:ss") + "  " + text;
    }

    static string Fmt(TimeSpan ts)
    {
        if (ts <= TimeSpan.Zero) return "-";
        return string.Format("{0:00}:{1:00}:{2:00}", (int)ts.TotalHours, ts.Minutes, ts.Seconds);
    }

    void OnFormClosing(object sender, FormClosingEventArgs e)
    {
        if (!_reallyClosing && _cfg.MinimizeToTray && CountRunning() > 0 &&
            e.CloseReason == CloseReason.UserClosing)
        {
            e.Cancel = true;
            Hide();
            _tray.Visible = true;
            _tray.ShowBalloonTip(5000, "Steam Idler is still running",
                "Still idling " + CountRunning() + " game(s).\n" +
                "Run SteamIdler.exe again to bring this window back.",
                ToolTipIcon.Info);
            return;
        }

        _timer.Stop();
        foreach (var entry in _entries.Values)
        {
            if (entry.Running && entry.Confirmed)
            {
                entry.Accumulated += DateTime.UtcNow - entry.StartedUtc;
                _cfg.Totals[entry.Game.AppId] = entry.Accumulated;
            }
            Stop(entry);
        }

        SaveChecked();
        _cfg.Save();
        _tray.Visible = false;
    }

    // --------------------------------------------------- icon + single instance

    [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr handle);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int RegisterWindowMessage(string message);
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    static extern bool PostMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

    static readonly IntPtr HwndBroadcast = new IntPtr(0xFFFF);
    static readonly int ShowWindowMessage = RegisterWindowMessage("SteamIdler_RestoreWindow");

    static Icon _appIcon;
    static Icon AppIcon
    {
        get
        {
            if (_appIcon != null) return _appIcon;

            // Drawn at runtime so the repo needs no binary .ico asset. A generic
            // icon is impossible to pick out of the Windows 11 tray overflow.
            using (var bmp = new Bitmap(32, 32))
            {
                using (var g = Graphics.FromImage(bmp))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    g.Clear(Color.Transparent);
                    using (var bg = new SolidBrush(Color.FromArgb(23, 26, 33)))
                        g.FillEllipse(bg, 0, 0, 31, 31);
                    using (var pen = new Pen(Color.FromArgb(102, 192, 244), 3.2f))
                        g.DrawArc(pen, 5, 5, 21, 21, 40, 290);
                    using (var dot = new SolidBrush(Color.FromArgb(102, 192, 244)))
                        g.FillEllipse(dot, 14, 2, 7, 7);
                }

                IntPtr handle = bmp.GetHicon();
                try { _appIcon = (Icon)Icon.FromHandle(handle).Clone(); }
                finally { DestroyIcon(handle); }
            }

            return _appIcon;
        }
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == ShowWindowMessage && ShowWindowMessage != 0)
        {
            RestoreFromTray();
            return;
        }
        base.WndProc(ref m);
    }

    static void LogCrash(object error)
    {
        try
        {
            string path = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "SteamIdler.error.log");
            File.AppendAllText(path, DateTime.Now + Environment.NewLine + error + Environment.NewLine + Environment.NewLine);
        }
        catch { }
    }

    [STAThread]
    static void Main()
    {
        // Only one instance may run: a second copy would fight over the config
        // file and double up sessions. Launching the exe again instead restores
        // the window of the instance already running, which is the way back if
        // it is hiding in the tray.
        bool createdNew;
        using (var mutex = new Mutex(true, @"Local\SteamIdler_SingleInstance", out createdNew))
        {
            if (!createdNew)
            {
                if (ShowWindowMessage != 0)
                    PostMessage(HwndBroadcast, ShowWindowMessage, IntPtr.Zero, IntPtr.Zero);
                return;
            }

            AppDomain.CurrentDomain.UnhandledException += (s, e) => LogCrash(e.ExceptionObject);
            Application.ThreadException += (s, e) => LogCrash(e.Exception);

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            try { Application.Run(new MainForm()); }
            catch (Exception ex)
            {
                LogCrash(ex);
                MessageBox.Show("Steam Idler failed to start:\n\n" + ex.Message +
                    "\n\nDetails written to SteamIdler.error.log",
                    "Steam Idler", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }

            GC.KeepAlive(mutex);
        }
    }
}
