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

    public static Icon CreateIcon()
    {
        using var bmp = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using (var bg = new SolidBrush(Color.FromArgb(255, 54, 120, 240))) g.FillEllipse(bg, 1, 1, 30, 30);
            using var white = new SolidBrush(Color.White);
            using var pen = new Pen(Color.White, 2.2f);
            g.FillRectangle(white, 12, 6, 8, 13);           // mic capsule
            g.FillEllipse(white, 12, 3, 8, 8);
            g.FillEllipse(white, 12, 14, 8, 8);
            g.DrawArc(pen, 9, 10, 14, 13, 10, 160);           // holder
            g.DrawLine(pen, 16, 23, 16, 27);
            g.DrawLine(pen, 12, 27, 20, 27);
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
        _icon = new NotifyIcon { Icon = CreateIcon(), Text = "Local Dictation", Visible = true, ContextMenuStrip = menu };
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
