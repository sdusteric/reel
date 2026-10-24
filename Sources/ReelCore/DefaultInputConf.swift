import Foundation

/// The M1 key bindings (design section 10) in IINA's input.conf syntax. Embedded as a string
/// so no SwiftPM resource bundle is needed; a user file can override it later.
public enum DefaultInputConf {
    public static let text = """
    # Reel default key bindings, input.conf syntax.
    # KEY command [args]. Modifiers: Shift, Ctrl, Alt, Meta (Command).

    # Playback
    SPACE cycle pause
    p cycle pause
    PLAYPAUSE cycle pause

    # Seeking
    RIGHT seek 5 exact
    LEFT seek -5 exact
    Shift+PGUP seek 600 exact
    Shift+PGDWN seek -600 exact
    . frame-step
    , frame-back-step
    Alt+RIGHT frame-step
    Alt+LEFT frame-back-step

    # Volume
    UP add volume 5
    DOWN add volume -5
    Alt+UP add volume 1
    Alt+DOWN add volume -1
    m cycle mute
    Meta+/ cycle mute

    # Window
    f cycle fullscreen
    Ctrl+Meta+f cycle fullscreen
    ENTER cycle fullscreen
    ESC set fullscreen no
    Meta+0 script-message reel-window-scale 0.5
    Meta+1 script-message reel-window-scale 1
    Meta+2 script-message reel-window-scale 2
    Meta+3 script-message reel-window-scale fit

    # App
    Meta+o script-message reel-open
    Meta+w script-message reel-close
    Meta+, script-message reel-settings
    Meta+q quit
    q quit
    """
}
