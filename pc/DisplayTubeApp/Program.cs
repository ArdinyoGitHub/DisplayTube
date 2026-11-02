using System.Drawing.Drawing2D;
using Microsoft.Win32;

namespace DisplayTube.App;

static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        // Yakalama motoru modu (StreamController bunu alt surec olarak baslatir)
        if (args.Length > 0 && args[0] == "--engine")
            return DisplayTube.Program.Main(args[1..]);

        // Yonetici olarak yeniden baslatilan surucu kurulum modu
        if (args.Length == 2 && args[0] == "--install-driver")
            return VirtualDisplay.InstallAsAdmin(args[1]);

        using var mutex = new Mutex(true, "DisplayTube.App.SingleInstance", out bool first);
        if (!first) return 0;   // zaten calisiyor

        ApplicationConfiguration.Initialize();
        Application.Run(new TrayApp());
        return 0;
    }
}

/// Bildirim alani simgesi ve menusu.
sealed class TrayApp : ApplicationContext
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string RunValue = "DisplayTube";

    readonly NotifyIcon tray;
    readonly Settings settings = Settings.Load();
    readonly StreamController controller;
    readonly SynchronizationContext ui;
    readonly ToolStripMenuItem statusItem, detailItem, startStopItem, autostartItem, resolutionMenu;
    readonly Icon iconIdle, iconActive;
    bool lastClient;

    public TrayApp()
    {
        ui = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();
        iconIdle = MakeIcon(Color.FromArgb(120, 120, 120));
        iconActive = MakeIcon(Color.FromArgb(0, 150, 255));
        controller = new StreamController(settings, Confirm);
        controller.Changed += () => ui.Post(_ => Refresh(), null);

        statusItem = new ToolStripMenuItem("DisplayTube") { Enabled = false };
        detailItem = new ToolStripMenuItem("") { Enabled = false, Visible = false };
        startStopItem = new ToolStripMenuItem("", null, (_, _) => ToggleStream());
        resolutionMenu = new ToolStripMenuItem(T.S("Cozunurluk", "Resolution"));
        foreach (var (key, text) in new[]
        {
            ("phone", T.S("Telefona gore (otomatik)", "Match phone (auto)")),
            ("keep", T.S("Degistirme (Windows ayari)", "Don't change (Windows setting)")),
            ("1920x1080", "1920 x 1080"),
            ("2560x1440", "2560 x 1440"),
        })
        {
            var item = new ToolStripMenuItem(text) { Tag = key, Checked = settings.Resolution == key };
            item.Click += (_, _) => SetResolution(key);
            resolutionMenu.DropDownItems.Add(item);
        }
        autostartItem = new ToolStripMenuItem(T.S("Windows acilisinda baslat", "Start with Windows"), null, (_, _) => ToggleAutostart())
        { Checked = IsAutostart() };

        var menu = new ContextMenuStrip();
        menu.Items.AddRange(new ToolStripItem[]
        {
            statusItem, detailItem, new ToolStripSeparator(),
            startStopItem, resolutionMenu, autostartItem, new ToolStripSeparator(),
            new ToolStripMenuItem(T.S("Gunlugu ac", "Open log"), null, (_, _) => OpenLog()),
            new ToolStripMenuItem(T.S("Cikis", "Exit"), null, (_, _) => Exit()),
        });

        tray = new NotifyIcon { Icon = iconIdle, ContextMenuStrip = menu, Visible = true, Text = "DisplayTube" };
        tray.DoubleClick += (_, _) => ToggleStream();
        Refresh();
        AppLog.Write("DisplayTube basladi");
        if (settings.StartStreamOnLaunch) controller.Start();
        else VirtualDisplay.Detach();   // onceki oturum cokerse acik kalan bos sanal ekrani kapat
    }

    void ToggleStream()
    {
        if (controller.IsRunning) { controller.Stop(); settings.StartStreamOnLaunch = false; }
        else { controller.Start(); settings.StartStreamOnLaunch = true; }
        settings.Save();
        Refresh();
    }

    void SetResolution(string key)
    {
        settings.Resolution = key;
        settings.Save();
        foreach (ToolStripMenuItem i in resolutionMenu.DropDownItems) i.Checked = (string)i.Tag! == key;
        controller.ResolutionChanged();
    }

    void Refresh()
    {
        StreamStatus s;
        lock (controller.Status) s = new StreamStatus
        {
            Phase = controller.Status.Phase, PhoneConnected = controller.Status.PhoneConnected,
            ClientConnected = controller.Status.ClientConnected, Encoder = controller.Status.Encoder,
            Size = controller.Status.Size, Message = controller.Status.Message, Fps = controller.Status.Fps
        };

        string state = s.Phase switch
        {
            Phase.Stopped => T.S("Durduruldu", "Stopped"),
            Phase.Preparing => T.S("Hazirlaniyor", "Preparing"),
            Phase.WaitingForPhone => s.PhoneConnected ? T.S("Telefon bagli, uygulama bekleniyor", "Phone connected, waiting for app")
                                                      : T.S("Telefon bekleniyor", "Waiting for phone"),
            Phase.Streaming => T.S("Yayinda", "Streaming") + (s.Fps > 0 ? $" - {s.Fps:F0} FPS" : ""),
            Phase.Error => T.S("Hata", "Error"),
            _ => ""
        };
        statusItem.Text = "DisplayTube: " + state;
        string detail = s.Message ?? (s.Phase == Phase.Streaming ? $"{s.Size} - {s.Encoder}" : "");
        detailItem.Text = detail;
        detailItem.Visible = detail.Length > 0;
        startStopItem.Text = controller.IsRunning ? T.S("Durdur", "Stop") : T.S("Baslat", "Start");
        tray.Icon = s.ClientConnected ? iconActive : iconIdle;
        string tip = "DisplayTube - " + state;
        tray.Text = tip.Length > 63 ? tip[..63] : tip;

        if (s.ClientConnected && !lastClient)
            tray.ShowBalloonTip(2000, "DisplayTube", T.S("Telefon ekran olarak bagli", "Phone connected as a display"), ToolTipIcon.Info);
        if (s.Phase == Phase.Error && s.Message != null)
            tray.ShowBalloonTip(5000, "DisplayTube", s.Message, ToolTipIcon.Warning);
        lastClient = s.ClientConnected;
    }

    bool Confirm(string title, string text)
    {
        bool result = false;
        ui.Send(_ => result = MessageBox.Show(text, "DisplayTube - " + title, MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes, null);
        return result;
    }

    static bool IsAutostart()
    {
        using var k = Registry.CurrentUser.OpenSubKey(RunKey);
        return k?.GetValue(RunValue) != null;
    }

    void ToggleAutostart()
    {
        using var k = Registry.CurrentUser.CreateSubKey(RunKey);
        if (IsAutostart()) k.DeleteValue(RunValue, false);
        else k.SetValue(RunValue, $"\"{Environment.ProcessPath}\"");
        autostartItem.Checked = IsAutostart();
    }

    static void OpenLog()
    {
        if (File.Exists(AppLog.FilePath))
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(AppLog.FilePath) { UseShellExecute = true });
    }

    void Exit()
    {
        controller.Stop();
        tray.Visible = false;
        tray.Dispose();
        ExitThread();
    }

    /// Basit simge: kenarligi renkli, yatay bir telefon.
    static Icon MakeIcon(Color color)
    {
        using var bmp = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using var path = Rounded(new Rectangle(2, 7, 28, 18), 4);
            using var fill = new SolidBrush(color);
            g.FillPath(fill, path);
            using var screen = new SolidBrush(Color.White);
            g.FillRectangle(screen, 6, 10, 20, 12);
            using var dot = new SolidBrush(color);
            g.FillEllipse(dot, 13, 13, 6, 6);
        }
        return Icon.FromHandle(bmp.GetHicon());
    }

    static GraphicsPath Rounded(Rectangle r, int radius)
    {
        var p = new GraphicsPath();
        int d = radius * 2;
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }
}
