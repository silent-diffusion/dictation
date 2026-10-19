using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;

namespace Dictation.App.Views;

/// <summary>
/// The top of Extended Notes: its own signal path, drawn like the dashboard's. What it listens to → the speech model →
/// the AI model formatting → the AI model summing up, each with its model and what it is doing. A step lights in the
/// accent, its core pulsing, while it is at work (listening, formatting, summing up); hollow while it is off. Built once
/// and updated in place (<see cref="Update"/>), so the pulse runs smoothly.
/// </summary>
sealed class NotesPipeline
{
    public enum State { Ready, Busy, Off }

    /// <summary>A step: its label, its model or source, what it is doing, and its state.</summary>
    public readonly record struct Step(string Label, string Title, string Status, State State);

    const double Width = 1000, Height = 118, Y = 46, Radius = 15, ColumnWidth = 250;

    sealed class Parts
    {
        public required Ellipse Ring, Core;
        public required TextBlock Label, Title, Status;
        public State? Shown;
    }

    readonly Parts[] _parts = new Parts[4];
    readonly Storyboard?[] _pulses = new Storyboard?[4];

    /// <summary>The drawing, scaled to the width it is given.</summary>
    public FrameworkElement View { get; }

    /// <param name="open">What a click on each step opens (or null).</param>
    public NotesPipeline(Action?[] open)
    {
        var mono = (FontFamily)Application.Current.FindResource("Ob.Mono");
        var c = new Canvas { Width = Width, Height = Height };
        double X(int i) => ColumnWidth / 2 + i * ColumnWidth;
        var line = new Line { X1 = X(0), Y1 = Y, X2 = X(3), Y2 = Y, StrokeThickness = 1 };
        line.SetResourceReference(Shape.StrokeProperty, "Ob.Text");
        c.Children.Add(line);
        for (var i = 0; i < 3; i++)
        {
            var mid = (X(i) + X(i + 1)) / 2;
            var arrow = new Polyline { Points = new PointCollection { new(mid - 3, Y - 4), new(mid + 3, Y), new(mid - 3, Y + 4) }, StrokeThickness = 1 };
            arrow.SetResourceReference(Shape.StrokeProperty, "Ob.Text");
            c.Children.Add(arrow);
        }
        for (var i = 0; i < 4; i++)
        {
            var col = new Grid { Width = ColumnWidth, Height = Height, Background = Brushes.Transparent };
            var label = new TextBlock { FontFamily = mono, FontSize = 13, FontWeight = FontWeights.Bold, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top };
            label.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Text");
            col.Children.Add(label);
            var ring = new Ellipse { Width = Radius * 2, Height = Radius * 2, StrokeThickness = 1, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, Y - Radius, 0, 0) };
            ring.SetResourceReference(Shape.FillProperty, "Ob.Window");
            col.Children.Add(ring);
            var core = new Ellipse { Width = 9, Height = 9, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, Y - 4.5, 0, 0) };
            col.Children.Add(core);
            var below = new StackPanel { VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, Y + Radius + 7, 0, 0) };
            var title = new TextBlock { FontFamily = mono, FontSize = 12.5, HorizontalAlignment = HorizontalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = ColumnWidth - 12 };
            title.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Text");
            var status = new TextBlock { FontFamily = mono, FontSize = 11.5, HorizontalAlignment = HorizontalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = ColumnWidth - 12, Margin = new Thickness(0, 2, 0, 0) };
            below.Children.Add(title);
            below.Children.Add(status);
            col.Children.Add(below);
            if (open[i] is { } go)
            {
                col.Cursor = Cursors.Hand;
                col.MouseEnter += (_, _) => col.SetResourceReference(Panel.BackgroundProperty, "Ob.AccentWash");
                col.MouseLeave += (_, _) => col.Background = Brushes.Transparent;
                col.MouseLeftButtonUp += (_, e) => { e.Handled = true; go(); };
            }
            Canvas.SetLeft(col, X(i) - ColumnWidth / 2);
            c.Children.Add(col);
            _parts[i] = new Parts { Ring = ring, Core = core, Label = label, Title = title, Status = status };
        }
        View = new Viewbox { Stretch = Stretch.Uniform, StretchDirection = StretchDirection.Both, MaxHeight = 150, Child = c, HorizontalAlignment = HorizontalAlignment.Left };
    }

    public void Update(IReadOnlyList<Step> steps)
    {
        for (var i = 0; i < _parts.Length && i < steps.Count; i++)
        {
            var (p, s) = (_parts[i], steps[i]);
            p.Label.Text = s.Label;
            p.Title.Text = s.Title.ToUpperInvariant();
            p.Status.Text = s.Status.ToUpperInvariant();
            ((FrameworkElement)p.Label.Parent).ToolTip = $"{s.Label}: {s.Title} · {s.Status}";
            if (p.Shown == s.State) continue;
            p.Shown = s.State;
            var key = s.State == State.Busy ? "Ob.Accent" : "Ob.Text";
            p.Ring.SetResourceReference(Shape.StrokeProperty, key);
            p.Status.SetResourceReference(TextBlock.ForegroundProperty, s.State == State.Busy ? "Ob.Accent" : "Ob.Muted");
            _pulses[i]?.Stop(p.Core);
            _pulses[i] = null;
            p.Core.Opacity = 1;
            if (s.State == State.Off)
            {
                p.Core.Fill = Brushes.Transparent;
                p.Core.StrokeThickness = 1;
                p.Core.SetResourceReference(Shape.StrokeProperty, "Ob.Muted");
                continue;
            }
            p.Core.StrokeThickness = 0;
            p.Core.SetResourceReference(Shape.FillProperty, s.State == State.Busy ? "Ob.Accent" : "Ob.Strong");
            if (s.State == State.Busy)
            {
                // At work: the core breathes, so it reads as live even when the words don't change.
                var pulse = new DoubleAnimation(1, 0.25, TimeSpan.FromSeconds(0.8)) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever };
                Storyboard.SetTarget(pulse, p.Core);
                Storyboard.SetTargetProperty(pulse, new PropertyPath(UIElement.OpacityProperty));
                var sb = new Storyboard();
                sb.Children.Add(pulse);
                sb.Begin(p.Core, true);
                _pulses[i] = sb;
            }
        }
    }
}
