using System.Windows;
using System.Windows.Automation.Peers;
using System.Windows.Controls;

namespace Dictation.App.Views;

/// <summary>
/// A small Japanese word beside a label, as decoration (the About page lists them all with their meaning). It is never
/// the only label for anything, so screen readers skip it: it has no automation peer.
/// </summary>
public class DecorText : TextBlock
{
    public DecorText()
    {
        SetResourceReference(StyleProperty, "Decor");
    }

    protected override AutomationPeer OnCreateAutomationPeer() => null!;
}

/// <summary>
/// A page's title as the instrument panel draws it: the name in large mono capitals, its decorative Japanese word in a
/// faint tone beside it, an optional readout on the right, and an ink rule underneath.
/// </summary>
public class PageHeader : StackPanel
{
    /// <summary>The page's name (shown in capitals).</summary>
    public string Title { get; set; } = "";
    /// <summary>The decorative Japanese word, or empty.</summary>
    public string Decor { get; set; } = "";
    /// <summary>Small text on the right, e.g. "SECTION A.1"; may hold a line break.</summary>
    public string Readout { get; set; } = "";

    TextBlock? _readout;

    public PageHeader()
    {
        Margin = new Thickness(0, 0, 0, 14);
    }

    /// <summary>Change the readout after the page has loaded.</summary>
    public void SetReadout(string text)
    {
        Readout = text;
        if (_readout != null) _readout.Text = text;
    }

    protected override void OnInitialized(EventArgs e)
    {
        base.OnInitialized(e);
        var row = new DockPanel { LastChildFill = false };

        _readout = new TextBlock
        {
            Text = Readout, TextAlignment = TextAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(16, 0, 0, 6),
        };
        _readout.SetResourceReference(StyleProperty, "MonoLabel");
        DockPanel.SetDock(_readout, Dock.Right);
        row.Children.Add(_readout);

        var title = new TextBlock { Text = Title.ToUpperInvariant(), TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(0) };
        title.SetResourceReference(StyleProperty, "SectionTitle");
        DockPanel.SetDock(title, Dock.Left);
        row.Children.Add(title);

        if (Decor.Length > 0)
        {
            var decor = new DecorText
            {
                Text = Decor, FontSize = 30, FontWeight = FontWeights.Bold, Margin = new Thickness(14, 0, 0, 2),
                VerticalAlignment = VerticalAlignment.Bottom,
            };
            decor.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Divider");
            DockPanel.SetDock(decor, Dock.Left);
            row.Children.Add(decor);
        }
        Children.Add(row);

        var rule = new Border { Margin = new Thickness(0, 6, 0, 0) };
        rule.SetResourceReference(StyleProperty, "Rule");
        Children.Add(rule);
    }
}
