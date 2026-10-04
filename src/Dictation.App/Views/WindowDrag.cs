using System.Windows;
using System.Windows.Input;

namespace Dictation.App.Views;

/// <summary>
/// Lets one of the floating popups (the dictation pill, the Read aloud player) be held and dragged by any part that
/// isn't a button, without ever taking focus from the app underneath. A press that doesn't move is still a click.
/// The spot it was dragged to is remembered until Oberton restarts or the position setting changes; the popup
/// keeps the same centre and, in the lower half of the screen, the same bottom edge, so it grows upwards.
/// </summary>
sealed class WindowDrag
{
    readonly Window _w;
    Point _start;
    double _left, _top;
    bool _pressed, _dragging, _fromBottom;
    Point? _anchor; // centre x; bottom or top edge y

    public WindowDrag(Window window)
    {
        _w = window;
        // Buttons mark their own presses as handled, so those never start a drag.
        _w.MouseLeftButtonDown += (_, e) =>
        {
            _pressed = true;
            _dragging = false;
            _start = ScreenPoint(e);
            _left = _w.Left;
            _top = _w.Top;
        };
        _w.MouseMove += (_, e) =>
        {
            if (!_pressed) return;
            if (e.LeftButton != MouseButtonState.Pressed) { _pressed = _dragging = false; return; }
            var p = ScreenPoint(e);
            if (!_dragging)
            {
                if (Math.Abs(p.X - _start.X) < SystemParameters.MinimumHorizontalDragDistance &&
                    Math.Abs(p.Y - _start.Y) < SystemParameters.MinimumVerticalDragDistance) return;
                _dragging = true;
                _w.CaptureMouse();
                Mouse.OverrideCursor = Cursors.SizeAll;
            }
            _w.Left = _left + p.X - _start.X;
            _w.Top = _top + p.Y - _start.Y;
            Remember();
        };
        _w.PreviewMouseLeftButtonUp += (_, e) =>
        {
            _pressed = false;
            if (!_dragging) return;
            _dragging = false;
            _w.ReleaseMouseCapture();
            e.Handled = true; // the end of a drag is not a click
        };
        _w.LostMouseCapture += (_, _) =>
        {
            _dragging = false;
            Mouse.OverrideCursor = null;
        };
    }

    public bool IsDragging => _dragging;

    /// <summary>Back to the position from settings.</summary>
    public void Reset() => _anchor = null;

    /// <summary>Put the window where it was dragged to. False if it never was (use the position setting).</summary>
    public bool Place()
    {
        if (_anchor is not { } a) return false;
        double w = _w.ActualWidth, h = _w.ActualHeight;
        var left = a.X - w / 2;
        var top = _fromBottom ? a.Y - h : a.Y;
        // Keep it on screen (any monitor) when it grows.
        double minX = SystemParameters.VirtualScreenLeft, minY = SystemParameters.VirtualScreenTop;
        double maxX = minX + SystemParameters.VirtualScreenWidth - w, maxY = minY + SystemParameters.VirtualScreenHeight - h;
        _w.Left = Math.Clamp(left, minX, Math.Max(minX, maxX));
        _w.Top = Math.Clamp(top, minY, Math.Max(minY, maxY));
        return true;
    }

    void Remember()
    {
        var wa = SystemParameters.WorkArea;
        _fromBottom = _w.Top + _w.ActualHeight / 2 > wa.Top + wa.Height / 2;
        _anchor = new Point(_w.Left + _w.ActualWidth / 2, _fromBottom ? _w.Top + _w.ActualHeight : _w.Top);
    }

    /// <summary>The pointer in screen coordinates, in the same units as Left and Top.</summary>
    Point ScreenPoint(MouseEventArgs e)
    {
        var device = _w.PointToScreen(e.GetPosition(_w));
        var source = PresentationSource.FromVisual(_w);
        return source?.CompositionTarget != null ? source.CompositionTarget.TransformFromDevice.Transform(device) : device;
    }
}
