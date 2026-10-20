using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using Dictation.Core.Infrastructure;
using Dictation.Core.Notes;
using Dictation.Core.Setup;

namespace Dictation.App.Views;

public partial class AboutPage : UserControl
{
    public AboutPage()
    {
        InitializeComponent();
        VersionText.Text = ($"{AppInfo.Name} {AppInfo.VersionText}" + (AppPaths.IsDevelopmentCopy ? "  // development copy" : "")).ToUpper();
        // The shortcuts the explanation mentions are the ones actually set
        var s = App.Services.Settings.Current;
        if (!string.IsNullOrEmpty(s.Hotkey)) DictateKey.Text = s.Hotkey;
        if (!string.IsNullOrEmpty(s.SpeakHotkey)) SpeakKey.Text = s.SpeakHotkey;
        // With the Japanese words turned off (Appearance) there is nothing for the glossary to explain.
        if (!s.ShowJapanese) GlossaryIntro.Visibility = Glossary.Visibility = Visibility.Collapsed;
        NotesTimelineBox.Child = NotesTimeline();
    }

    void Repo_Click(object sender, RoutedEventArgs e) =>
        Process.Start(new ProcessStartInfo(AppInfo.RepositoryUrl) { UseShellExecute = true });

    /// <summary>
    /// A 30-minute Extended Notes session on a time line, one lane per step: speech commits every ~5 s, formatting about
    /// every minute (110 words of steady speech), a summary section every ~6.5 minutes (6,000 characters), the first
    /// four section summaries folded into one, and the final summary at Stop. Drawn at a design size; the Viewbox scales it.
    /// </summary>
    FrameworkElement NotesTimeline()
    {
        const double W = 760, H = 196, X0 = 96, X1 = 740, Minutes = 30;
        double X(double min) => X0 + (X1 - X0) * min / Minutes;
        var mono = (FontFamily)FindResource("Ob.Mono");
        var c = new Canvas { Width = W, Height = H };

        TextBlock Text(string text, double x, double y, double size = 10, string brush = "Ob.Muted", bool bold = false)
        {
            var t = new TextBlock { Text = text, FontFamily = mono, FontSize = size, FontWeight = bold ? FontWeights.Bold : FontWeights.Normal };
            t.SetResourceReference(TextBlock.ForegroundProperty, brush);
            Canvas.SetLeft(t, x);
            Canvas.SetTop(t, y);
            c.Children.Add(t);
            return t;
        }
        Line Rule(double x1, double y1, double x2, double y2, string brush, double thick = 1, double opacity = 1)
        {
            var l = new Line { X1 = x1, Y1 = y1, X2 = x2, Y2 = y2, StrokeThickness = thick, Opacity = opacity };
            l.SetResourceReference(Shape.StrokeProperty, brush);
            c.Children.Add(l);
            return l;
        }
        Rectangle Box(double x, double y, double w, double h, string fill, double opacity = 1, string? stroke = null)
        {
            var r = new Rectangle { Width = Math.Max(1, w), Height = h, Opacity = opacity };
            r.SetResourceReference(Shape.FillProperty, fill);
            if (stroke != null) { r.StrokeThickness = 1; r.SetResourceReference(Shape.StrokeProperty, stroke); }
            Canvas.SetLeft(r, x);
            Canvas.SetTop(r, y);
            c.Children.Add(r);
            return r;
        }

        // Lanes
        double[] lane = { 14, 50, 86, 128 };
        string[] names = { "02 SPEECH", "03 FORMAT", "04 SUMMARY", "   LAYERS" };
        for (var i = 0; i < 4; i++)
        {
            Text(names[i], 0, lane[i] + 2, 10, "Ob.Text", bold: true);
            Rule(X0, lane[i] + 18, X1, lane[i] + 18, "Ob.Divider");
        }

        // 02 speech: a commit every 5 seconds
        for (var t = 5.0 / 60; t <= Minutes; t += 5.0 / 60) Rule(X(t), lane[0] + 4, X(t), lane[0] + 16, "Ob.Text", 0.6, 0.55);
        Text("a sentence every ~5 s", X(Minutes) - 128, lane[0] - 12, 9);

        // 03 format: about every minute of steady speech (110 words)
        for (var t = 0.8; t <= Minutes; t += 0.8) Box(X(t) - 3, lane[1] + 4, 6, 12, "Ob.Strong");
        Text("110 new words (~50 s of talk), or 90 s", X(Minutes) - 222, lane[1] - 12, 9);

        // 04 summary: a section every ~6.5 minutes, summed up as it closes; the last part waits for Stop
        double[] ends = { 6.5, 13, 19.5, 26 };
        var from = 0.0;
        for (var i = 0; i < ends.Length; i++)
        {
            Box(X(from) + 1, lane[2] + 4, X(ends[i]) - X(from) - 2, 12, "Ob.Subtle", 1, "Ob.Divider");
            Text($"§{i + 1}", X(from) + 5, lane[2] + 3, 9, "Ob.Text");
            Box(X(ends[i]) - 4, lane[2] + 6, 8, 8, "Ob.Strong");
            from = ends[i];
        }
        Box(X(from) + 1, lane[2] + 4, X(Minutes) - X(from) - 2, 12, "Ob.Subtle", 0.6, "Ob.Divider");
        Text("§5", X(from) + 5, lane[2] + 3, 9);
        Text($"~{NotesSummary.SectionChars:N0} characters each", X(Minutes) - 168, lane[2] - 12, 9);

        // Layers: the four summaries fold into one, then the final summary at Stop
        var merge = Box(X(0) + 1, lane[3] + 4, X(26) - X(0) - 2, 12, "Ob.Strong", 0.18, "Ob.Text");
        Text($"§1–4 folded into one ({NotesSummary.MergeCount} summaries → 1)", X(0) + 6, lane[3] + 3, 9, "Ob.Text");
        Box(X(26) - 4, lane[3] + 6, 8, 8, "Ob.Strong");
        var final = Box(X(Minutes) - 6, lane[3] + 2, 12, 16, "Ob.Accent");
        Text("FINAL AT STOP", X(Minutes) - 84, lane[3] + 22, 9, "Ob.Accent", bold: true);
        Text("main idea · 3 bullets · ≤ 3 paragraphs", X(Minutes) - 216, lane[3] + 34, 9, "Ob.Accent");

        // Time axis
        var axisY = H - 18;
        Rule(X0, axisY, X1, axisY, "Ob.Text");
        for (var m = 0; m <= Minutes; m += 5)
        {
            Rule(X(m), axisY, X(m), axisY + 4, "Ob.Text");
            var label = m == Minutes ? "30 MIN · STOP" : m.ToString();
            Text(label, m == Minutes ? X(m) - 76 : X(m) - 3, axisY + 4, 9);
        }
        return c;
    }
}
