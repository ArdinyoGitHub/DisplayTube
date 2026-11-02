using System.Text.Json;

namespace DisplayTube.App;

/// Kullanici ayarlari: %APPDATA%\DisplayTube\settings.json
sealed class Settings
{
    /// "phone" (telefon oranina gore), "keep" (degistirme) ya da "1920x1080" gibi sabit boyut.
    public string Resolution { get; set; } = "phone";
    public int Fps { get; set; } = 60;
    public int Bitrate { get; set; } = 12_000_000;
    /// Uygulama acilinca yayini hemen baslat.
    public bool StartStreamOnLaunch { get; set; } = true;
    /// Kullanici adb'nin Google'dan indirilmesine izin verdi mi.
    public bool AdbDownloadAllowed { get; set; }

    public static string Dir => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "DisplayTube");
    static string FilePath => Path.Combine(Dir, "settings.json");

    public static Settings Load()
    {
        try
        {
            if (File.Exists(FilePath))
                return JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath)) ?? new Settings();
        }
        catch { }
        return new Settings();
    }

    public void Save()
    {
        Directory.CreateDirectory(Dir);
        File.WriteAllText(FilePath, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
    }
}

/// Basit dosya gunlugu: %APPDATA%\DisplayTube\log.txt
static class AppLog
{
    static readonly object gate = new();
    public static string FilePath => Path.Combine(Settings.Dir, "log.txt");

    public static void Write(string line)
    {
        lock (gate)
        {
            try
            {
                Directory.CreateDirectory(Settings.Dir);
                var fi = new FileInfo(FilePath);
                if (fi.Exists && fi.Length > 2_000_000) fi.Delete();
                File.AppendAllText(FilePath, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {line}{Environment.NewLine}");
            }
            catch { }
        }
    }
}

/// Arayuz metinleri. Varsayilan dil Ingilizce; Turkce yalnizca kurulum programinda secildiyse
/// kullanilir. Kurulum, secilen dili exe'nin yanindaki language.txt dosyasina ("en" ya da "tr") yazar.
static class T
{
    static readonly bool tr = ReadLanguage() == "tr";
    public static string S(string turkish, string english) => tr ? turkish : english;

    static string ReadLanguage()
    {
        try
        {
            string f = Path.Combine(AppContext.BaseDirectory, "language.txt");
            return File.Exists(f) ? File.ReadAllText(f).Trim().ToLowerInvariant() : "en";
        }
        catch { return "en"; }
    }
}
