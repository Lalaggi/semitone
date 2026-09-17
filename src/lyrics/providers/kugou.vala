namespace G4 {

    private async LyricsCandidate? kugou_fetch_lyric (string file_hash, int duration_ms, int index, GLib.Cancellable? cancellable) {
        var url = "http://m.kugou.com/app/i/krc.php?cmd=100&hash=%s&timelength=%d".printf (
            Uri.escape_string (file_hash, null, false), duration_ms);
        var body = yield lyrics_http_get (url, cancellable);
        if (cancellable != null && ((!)cancellable).is_cancelled ()) return null;
        if (body == null || ((!)body).strip ().length == 0) return null;
        return lyrics_build_candidate ((!)body, "KuGou", index);
    }

    public async LyricsCandidate? provider_fetch_kugou (Music music, int duration_ms, Settings settings, int index, GLib.Cancellable? cancellable = null) {
        if (!settings.get_boolean ("lyrics-kugou-enabled")) {
            lyrics_log ("KuGou: disable");
            return null;
        }

        var query = "%s %s".printf (music.title, music.artist).strip ();
        if (query.length < 2) return null;
        var url = "http://mobilecdn.kugou.com/api/v3/search/song?format=json&keyword=%s&page=1&pagesize=5&showtype=1".printf (
            Uri.escape_string (query, null, false));
        var body = yield lyrics_http_get (url, cancellable);
        if (cancellable != null && ((!)cancellable).is_cancelled ()) return null;
        if (body == null) return null;
        try {
            var parser = new Json.Parser ();
            parser.load_from_data ((!)body);
            var root = parser.get_root ()?.get_object ();
            if (root == null) return null;
            var obj = (!)root;
            if (!obj.has_member ("data")) return null;
            var data = obj.get_object_member ("data");
            if (data == null || !((!)data).has_member ("info")) return null;
            var info = ((!)data).get_array_member ("info");
            if (info == null) return null;
            string[] hashes = {};
            ((!)info).foreach_element ((a, i, node) => {
                var entry = node.get_object ();
                if (entry == null) return;
                var e = (!)entry;
                var name = unison_get_string_member (e, "songname");
                if (name.length == 0) name = unison_get_string_member (e, "songname_original");
                var singer = unison_get_string_member (e, "singername");
                if (!unison_text_matches (name, music.title) || !unison_text_matches (singer, music.artist)) {
                    if (lyrics_debug_enabled)
                        lyrics_log ("KuGou: skipping '%s' by '%s'".printf (name, singer));
                    return;
                }
                var hash = unison_get_string_member (e, "hash");
                if (hash.length > 0) hashes += hash;
            });
            var limit = int.min (3, hashes.length);
            for (var i = 0; i < limit; i++) {
                if (cancellable != null && ((!)cancellable).is_cancelled ()) return null;
                var c = yield kugou_fetch_lyric (hashes[i], duration_ms, index, cancellable);
                if (c != null) return c;
            }
            return null;
        } catch (Error e) {
            if (lyrics_debug_enabled)
                lyrics_log ("KuGou: %s".printf (e.message));
            return null;
        }
    }
}
