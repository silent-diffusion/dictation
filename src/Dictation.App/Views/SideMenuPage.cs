namespace Dictation.App.Views;

/// <summary>
/// A page with a side menu of its own (Settings, Speech to text). When the app's sidebar is folded away, the page sits
/// flush against the window's left edge and its menu starts below the menu and Back buttons in the corner.
/// </summary>
public interface ISideMenuPage
{
    /// <param name="clear">True: leave room at the top for the corner buttons.</param>
    void ClearCorner(bool clear);
}
