using System;
using System.Runtime.InteropServices;

namespace DI
{
    [StructLayout(LayoutKind.Sequential)]
    public struct AccentPolicy { public int AccentState; public int AccentFlags; public uint GradientColor; public int AnimationId; }

    [StructLayout(LayoutKind.Sequential)]
    public struct WinCompAttrData { public int Attribute; public IntPtr Data; public int SizeOfData; }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    public static class Native
    {
        [DllImport("user32.dll")] static extern int SetWindowCompositionAttribute(IntPtr hwnd, ref WinCompAttrData data);
        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll")] static extern int SetWindowRgn(IntPtr h, IntPtr rgn, bool redraw);
        [DllImport("gdi32.dll")] static extern IntPtr CreateRoundRectRgn(int l, int t, int r, int b, int w, int h);
        [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
        [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);
        [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
        [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
        [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
        [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
        [DllImport("user32.dll")] static extern uint RegisterClipboardFormat(string name);
        [DllImport("user32.dll")] static extern bool IsClipboardFormatAvailable(uint fmt);
        [DllImport("shell32.dll")] static extern int SHQueryUserNotificationState(out int state);
        [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
        [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);

        static uint excludeFmt = 0;

        // state: 0 = off, 3 = blur-behind, 4 = acrylic. Colors are ARGB in, converted to ABGR for DWM.
        public static int SetAccent(IntPtr hwnd, int state, byte a, byte r, byte g, byte b)
        {
            AccentPolicy ap = new AccentPolicy();
            ap.AccentState = state;
            ap.AccentFlags = 0;
            ap.GradientColor = ((uint)a << 24) | ((uint)b << 16) | ((uint)g << 8) | (uint)r;
            ap.AnimationId = 0;
            int size = Marshal.SizeOf(ap);
            IntPtr p = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(ap, p, false);
                WinCompAttrData d = new WinCompAttrData();
                d.Attribute = 19; // WCA_ACCENT_POLICY
                d.Data = p;
                d.SizeOfData = size;
                return SetWindowCompositionAttribute(hwnd, ref d);
            }
            finally { Marshal.FreeHGlobal(p); }
        }

        // WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE (+ optional WS_EX_TRANSPARENT = click-through)
        public static void ToolNoActivate(IntPtr hwnd, bool clickThrough)
        {
            int ex = GetWindowLong(hwnd, -20);
            ex |= 0x00000080 | 0x08000000;
            if (clickThrough) ex |= 0x00000020;
            SetWindowLong(hwnd, -20, ex);
        }

        // turn WS_EX_NOACTIVATE on / off (off = the window may take keyboard focus, used while typing a URL)
        public static void SetNoActivate(IntPtr hwnd, bool on)
        {
            int ex = GetWindowLong(hwnd, -20);
            if (on) ex |= 0x08000000; else ex &= ~0x08000000;
            SetWindowLong(hwnd, -20, ex);
        }
        public static IntPtr Foreground() { return GetForegroundWindow(); }
        public static void Foreground(IntPtr h)
        {
            try { if (h != IntPtr.Zero && IsWindow(h)) SetForegroundWindow(h); } catch { }
        }

        // Win11: no DWM rounding, no DWM border. Harmless no-op on Win10.
        public static void NoDwmDecor(IntPtr hwnd)
        {
            try
            {
                int v = 1;   // DWMWCP_DONOTROUND
                DwmSetWindowAttribute(hwnd, 33, ref v, 4);
                int none = unchecked((int)0xFFFFFFFE); // DWMWA_COLOR_NONE
                DwmSetWindowAttribute(hwnd, 34, ref none, 4);
            }
            catch { }
        }

        // Move + resize the glass window and clip it to a rounded rectangle (device pixels).
        public static void PlaceRounded(IntPtr hwnd, IntPtr after, int x, int y, int w, int h, int radius, bool show)
        {
            if (w < 2) w = 2;
            if (h < 2) h = 2;
            uint flags = 0x0010; // SWP_NOACTIVATE
            if (show) flags |= 0x0040; // SWP_SHOWWINDOW
            SetWindowPos(hwnd, after, x, y, w, h, flags);
            int d = radius * 2;
            if (d > h) d = h;
            if (d > w) d = w;
            IntPtr rgn = CreateRoundRectRgn(0, 0, w + 1, h + 1, d, d);
            SetWindowRgn(hwnd, rgn, true); // the system owns the region from here on
        }

        public static void KeepTopmost(IntPtr main, IntPtr glass)
        {
            IntPtr HWND_TOPMOST = new IntPtr(-1);
            SetWindowPos(main, HWND_TOPMOST, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010);   // NOSIZE|NOMOVE|NOACTIVATE
            if (glass != IntPtr.Zero)
                SetWindowPos(glass, main, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010);      // right below main
        }

        public static void Visible(IntPtr hwnd, bool show)
        {
            // SWP_NOSIZE|SWP_NOMOVE|SWP_NOZORDER|SWP_NOACTIVATE + SHOWWINDOW / HIDEWINDOW
            uint flags = 0x0001 | 0x0002 | 0x0004 | 0x0010;
            flags |= show ? (uint)0x0040 : (uint)0x0080;
            SetWindowPos(hwnd, IntPtr.Zero, 0, 0, 0, 0, flags);
        }

        public static void MediaKey(byte vk)
        {
            keybd_event(vk, 0, 0, UIntPtr.Zero);
            keybd_event(vk, 0, 2, UIntPtr.Zero);
        }

        public static int CursorX() { POINT p; GetCursorPos(out p); return p.X; }
        public static int CursorY() { POINT p; GetCursorPos(out p); return p.Y; }
        public static bool LeftDown() { return (GetAsyncKeyState(0x01) & 0x8000) != 0; }
        public static bool KeyDown(int vk) { return (GetAsyncKeyState(vk) & 0x8000) != 0; }

        // press a chord like Win+Shift+S : vks in order, held, released in reverse
        public static void Chord(byte[] vks)
        {
            for (int i = 0; i < vks.Length; i++) keybd_event(vks[i], 0, 0, UIntPtr.Zero);
            for (int i = vks.Length - 1; i >= 0; i--) keybd_event(vks[i], 0, 2, UIntPtr.Zero);
        }

        // true when a full-screen app / game / presentation owns the screen
        public static bool FullscreenBusy()
        {
            try
            {
                int s;
                if (SHQueryUserNotificationState(out s) != 0) return false;
                return s == 2 || s == 3 || s == 4;
            }
            catch { return false; }
        }

        // Password managers mark their clipboard content; we never record it.
        public static bool ClipboardIsExcluded()
        {
            try
            {
                if (excludeFmt == 0) excludeFmt = RegisterClipboardFormat("ExcludeClipboardContentFromMonitorProcessing");
                return excludeFmt != 0 && IsClipboardFormatAvailable(excludeFmt);
            }
            catch { return false; }
        }
    }

    // ---------------- master volume (Core Audio) ----------------
    [Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioEndpointVolume
    {
        [PreserveSig] int RegisterControlChangeNotify(IntPtr p);
        [PreserveSig] int UnregisterControlChangeNotify(IntPtr p);
        [PreserveSig] int GetChannelCount(out uint c);
        [PreserveSig] int SetMasterVolumeLevel(float l, ref Guid ctx);
        [PreserveSig] int SetMasterVolumeLevelScalar(float l, ref Guid ctx);
        [PreserveSig] int GetMasterVolumeLevel(out float l);
        [PreserveSig] int GetMasterVolumeLevelScalar(out float l);
        [PreserveSig] int SetChannelVolumeLevel(uint ch, float l, ref Guid ctx);
        [PreserveSig] int SetChannelVolumeLevelScalar(uint ch, float l, ref Guid ctx);
        [PreserveSig] int GetChannelVolumeLevel(uint ch, out float l);
        [PreserveSig] int GetChannelVolumeLevelScalar(uint ch, out float l);
        [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool m, ref Guid ctx);
        [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool m);
    }

    [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr pars, [MarshalAs(UnmanagedType.IUnknown)] out object ep);
    }

    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(int flow, int mask, out IntPtr devs);
        [PreserveSig] int GetDefaultAudioEndpoint(int flow, int role, out IMMDevice dev);
    }

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumeratorComObject { }

    public static class Vol
    {
        static IAudioEndpointVolume cached;
        static int cachedAt;

        static IAudioEndpointVolume Endpoint()
        {
            int now = Environment.TickCount;
            if (cached != null && unchecked(now - cachedAt) < 1500) return cached;
            Drop();
            IMMDeviceEnumerator en = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
            IMMDevice dev;
            Marshal.ThrowExceptionForHR(en.GetDefaultAudioEndpoint(0, 1, out dev));
            Guid iid = typeof(IAudioEndpointVolume).GUID;
            object epo;
            Marshal.ThrowExceptionForHR(dev.Activate(ref iid, 23, IntPtr.Zero, out epo));
            IAudioEndpointVolume ep = (IAudioEndpointVolume)epo;
            cached = ep;
            cachedAt = now;
            return ep;
        }

        static void Drop()
        {
            try { if (cached != null) Marshal.ReleaseComObject(cached); } catch { }
            cached = null;
        }

        public static string LastError = "";

        // 0..1, or -1 when no audio device
        public static float Get()
        {
            try { float v; Marshal.ThrowExceptionForHR(Endpoint().GetMasterVolumeLevelScalar(out v)); return v; }
            catch (Exception ex) { LastError = ex.Message; Drop(); return -1f; }
        }

        // volume 0..1 (or -1) plus mute flag in one COM round-trip
        public static float GetEx(out bool muted)
        {
            muted = false;
            try
            {
                IAudioEndpointVolume ep = Endpoint();
                float v;
                Marshal.ThrowExceptionForHR(ep.GetMasterVolumeLevelScalar(out v));
                bool m;
                if (ep.GetMute(out m) == 0) muted = m;
                return v;
            }
            catch (Exception ex) { LastError = ex.Message; Drop(); return -1f; }
        }

        public static bool Muted()
        {
            try { bool m; Marshal.ThrowExceptionForHR(Endpoint().GetMute(out m)); return m; }
            catch (Exception ex) { LastError = ex.Message; Drop(); return false; }
        }

        // returns 0 on success, otherwise an HRESULT-ish error code (the message is in LastError)
        public static int Set(float v)
        {
            for (int attempt = 0; attempt < 2; attempt++)
            {
                try
                {
                    if (v < 0f) v = 0f;
                    if (v > 1f) v = 1f;
                    Guid g = Guid.Empty;
                    int hr = Endpoint().SetMasterVolumeLevelScalar(v, ref g);
                    if (hr == 0) return 0;
                    LastError = "SetMasterVolumeLevelScalar hr=0x" + hr.ToString("X8");
                    Drop();
                }
                catch (Exception ex) { LastError = ex.Message; Drop(); }
            }
            return -1;
        }

        public static int SetMute(bool m)
        {
            for (int attempt = 0; attempt < 2; attempt++)
            {
                try
                {
                    Guid g = Guid.Empty;
                    int hr = Endpoint().SetMute(m, ref g);
                    if (hr == 0) return 0;
                    LastError = "SetMute hr=0x" + hr.ToString("X8");
                    Drop();
                }
                catch (Exception ex) { LastError = ex.Message; Drop(); }
            }
            return -1;
        }
    }


    // ---------------- per-application volume (Core Audio sessions) ----------------
    [Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionManager2
    {
        [PreserveSig] int GetAudioSessionControl(ref Guid g, uint flags, out IntPtr c);
        [PreserveSig] int GetSimpleAudioVolume(ref Guid g, uint flags, out IntPtr v);
        [PreserveSig] int GetSessionEnumerator(out IAudioSessionEnumerator e);
    }

    [Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionEnumerator
    {
        [PreserveSig] int GetCount(out int n);
        [PreserveSig] int GetSession(int i, [MarshalAs(UnmanagedType.IUnknown)] out object s);
    }

    [Guid("BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionControl2
    {
        [PreserveSig] int GetState(out int s);
        [PreserveSig] int GetDisplayName([MarshalAs(UnmanagedType.LPWStr)] out string n);
        [PreserveSig] int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)] string n, ref Guid c);
        [PreserveSig] int GetIconPath([MarshalAs(UnmanagedType.LPWStr)] out string p);
        [PreserveSig] int SetIconPath([MarshalAs(UnmanagedType.LPWStr)] string p, ref Guid c);
        [PreserveSig] int GetGroupingParam(out Guid g);
        [PreserveSig] int SetGroupingParam(ref Guid g, ref Guid c);
        [PreserveSig] int RegisterAudioSessionNotification(IntPtr p);
        [PreserveSig] int UnregisterAudioSessionNotification(IntPtr p);
        [PreserveSig] int GetSessionIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetSessionInstanceIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetProcessId(out uint pid);
        [PreserveSig] int IsSystemSoundsSession();
        [PreserveSig] int SetDuckingPreference([MarshalAs(UnmanagedType.Bool)] bool d);
    }

    [Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ISimpleAudioVolume
    {
        [PreserveSig] int SetMasterVolume(float v, ref Guid c);
        [PreserveSig] int GetMasterVolume(out float v);
        [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool m, ref Guid c);
        [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool m);
    }

    public class MixItem
    {
        public string Name;     // process name (grouped), or "" for system sounds
        public uint Pid;        // one of the pids
        public float Vol;
        public bool Muted;
        public bool Active;     // audio is playing right now
        public bool System;
    }

    public static class Mixer
    {
        public static string LastError = "";

        static IAudioSessionManager2 Manager()
        {
            IMMDeviceEnumerator en = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
            IMMDevice dev;
            Marshal.ThrowExceptionForHR(en.GetDefaultAudioEndpoint(0, 1, out dev));
            Guid iid = typeof(IAudioSessionManager2).GUID;
            object o;
            Marshal.ThrowExceptionForHR(dev.Activate(ref iid, 23, IntPtr.Zero, out o));
            return (IAudioSessionManager2)o;
        }

        static string ProcName(uint pid)
        {
            try { return System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; }
            catch { return ""; }
        }

        static System.Collections.Generic.List<object> Sessions()
        {
            System.Collections.Generic.List<object> res = new System.Collections.Generic.List<object>();
            IAudioSessionManager2 m = Manager();
            IAudioSessionEnumerator en;
            Marshal.ThrowExceptionForHR(m.GetSessionEnumerator(out en));
            int n;
            Marshal.ThrowExceptionForHR(en.GetCount(out n));
            for (int i = 0; i < n; i++)
            {
                object s;
                if (en.GetSession(i, out s) == 0 && s != null) res.Add(s);
            }
            return res;
        }

        // one row per application (all its sessions merged), sorted: playing first, then by name
        public static MixItem[] List()
        {
            try
            {
                System.Collections.Generic.Dictionary<string, MixItem> map = new System.Collections.Generic.Dictionary<string, MixItem>();
                System.Collections.Generic.List<MixItem> order = new System.Collections.Generic.List<MixItem>();
                foreach (object s in Sessions())
                {
                    try
                    {
                        IAudioSessionControl2 c = (IAudioSessionControl2)s;
                        ISimpleAudioVolume v = (ISimpleAudioVolume)s;
                        int st; c.GetState(out st);
                        if (st == 2) continue;   // expired
                        uint pid; c.GetProcessId(out pid);
                        bool sys = c.IsSystemSoundsSession() == 0;
                        string name = sys ? "" : ProcName(pid);
                        if (!sys && name.Length == 0) continue;
                        float vol; v.GetMasterVolume(out vol);
                        bool mu; v.GetMute(out mu);
                        string key = sys ? "\u0001sys" : name.ToLowerInvariant();
                        MixItem it;
                        if (!map.TryGetValue(key, out it))
                        {
                            it = new MixItem(); it.Name = name; it.Pid = pid; it.Vol = vol; it.Muted = mu; it.System = sys;
                            map[key] = it; order.Add(it);
                        }
                        else { if (vol > it.Vol) it.Vol = vol; if (!mu) it.Muted = false; }
                        if (st == 1) it.Active = true;
                    }
                    catch (Exception ex) { LastError = ex.Message; }
                }
                order.Sort(delegate(MixItem a, MixItem b)
                {
                    if (a.System != b.System) return a.System ? 1 : -1;
                    if (a.Active != b.Active) return a.Active ? -1 : 1;
                    return string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase);
                });
                return order.ToArray();
            }
            catch (Exception ex) { LastError = ex.Message; return new MixItem[0]; }
        }

        // name = process name ("" = system sounds). Applies to every session of that application.
        public static int SetVol(string name, float v)
        {
            return Apply(name, v, false, true);
        }
        public static int SetMute(string name, bool m)
        {
            return Apply(name, 0f, m, false);
        }

        static int Apply(string name, float vol, bool mute, bool isVol)
        {
            int hit = 0;
            try
            {
                if (vol < 0f) vol = 0f;
                if (vol > 1f) vol = 1f;
                Guid g = Guid.Empty;
                foreach (object s in Sessions())
                {
                    try
                    {
                        IAudioSessionControl2 c = (IAudioSessionControl2)s;
                        ISimpleAudioVolume sv = (ISimpleAudioVolume)s;
                        uint pid; c.GetProcessId(out pid);
                        bool sys = c.IsSystemSoundsSession() == 0;
                        bool match = (name.Length == 0) ? sys : (!sys && string.Equals(ProcName(pid), name, StringComparison.OrdinalIgnoreCase));
                        if (!match) continue;
                        int hr = isVol ? sv.SetMasterVolume(vol, ref g) : sv.SetMute(mute, ref g);
                        if (hr == 0) hit++;
                    }
                    catch (Exception ex) { LastError = ex.Message; }
                }
            }
            catch (Exception ex) { LastError = ex.Message; return -1; }
            return hit > 0 ? 0 : -2;
        }
    }

    // ---------------- screen snapshot -> blurred backdrop for the glass ----------------
    public static class Backdrop
    {
        [StructLayout(LayoutKind.Sequential)]
        struct BMIH
        {
            public int biSize; public int biWidth; public int biHeight; public short biPlanes; public short biBitCount;
            public int biCompression; public int biSizeImage; public int biXPelsPerMeter; public int biYPelsPerMeter;
            public int biClrUsed; public int biClrImportant;
        }

        [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
        [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
        [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
        [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleBitmap(IntPtr dc, int w, int h);
        [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr o);
        [DllImport("gdi32.dll")] static extern bool BitBlt(IntPtr dst, int x, int y, int w, int h, IntPtr src, int sx, int sy, uint rop);
        [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr o);
        [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
        [DllImport("gdi32.dll")] static extern int GetDIBits(IntPtr dc, IntPtr bmp, uint start, uint lines, byte[] bits, ref BMIH bi, uint usage);

        public static string LastError = "";

        // Grabs the screen rectangle (device pixels), hides the island's own pill (ix,iy,iw,ih are relative to the
        // rectangle; the pixels there are replaced by a horizontal gradient of their neighbours), shrinks it by
        // `down`, blurs it (3 box passes of `radius` small pixels) and boosts the saturation.
        // Returns BGRA bytes of the SMALL image (alpha = 255) or null.
        public static byte[] Snap(int sx, int sy, int w, int h, int down, int radius, float sat,
                                  int ix, int iy, int iw, int ih, out int ow, out int oh)
        {
            ow = 0; oh = 0;
            if (w < 8 || h < 8) return null;
            if (down < 1) down = 1;
            IntPtr sdc = IntPtr.Zero, mdc = IntPtr.Zero, bmp = IntPtr.Zero;
            try
            {
                sdc = GetDC(IntPtr.Zero);
                if (sdc == IntPtr.Zero) { LastError = "GetDC failed"; return null; }
                mdc = CreateCompatibleDC(sdc);
                bmp = CreateCompatibleBitmap(sdc, w, h);
                if (mdc == IntPtr.Zero || bmp == IntPtr.Zero) { LastError = "CreateCompatibleBitmap failed"; return null; }
                IntPtr old = SelectObject(mdc, bmp);
                bool ok = BitBlt(mdc, 0, 0, w, h, sdc, sx, sy, 0x00CC0020);   // SRCCOPY: layered windows (the island) are not captured
                SelectObject(mdc, old);
                if (!ok) { LastError = "BitBlt failed"; return null; }
                BMIH bi = new BMIH();
                bi.biSize = 40; bi.biWidth = w; bi.biHeight = -h; bi.biPlanes = 1; bi.biBitCount = 32; bi.biCompression = 0;
                byte[] buf = new byte[w * h * 4];
                int lines = GetDIBits(mdc, bmp, 0, (uint)h, buf, ref bi, 0);
                if (lines == 0) { LastError = "GetDIBits failed"; return null; }

                // inpaint the pill rectangle
                if (iw > 0 && ih > 0)
                {
                    int x0 = Math.Max(0, ix), x1 = Math.Min(w - 1, ix + iw);
                    int y0 = Math.Max(0, iy), y1 = Math.Min(h - 1, iy + ih);
                    int lx = Math.Max(0, x0 - 4), rx = Math.Min(w - 1, x1 + 4);
                    for (int y = y0; y <= y1; y++)
                    {
                        int lo = (y * w + lx) * 4, ro = (y * w + rx) * 4;
                        int span = Math.Max(1, x1 - x0);
                        for (int x = x0; x <= x1; x++)
                        {
                            int o = (y * w + x) * 4;
                            int t = x - x0;
                            for (int c = 0; c < 3; c++)
                                buf[o + c] = (byte)((buf[lo + c] * (span - t) + buf[ro + c] * t) / span);
                        }
                    }
                }

                ow = Math.Max(2, w / down); oh = Math.Max(2, h / down);
                float[] r = new float[ow * oh], g = new float[ow * oh], b = new float[ow * oh];
                int cnt = down * down;
                for (int y = 0; y < oh; y++)
                {
                    for (int x = 0; x < ow; x++)
                    {
                        int sr = 0, sg = 0, sb = 0;
                        for (int yy = 0; yy < down; yy++)
                        {
                            int o = ((y * down + yy) * w + x * down) * 4;
                            for (int xx = 0; xx < down; xx++)
                            {
                                sb += buf[o]; sg += buf[o + 1]; sr += buf[o + 2];
                                o += 4;
                            }
                        }
                        int k = y * ow + x;
                        r[k] = (float)sr / cnt; g[k] = (float)sg / cnt; b[k] = (float)sb / cnt;
                    }
                }
                float[] tmp = new float[ow * oh];
                for (int pass = 0; pass < 3; pass++)
                {
                    Blur(r, tmp, ow, oh, radius); Blur(g, tmp, ow, oh, radius); Blur(b, tmp, ow, oh, radius);
                }
                byte[] outb = new byte[ow * oh * 4];
                for (int k = 0; k < ow * oh; k++)
                {
                    float lum = 0.299f * r[k] + 0.587f * g[k] + 0.114f * b[k];
                    float rr = lum + (r[k] - lum) * sat, gg = lum + (g[k] - lum) * sat, bb = lum + (b[k] - lum) * sat;
                    outb[k * 4] = Clamp(bb); outb[k * 4 + 1] = Clamp(gg); outb[k * 4 + 2] = Clamp(rr); outb[k * 4 + 3] = 255;
                }
                return outb;
            }
            catch (Exception ex) { LastError = ex.Message; return null; }
            finally
            {
                if (bmp != IntPtr.Zero) DeleteObject(bmp);
                if (mdc != IntPtr.Zero) DeleteDC(mdc);
                if (sdc != IntPtr.Zero) ReleaseDC(IntPtr.Zero, sdc);
            }
        }

        static byte Clamp(float v) { return (byte)(v < 0f ? 0 : (v > 255f ? 255 : (int)(v + 0.5f))); }

        // one box-blur pass in both directions, edges replicated
        static void Blur(float[] a, float[] t, int w, int h, int r)
        {
            float inv = 1f / (2 * r + 1);
            for (int y = 0; y < h; y++)
            {
                int o = y * w;
                float sum = 0;
                for (int i = -r; i <= r; i++) sum += a[o + Math.Min(w - 1, Math.Max(0, i))];
                for (int x = 0; x < w; x++)
                {
                    t[o + x] = sum * inv;
                    sum += a[o + Math.Min(w - 1, x + r + 1)] - a[o + Math.Max(0, x - r)];
                }
            }
            for (int x = 0; x < w; x++)
            {
                float sum = 0;
                for (int i = -r; i <= r; i++) sum += t[Math.Min(h - 1, Math.Max(0, i)) * w + x];
                for (int y = 0; y < h; y++)
                {
                    a[y * w + x] = sum * inv;
                    sum += t[Math.Min(h - 1, y + r + 1) * w + x] - t[Math.Max(0, y - r) * w + x];
                }
            }
        }
    }

    // ---------------- CPU / RAM load ----------------
    public static class Sys
    {
        [StructLayout(LayoutKind.Sequential)]
        class MEMSTATUS
        {
            public uint dwLength; public uint dwMemoryLoad;
            public ulong ullTotalPhys; public ulong ullAvailPhys;
            public ulong ullTotalPageFile; public ulong ullAvailPageFile;
            public ulong ullTotalVirtual; public ulong ullAvailVirtual; public ulong ullAvailExtendedVirtual;
            public MEMSTATUS() { dwLength = (uint)Marshal.SizeOf(typeof(MEMSTATUS)); }
        }

        [DllImport("kernel32.dll")] static extern bool GetSystemTimes(out long idle, out long kernel, out long user);
        [DllImport("kernel32.dll")] static extern bool GlobalMemoryStatusEx([In, Out] MEMSTATUS s);

        static long pi, pk, pu;
        static bool has;

        // total CPU load 0..100 since the previous call (-1 on the first call)
        public static double Cpu()
        {
            long i, k, u;
            if (!GetSystemTimes(out i, out k, out u)) return -1;
            double r = -1;
            if (has)
            {
                long di = i - pi, dk = k - pk, du = u - pu;
                long tot = dk + du;
                if (tot > 0) r = 100.0 * (tot - di) / tot;
                if (r < 0) r = 0;
                if (r > 100) r = 100;
            }
            pi = i; pk = k; pu = u; has = true;
            return r;
        }

        public static bool Mem(out double usedGb, out double totalGb, out double pct)
        {
            usedGb = 0; totalGb = 0; pct = 0;
            MEMSTATUS m = new MEMSTATUS();
            if (!GlobalMemoryStatusEx(m)) return false;
            totalGb = m.ullTotalPhys / 1073741824.0;
            usedGb = (m.ullTotalPhys - m.ullAvailPhys) / 1073741824.0;
            pct = m.dwMemoryLoad;
            return true;
        }
    }
}
