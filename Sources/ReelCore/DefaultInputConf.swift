import Foundation

/// The key bindings (design section 10) in IINA's input.conf syntax. The M2 rows are written as
/// IINA's own `iina-default-input.conf` has them. Embedded as a string so no SwiftPM resource
/// bundle is needed; a user file can override it later.
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

    # Subtitles (M2)
    Shift+RIGHT sub-seek 1
    Shift+LEFT sub-seek -1
    Z add sub-delay -0.5
    X add sub-delay 0.5
    Alt+Z add sub-delay -0.1
    Alt+X add sub-delay 0.1
    C set sub-delay 0
    G add sub-scale +0.1
    F add sub-scale -0.1
    r add sub-pos -1
    R add sub-pos +1
    t add sub-pos +1
    v cycle sub-visibility

    # Audio delay (M2)
    Shift+( add audio-delay 0.5
    Shift+) add audio-delay -0.5
    Alt+Shift+( add audio-delay 0.1
    Alt+Shift+) add audio-delay -0.1
    Shift+_ set audio-delay 0

    # Tracks (M2)
    Ctrl+Meta+s cycle sub
    Ctrl+Meta+a cycle audio
    Ctrl+Meta+v cycle video

    # Episodes (M2)
    Meta+RIGHT playlist-next
    Meta+LEFT playlist-prev
    NEXT playlist-next
    PREV playlist-prev
    MBTN_FORWARD playlist-next
    MBTN_BACK playlist-prev

    # Speed (M2)
    Meta+[ multiply speed 0.5
    Meta+] multiply speed 2.0
    Alt+Meta+[ multiply speed 1/1.1
    Alt+Meta+] multiply speed 1.1
    Meta+\\ set speed 1.0

    # Media keys (M2)
    FORWARD seek 15
    REWIND seek -15

    # Screenshot, loops and Picture in Picture (M2)
    Meta+s screenshot
    Meta+l ab-loop
    Meta+L cycle-values loop "inf" "no"
    Ctrl+Meta+p toggle-pip

    # App
    Meta+o script-message reel-open
    Meta+w script-message reel-close
    Meta+, script-message reel-settings
    Meta+q quit
    q quit
    """
}
