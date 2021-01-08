#!/usr/bin/env sh
#ump - universal media player
set -eu

# COMMON ----------------------------------------------------------------------
daemon() ( exec nohup "$@" >/dev/null 2>&1 & )
die() { printf '%s\n' "$*" >&2; exit 1; }
exists() { command -v "$1" >/dev/null 2>&1; }
to_argv() { while read -r LINE; do set -- "$@" "$LINE"; done; "$@"; }
in_dir() ( cd "$1"; shift; "$@"; )

# PROVIDER: APPLE MUSIC -------------------------------------------------------
ump_applemusic() {
    case "$1" in
    now)
        shift
        artist="$1" title="$2" osascript -e '
            tell application "Music"
                set results to (every track ¬
                    whose name contains (do shell script "echo \"$title\"") ¬
                    and artist contains (do shell script "echo \"$artist\""))
                play item 1 of results
            end tell'
        ;;
    toggle) osascript -e 'tell application "Music" to playpause';;
    prev) osascript -e 'tell application "Music" to previous track';;
    next) osascript -e 'tell application "Music" to next track';;
    current)
        osascript -e '
            tell application "Music"
                copy (artist of current track) & " - " ¬
                    & (name of current track) to stdout
            end tell'
        ;;
    *) die 'Error: unsupported operation';;
    esac
}

# PROVIDER: YOUTUBE -----------------------------------------------------------
mpv_ensure_running() {
    if ! exists ump_youtube_tell_mpv; then
        if exists socat; then
            ump_youtube_tell_mpv() { socat - "$MPV_SOCKET" 2>/dev/null; }
        elif exists nc && [ "$(uname -s)" = Darwin ]; then
            ump_youtube_tell_mpv() { nc -U "$MPV_SOCKET"; }
        else
            die "Error: socat (or netcat with unix pipes) is not installed"
        fi
    fi
    if ! mpv_command get_version >/dev/null 2>&1; then
        exists mpv || die "Error: mpv is not installed"
        daemon mpv --idle --input-ipc-server="$MPV_SOCKET"
        until mpv_command get_version >/dev/null 2>&1; do sleep 1; done
    fi
}

mpv_command() {
    {
        printf '{ "command": ['
        for x; do printf '%s' "$x" | sed 's/"/\\"/g;s/^/"/;s/$/",/'; done
        echo ']}'
    } | ump_youtube_tell_mpv | jq -esr '
        if . == [] then
            "Error: could not connect to socket.\n" | halt_error
        elif .[0].error != "success" then
            "Error: \(.[0].error)\n" | halt_error
        else
            .[0] | .data
        end'
}

video_lib_location() {
    if [ -n "${UMP_VIDEO_LIBRARY:-}" ]; then
        echo "${UMP_VIDEO_LIBRARY:-}"
    elif exists xdg-user-dir; then
        echo "$(xdg-user-dir MUSIC)"
    else
        echo "$XDG_DATA_HOME/ump/downloaded"
    fi
}

ump_youtube_find_ext() {
    if [ -e "$1.mkv" ]; then
        echo "$1.mkv"
    elif [ -e "$1.webm" ]; then
        echo "$1.webm"
    elif [ -e "$1.mp4" ]; then
        echo "$1.mp4"
    else
        return 1
    fi
}

ump_youtube_video_name() { #1:json
    set -- "$1" "$(<"$1" jq -r '(.artist + " - " + .track)')"
    case "$2" in
    \ -\ |*\ -\ |\ -\ *) <"$1" jq -r .title | yt_title_clean;;
    *) echo "$2";;
    esac
}

ump_youtube_move_file() { #1:file 2:json
    set -- "$1" "$2" \
        "$(ump_youtube_video_name "$2" | sed 's_ \{0,1\}/ \{0,1\}_ - _g')"
    set -- "$1" "$2" \
        "$UMP_VIDEO_LIBRARY/$3.${1##*.}" "$UMP_VIDEO_LIBRARY/.$3.info.json"
    [ "$1" = "$3" ] || mv "$1" "$3" >&2
    [ "$2" = "$4" ] || mv "$2" "$4" >&2
    echo "$3"
}

ump_youtube_organise() {
    for json in "$UMP_VIDEO_LIBRARY"/.*.info.json; do
        video="$(ump_youtube_find_ext "$(dirname "$json")/$(basename "$json" \
            | sed 's/^\.//;s/\.info\.json$//')")" || { rm "$json"; continue; }
        ump_youtube_move_file "$video" "$json"
    done
    for trash in "$UMP_VIDEO_LIBRARY"/.ytdl-tmp-*; do
        [ "$trash" != "$UMP_VIDEO_LIBRARY/.ytdl-tmp-*" ] || continue
        rm "$trash"
    done
    cat "$UMP_VIDEO_LIBRARY"/.*.json \
        | jq -r '(.extractor + " " + .id)' \
        >"$UMP_VIDEO_LIBRARY/.ytdl-archive"
}

hash() {
    python -c \
        'import sys;'`
        `'from hashlib import sha256;'`
        `'print(sha256(sys.argv[2].encode("utf-8")).hexdigest())' -- "$1"
}

ump_youtube_download() {
    set -- "$*" "$(hash "$*")"
    mkdir -p "$UMP_VIDEO_LIBRARY"
    youtube-dl --default-search ytsearch \
        --download-archive "$UMP_VIDEO_LIBRARY/.ytdl-archive" \
        --write-info-json \
        -o "$UMP_VIDEO_LIBRARY/.ytdl-tmp-$2-%(autonumber)s.%(ext)s" "$1" >&2
    for json in "$UMP_VIDEO_LIBRARY/.ytdl-tmp-$2"-*.info.json; do
        video="$(ump_youtube_find_ext "${json%%.info.json}")"
        ump_youtube_move_file "$video" "$json"
    done
}

ump_youtube_find_by_name() {
    set -- "*$(for x; do echo "$x" | sed 's/[][*]/\\&/g;s/$/*/'; done)"
    case "$(find --help | grep -E 'iwholename|ipath|iname')" in
    *iwholename*) set -- -iwholename "$1";;
    *ipath*) set -- -ipath "$1";;
    *iname*) set -- -iname "$1";;
    *) set -- -name "$1";;
    esac
    find "$UMP_VIDEO_LIBRARY" -not -name '.*' -a "$@"
}

ump_youtube_cached() {
    set -- "$(ump_youtube_find_by_name "$@")"
    [ -n "$1" ] && echo "$1" || return 1
}

ump_youtube_ui() {
    find "$UMP_VIDEO_LIBRARY" -maxdepth 1 \( \
            -name '*.mkv' -o -name '*.webm' -o -name '*.mp4' \) \
        | sed 's_.*/__;s/\.[a-z0-9]*$//' \
        | fzy
}

ump_youtube_now() {
    [ "$#" -ne 0 ] || set -- "$(ump_youtube_ui)"; [ -n "$1" ] || return 1
    { ump_youtube_cached "$@" || echo "ytdl://ytsearch:$*"; } \
        | while read -r LINE; do
            mpv_command loadfile "$LINE" replace
        done
}

ump_youtube_add() {
    [ "$#" -ne 0 ] || set -- "$(ump_youtube_ui)"; [ -n "$1" ] || return 1
    { ump_youtube_cached "$@" || ump_youtube_download "$@"; } \
        | while read -r LINE; do
            mpv_command loadfile "$LINE" append-play
        done
}

ump_youtube() {
    MPV_SOCKET="${MPV_SOCKET:-$XDG_RUNTIME_DIR/ump_mpv_socket}"
    UMP_VIDEO_LIBRARY="$(video_lib_location)"
    mpv_ensure_running
    case "$1" in
    now) shift; ump_youtube_now "$@";;
    add) shift; ump_youtube_add "$@";;
    toggle) mpv_command cycle pause;;
    prev) shift; mpv_command playlist_prev;;
    next) shift; mpv_command playlist_next;;
    current) mpv_command get_property media-title | sed 's/\.[^.]*$//';;
    exec) shift; "$@";;
    rsync) shift; in_dir "$UMP_VIDEO_LIBRARY" rsync --progress -rh \
        --exclude '*/' --include '*.mp4' --include '*.mkv' --include '*.webm' \
        --include '.*.info.json' "$@";;
    *) die 'Error: unsupported operation';;
    esac
}

ump() {
    ump_youtube "$@"
}

ump "$@"
