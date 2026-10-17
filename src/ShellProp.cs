using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

public static class ShellProp {
  public static System.Collections.Generic.Dictionary<string, long> Index(string dir) {   // file name -> last-write ticks, one enumeration (fast; PowerShell per-file calls were not)
    var d = new System.Collections.Generic.Dictionary<string, long>();
    foreach (var f in new System.IO.DirectoryInfo(dir).EnumerateFiles("local_*.json")) d[f.Name] = f.LastWriteTimeUtc.Ticks;
    return d;
  }
  [StructLayout(LayoutKind.Sequential, Pack = 4)]
  public struct PROPERTYKEY { public Guid fmtid; public uint pid; }
  [StructLayout(LayoutKind.Explicit)]
  public struct PROPVARIANT { [FieldOffset(0)] public ushort vt; [FieldOffset(8)] public IntPtr p; [FieldOffset(16)] public IntPtr p2; }
  [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IPropertyStore {
    [PreserveSig] int GetCount(out uint c);
    [PreserveSig] int GetAt(uint i, out PROPERTYKEY k);
    [PreserveSig] int GetValue(ref PROPERTYKEY k, out PROPVARIANT v);
    [PreserveSig] int SetValue(ref PROPERTYKEY k, ref PROPVARIANT v);
    [PreserveSig] int Commit();
  }
  [DllImport("shell32.dll")] static extern int SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid riid, out IPropertyStore ps);
  [DllImport("propsys.dll", CharSet = CharSet.Unicode)] static extern int PropVariantToStringAlloc(ref PROPVARIANT pv, out IntPtr s);
  [DllImport("ole32.dll")] static extern int PropVariantClear(ref PROPVARIANT pv);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool SetWindowText(IntPtr h, string title);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr LoadImage(IntPtr hi, string f, uint t, int cx, int cy, uint fl);

  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [StructLayout(LayoutKind.Sequential)] struct LII { public uint cbSize; public uint dwTime; }
  [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LII p);
  public static uint IdleSeconds() { LII l = new LII(); l.cbSize = (uint)Marshal.SizeOf(typeof(LII)); if (!GetLastInputInfo(ref l)) return 0; return (uint)(((uint)Environment.TickCount - l.dwTime) / 1000); }
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  public static bool IsVisibleNotMinimized(IntPtr h) { return IsWindowVisible(h) && !IsIconic(h); }
  public static void Restore(IntPtr h) { ShowWindow(h, 9); }                         // SW_RESTORE
  public static void MinimizeNoActivate(IntPtr h) { ShowWindow(h, 7); }            // SW_SHOWMINNOACTIVE
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct STARTUPINFO { public int cb; public string lpReserved, lpDesktop, lpTitle; public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
    public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError; }
  [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  static extern bool CreateProcessW(string app, string cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  // starts a program with its first window minimised and NOT activated (nothing steals the focus)
  public static int StartMinNoActivate(string exe, string args) {
    STARTUPINFO si = new STARTUPINFO(); si.cb = Marshal.SizeOf(typeof(STARTUPINFO)); si.dwFlags = 1; si.wShowWindow = 7;
    PROCESS_INFORMATION pi;
    if (!CreateProcessW(null, "\"" + exe + "\" " + args, IntPtr.Zero, IntPtr.Zero, false, 0, IntPtr.Zero, null, ref si, out pi)) return -1;
    CloseHandle(pi.hProcess); CloseHandle(pi.hThread); return pi.dwProcessId;
  }
  public static IntPtr ForegroundWindow() { return GetForegroundWindow(); }
  public static bool Foreground(IntPtr h) {          // the ALT tap lets a background process take the foreground
    if (IsIconic(h)) ShowWindow(h, 9);
    keybd_event(0x12, 0, 0, UIntPtr.Zero); bool ok = SetForegroundWindow(h); keybd_event(0x12, 0, 2, UIntPtr.Zero); return ok;
  }
  public static uint ForegroundPid() { uint p; GetWindowThreadProcessId(GetForegroundWindow(), out p); return p; }

  static readonly Guid FMT = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
  static PROPERTYKEY K(uint pid) { var k = new PROPERTYKEY(); k.fmtid = FMT; k.pid = pid; return k; }

  static void Put(IPropertyStore ps, uint pid, string val) {
    var k = K(pid); PROPVARIANT v;
    v = new PROPVARIANT(); v.vt = 31; v.p = Marshal.StringToCoTaskMemUni(val);
    Marshal.ThrowExceptionForHR(ps.SetValue(ref k, ref v));
    PropVariantClear(ref v);
  }
  static string Get(IPropertyStore ps, uint pid) {
    var k = K(pid); PROPVARIANT v;
    if (ps.GetValue(ref k, out v) != 0 || v.vt == 0) return null;
    IntPtr s; PropVariantToStringAlloc(ref v, out s);
    string r = Marshal.PtrToStringUni(s); Marshal.FreeCoTaskMem(s); PropVariantClear(ref v);
    return r;
  }

  // Window-level taskbar identity (overrides the process-level AUMID Electron sets).
  public static string SetWindowIdentity(IntPtr hwnd, string aumid, string relaunchCmd, string iconRes, string name) {
    Guid iid = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
    IPropertyStore ps;
    Marshal.ThrowExceptionForHR(SHGetPropertyStoreForWindow(hwnd, ref iid, out ps));
    Put(ps, 5, aumid);
    Put(ps, 2, relaunchCmd);
    Put(ps, 3, iconRes);
    Put(ps, 4, name);
    return Get(ps, 5);
  }
  public static string GetWindowAumid(IntPtr hwnd) {
    Guid iid = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
    IPropertyStore ps;
    if (SHGetPropertyStoreForWindow(hwnd, ref iid, out ps) != 0) return null;
    return Get(ps, 5);
  }
  public static void SetWindowIcon(IntPtr hwnd, string ico) {
    IntPtr big = LoadImage(IntPtr.Zero, ico, 1, 32, 32, 0x10);
    IntPtr small = LoadImage(IntPtr.Zero, ico, 1, 16, 16, 0x10);
    SendMessage(hwnd, 0x80, (IntPtr)1, big);
    SendMessage(hwnd, 0x80, (IntPtr)0, small);
  }

  // Stamp an AUMID onto a .lnk (IPropertyStore on the ShellLink object).
  public static void SetLinkAumid(string lnk, string aumid) {
    var t = Type.GetTypeFromCLSID(new Guid("00021401-0000-0000-C000-000000000046"));
    object o = Activator.CreateInstance(t);
    var pf = (IPersistFile)o;
    pf.Load(lnk, 2);
    var ps = (IPropertyStore)o;
    Put(ps, 5, aumid);
    Marshal.ThrowExceptionForHR(ps.Commit());
    pf.Save(lnk, true);
  }
  public static string GetLinkAumid(string lnk) {
    var t = Type.GetTypeFromCLSID(new Guid("00021401-0000-0000-C000-000000000046"));
    object o = Activator.CreateInstance(t);
    ((IPersistFile)o).Load(lnk, 0);
    return Get((IPropertyStore)o, 5);
  }
}

// Minimal read-only SQLite access through the winsqlite3.dll that ships with Windows 10/11 (no python / sqlite3.exe needed).
public static class WinSqlite {
  const string L = "winsqlite3.dll";
  [DllImport(L, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_open_v2(byte[] filename, out IntPtr db, int flags, IntPtr vfs);
  [DllImport(L, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_close(IntPtr db);
  [DllImport(L, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int n, out IntPtr stmt, IntPtr tail);
  [DllImport(L, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_step(IntPtr stmt);
  [DllImport(L, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_column_count(IntPtr stmt);
  [DllImport(L, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr sqlite3_column_text(IntPtr stmt, int i);
  [DllImport(L, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr sqlite3_column_name(IntPtr stmt, int i);
  [DllImport(L, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_finalize(IntPtr stmt);

  static string Utf8(IntPtr p) {
    if (p == IntPtr.Zero) return null;
    int n = 0; while (Marshal.ReadByte(p, n) != 0) n++;
    byte[] b = new byte[n]; Marshal.Copy(p, b, 0, n); return System.Text.Encoding.UTF8.GetString(b);
  }
  static byte[] Z(string s) { return System.Text.Encoding.UTF8.GetBytes(s + "\0"); }

  public static System.Collections.Generic.List<System.Collections.Generic.Dictionary<string, string>> Query(string path, string sql) {
    var rows = new System.Collections.Generic.List<System.Collections.Generic.Dictionary<string, string>>();
    IntPtr db;
    string uri = new Uri(path).AbsoluteUri;                               // file:///C:/... (percent-encoded)
    if (sqlite3_open_v2(Z(uri), out db, 0x01 | 0x40, IntPtr.Zero) != 0) { if (db != IntPtr.Zero) sqlite3_close(db); throw new Exception("cannot open " + path); }
    try {
      IntPtr st;
      if (sqlite3_prepare_v2(db, Z(sql), -1, out st, IntPtr.Zero) != 0) throw new Exception("bad sql");
      try {
        int n = sqlite3_column_count(st);
        while (sqlite3_step(st) == 100) {
          var r = new System.Collections.Generic.Dictionary<string, string>();
          for (int i = 0; i < n; i++) r[Utf8(sqlite3_column_name(st, i))] = Utf8(sqlite3_column_text(st, i));
          rows.Add(r);
        }
      } finally { sqlite3_finalize(st); }
    } finally { sqlite3_close(db); }
    return rows;
  }
}

// Re-skins the notification-area (tray) icon that an Electron window of another process owns.
public static class TrayIcon {
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr LoadImage(IntPtr hi, string f, uint t, int cx, int cy, uint fl);
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct NID { public int cbSize; public IntPtr hWnd; public uint uID; public uint uFlags; public uint uCallbackMessage; public IntPtr hIcon;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szTip; public uint dwState; public uint dwStateMask;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string szInfo; public uint uTimeoutOrVersion;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string szInfoTitle; public uint dwInfoFlags; public Guid guidItem; public IntPtr hBalloonIcon; }
  [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern bool Shell_NotifyIconW(uint msg, ref NID d);
  static System.Collections.Generic.Dictionary<string, IntPtr> cache = new System.Collections.Generic.Dictionary<string, IntPtr>();

  public static int Apply(uint pid, string ico, string tip) {
    IntPtr icon;
    if (!cache.TryGetValue(ico, out icon)) { int s = GetSystemMetrics(49); icon = LoadImage(IntPtr.Zero, ico, 1, s, s, 0x10); cache[ico] = icon; }
    if (icon == IntPtr.Zero) return 0;
    int done = 0;
    EnumWindows((h, l) => {
      uint p; GetWindowThreadProcessId(h, out p); if (p != pid) return true;
      var sb = new System.Text.StringBuilder(64); GetClassName(h, sb, 64); if (sb.ToString() != "Electron_NotifyIconHostWindow") return true;
      for (uint id = 0; id <= 16; id++) {
        var n = new NID(); n.cbSize = Marshal.SizeOf(typeof(NID)); n.hWnd = h; n.uID = id; n.uFlags = 2 | 4; n.hIcon = icon; n.szTip = tip;
        if (Shell_NotifyIconW(1, ref n)) done++;
      }
      return true;
    }, IntPtr.Zero);
    return done;
  }
}
