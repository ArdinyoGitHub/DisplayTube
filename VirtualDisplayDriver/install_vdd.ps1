param([string]$DriverDir, [string]$Log)
Start-Transcript -Path $Log -Force | Out-Null
try {
    $inf = Join-Path $DriverDir 'MttVDD.inf'
    New-Item -ItemType Directory -Force 'C:\VirtualDisplayDriver' | Out-Null
    Copy-Item (Join-Path $DriverDir 'vdd_settings.xml') 'C:\VirtualDisplayDriver\vdd_settings.xml' -Force
    "settings copied"

    pnputil /add-driver $inf
    "pnputil exit: $LASTEXITCODE"

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class RootDev {
    [StructLayout(LayoutKind.Sequential)]
    public struct SP_DEVINFO_DATA { public int cbSize; public Guid ClassGuid; public int DevInst; public IntPtr Reserved; }
    [DllImport("setupapi.dll", SetLastError=true)]
    static extern IntPtr SetupDiCreateDeviceInfoList(ref Guid ClassGuid, IntPtr hwnd);
    [DllImport("setupapi.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern bool SetupDiCreateDeviceInfo(IntPtr set, string name, ref Guid cls, string desc, IntPtr hwnd, int flags, ref SP_DEVINFO_DATA data);
    [DllImport("setupapi.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern bool SetupDiSetDeviceRegistryProperty(IntPtr set, ref SP_DEVINFO_DATA data, int prop, byte[] buf, int size);
    [DllImport("setupapi.dll", SetLastError=true)]
    static extern bool SetupDiCallClassInstaller(int dif, IntPtr set, ref SP_DEVINFO_DATA data);
    [DllImport("setupapi.dll", SetLastError=true)]
    static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
    [DllImport("newdev.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern bool UpdateDriverForPlugAndPlayDevices(IntPtr hwnd, string hwid, string inf, int flags, out bool reboot);
    public static string Install(string inf, string hwid) {
        Guid cls = new Guid("4D36E968-E325-11CE-BFC1-08002BE10318");
        IntPtr set = SetupDiCreateDeviceInfoList(ref cls, IntPtr.Zero);
        SP_DEVINFO_DATA d = new SP_DEVINFO_DATA(); d.cbSize = Marshal.SizeOf(d);
        if (!SetupDiCreateDeviceInfo(set, "Display", ref cls, null, IntPtr.Zero, 1 /*DICD_GENERATE_ID*/, ref d))
            return "CreateDeviceInfo failed " + Marshal.GetLastWin32Error();
        byte[] ids = System.Text.Encoding.Unicode.GetBytes(hwid + "\0\0");
        if (!SetupDiSetDeviceRegistryProperty(set, ref d, 1 /*SPDRP_HARDWAREID*/, ids, ids.Length))
            return "SetHardwareId failed " + Marshal.GetLastWin32Error();
        if (!SetupDiCallClassInstaller(0x19 /*DIF_REGISTERDEVICE*/, set, ref d))
            return "RegisterDevice failed " + Marshal.GetLastWin32Error();
        SetupDiDestroyDeviceInfoList(set);
        bool reboot;
        if (!UpdateDriverForPlugAndPlayDevices(IntPtr.Zero, hwid, inf, 1 /*INSTALLFLAG_FORCE*/, out reboot))
            return "UpdateDriver failed " + Marshal.GetLastWin32Error();
        return "OK reboot=" + reboot;
    }
}
'@
    $existing = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Where-Object { $_.HardwareID -contains 'Root\MttVDD' }
    if ($existing) { "device already exists: $($existing.InstanceId) $($existing.Status)" }
    else { "root device: " + [RootDev]::Install($inf, 'Root\MttVDD') }
} catch { "ERROR: $_" }
Stop-Transcript | Out-Null
