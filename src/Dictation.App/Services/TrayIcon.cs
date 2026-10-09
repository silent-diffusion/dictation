using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;
using Dictation.Core.Settings;

namespace Dictation.App.Services;

public sealed class TrayIcon : IDisposable
{
    readonly NotifyIcon _icon;
    readonly ToolStripMenuItem _profilesMenu = new("Profile");
    readonly ProfileService _profiles;

    /// <summary>The Oberton mark: a red record light on a dark rounded square.</summary>
    public static Icon CreateIcon()
    {
        using var bmp = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using var square = new GraphicsPath();
            const int r = 10; // corner diameter: a near-square ink mark
            square.AddArc(1, 1, r, r, 180, 90);
            square.AddArc(31 - r, 1, r, r, 270, 90);
            square.AddArc(31 - r, 31 - r, r, r, 0, 90);
            square.AddArc(1, 31 - r, r, r, 90, 90);
            square.CloseFigure();
            using (var bg = new SolidBrush(Color.FromArgb(255, 0x0D, 0x0D, 0x0C))) g.FillPath(bg, square);
            using (var edge = new Pen(Color.FromArgb(70, 255, 255, 255), 1f)) g.DrawPath(edge, square); // visible on a dark taskbar
            using var dot = new SolidBrush(Color.FromArgb(255, 0xE8, 0xE7, 0xE3)); // paper: red is only for recording
            g.FillEllipse(dot, 10.5f, 10.5f, 11f, 11f);
        }
        return Icon.FromHandle(bmp.GetHicon());
    }

    public TrayIcon(ProfileService profiles, Action toggle, Action openSettings, Action checkUpdates, Action quit)
    {
        _profiles = profiles;
        var menu = new ContextMenuStrip();
        menu.Items.Add("Start / stop dictation", null, (_, _) => toggle());
        menu.Items.Add(_profilesMenu);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Open settings", null, (_, _) => openSettings());
        menu.Items.Add("Check for updates…", null, (_, _) => checkUpdates());
        menu.Items.Add("Quit", null, (_, _) => quit());
        menu.Opening += (_, _) => RebuildProfiles();
        _icon = new NotifyIcon { Icon = CreateIcon(), Text = Dictation.Core.Infrastructure.AppInfo.Name, Visible = true, ContextMenuStrip = menu };
        _icon.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) openSettings(); };
    }

    void RebuildProfiles()
    {
        _profilesMenu.DropDownItems.Clear();
        foreach (var p in _profiles.Profiles.ToList())
        {
            var item = new ToolStripMenuItem(p.Name) { Checked = p.IsActive };
            item.Click += (_, _) => _profiles.SetActive(p);
            _profilesMenu.DropDownItems.Add(item);
        }
    }

    public void SetTooltip(string text) => _icon.Text = text.Length > 60 ? text[..60] : text;

    public void Dispose()
    {
        _icon.Visible = false;
        _icon.Dispose();
    }
}
