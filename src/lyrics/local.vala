namespace G4 {

    // ── Local lyric files ─────────────────────────────────────────────
    //
    // Local lyrics live next to the audio file, named after the song stem:
    //   Song.flac + Song.lrc / Song.lrcplus / Song.ttml
    // Extensions and stems are matched case-insensitively (Song.LRC), as
    // files often come from Windows or download tools. All readable
    // candidates are parsed and the best one wins (see provider_fetch_local).

    public const string[] LOCAL_LYRICS_EXTENSIONS = { ".lrc", ".lrcplus", ".ttml" };

    public string lyrics_local_extension (string path) {
        var basename = GLib.Path.get_basename (path);
        var dot = basename.last_index_of_char ('.');
        if (dot < 0) return "";
        return basename.substring (dot).down ();
    }

    private bool lyrics_is_local_extension (string ext) {
        foreach (var known in LOCAL_LYRICS_EXTENSIONS)
            if (known == ext) return true;
        return false;
    }

    private int lyrics_local_extension_rank (string ext) {
        switch (ext) {
            case ".lrcplus": return 0;
            case ".ttml":    return 1;
            case ".lrc":     return 2;
            default:         return 99;
        }
    }

    // Song basename without its audio extension ("Song.flac" -> "Song").
    public string? lyrics_local_stem (Music music) {
        var file = File.new_for_uri (music.uri);
        var basename = file.get_basename ();
        if (basename == null) return null;
        var name = (!)basename;
        if (name.length == 0) return null;
        var dot = name.last_index_of_char ('.');
        if (dot > 0) name = name.substring (0, dot);
        return name;
    }

    // Every existing lyric file next to the song whose stem matches,
    // regardless of extension case. Order is deterministic (LRC+ first).
    public File[] lyrics_find_local_files (Music music) {
        File[] result = {};
        var stem = lyrics_local_stem (music);
        if (stem == null) return result;
        var song_stem = (!)stem;
        var wanted = song_stem.down ();

        var file = File.new_for_uri (music.uri);
        var parent = file.get_parent ();
        if (parent == null) return result;
        var folder = (!)parent;

        try {
            var enumerator = folder.enumerate_children (
                "standard::name,standard::type", FileQueryInfoFlags.NONE);
            FileInfo? info;
            while ((info = enumerator.next_file ()) != null) {
                var i = (!)info;
                if (i.get_file_type () != FileType.REGULAR) continue;
                var name = i.get_name ();
                var dot = name.last_index_of_char ('.');
                if (dot <= 0) continue;
                var ext = name.substring (dot).down ();
                if (!lyrics_is_local_extension (ext)) continue;
                if (name.substring (0, dot).down () != wanted) continue;
                result += folder.get_child (name);
            }
        } catch (Error e) {
            // Directory enumeration is unavailable (e.g. some virtual
            // filesystems): fall back to exact-case direct lookups.
            foreach (var ext in LOCAL_LYRICS_EXTENSIONS) {
                var candidate = folder.get_child (song_stem + ext);
                if (candidate.query_exists ())
                    result += candidate;
            }
        }

        // Stable preference for equal-quality candidates.
        for (var i = 1; i < result.length; i++) {
            var cur = result[i];
            var rank = lyrics_local_extension_rank (
                lyrics_local_extension (cur.get_basename () ?? ""));
            var j = i - 1;
            while (j >= 0) {
                var prev_rank = lyrics_local_extension_rank (
                    lyrics_local_extension (result[j].get_basename () ?? ""));
                if (prev_rank <= rank) break;
                result[j + 1] = result[j];
                j--;
            }
            result[j + 1] = cur;
        }
        return result;
    }

    // Best existing local path for display/reload purposes. This does not
    // parse the files; provider_fetch_local does that to pick the winner.
    public string lyrics_preferred_local_path (Music music) {
        var files = lyrics_find_local_files (music);
        if (files.length == 0) return "";
        var path = files[0].get_path ();
        return path ?? files[0].get_uri ();
    }

    // Accepts either a filesystem path or a URI (non-file backends such as
    // SMB mounts report a URI without a native path).
    private File lyrics_file_from_location (string location) {
        return location.contains ("://") ? File.new_for_uri (location)
                                         : File.new_for_path (location);
    }

    public bool lyrics_read_local_file (File file, out string text) {
        text = "";
        try {
            uint8[] bytes;
            string? etag = null;
            if (!file.load_contents (null, out bytes, out etag))
                return false;
            // load_contents does not guarantee a trailing NUL; copy using
            // the byte count before normalizing BOM/CRLF/encoding.
            text = ((string) bytes).substring (0, bytes.length);
            text = lyrics_normalize_text (text);
            return text.strip ().length > 0;
        } catch (Error e) {
            return false;
        }
    }

    // Writes a sibling lyric file atomically. `format` selects the canonical
    // container: LRC+ / ELRC / TTML are stored as .lrcplus, LRC / plain as
    // .lrc. Reuses an existing same-format file (preserving its case).
    public File? lyrics_local_save_target (Music music, LyricsFormat format,
                                           string preferred_path = "") {
        bool want_lrc_plus = format == LyricsFormat.LRC_PLUS ||
                             format == LyricsFormat.EXTENDED_LRC ||
                             format == LyricsFormat.TTML_WORD_SYNCED ||
                             format == LyricsFormat.TTML_LINE_SYNCED ||
                             format == LyricsFormat.TTML_UNSYNCED;
        var wanted_ext = want_lrc_plus ? ".lrcplus" : ".lrc";

        if (preferred_path.length > 0 &&
                lyrics_local_extension (preferred_path) == wanted_ext) {
            return lyrics_file_from_location (preferred_path);
        }

        foreach (var existing in lyrics_find_local_files (music)) {
            if (lyrics_local_extension (existing.get_basename () ?? "") == wanted_ext)
                return existing;
        }

        var stem = lyrics_local_stem (music);
        if (stem == null) return null;
        var parent = File.new_for_uri (music.uri).get_parent ();
        if (parent == null) return null;
        var folder = (!)parent;
        return folder.get_child ((!)stem + wanted_ext);
    }

    public bool lyrics_write_local_file (File file, string text, out string error) {
        error = "";
        try {
            var contents = text.has_suffix ("\n") ? text : text + "\n";
            string? new_etag = null;
            file.replace_contents (contents.data, null, false,
                FileCreateFlags.REPLACE_DESTINATION, out new_etag, null);
            return true;
        } catch (Error e) {
            error = e.message;
            return false;
        }
    }
}
