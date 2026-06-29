namespace G4 {

    private string lyrics_cache_path (string uri) {
        var cache_dir = GLib.Path.build_filename (
            GLib.Environment.get_user_cache_dir (), "semitone", "lyrics");
        DirUtils.create_with_parents (cache_dir, 0755);
        var hash = GLib.Checksum.compute_for_string (GLib.ChecksumType.MD5, uri, -1);
        return GLib.Path.build_filename (cache_dir, hash + ".json");
    }

    public void lyrics_save_cache (string uri, string raw, string provider, int64 offset) {
        if (uri.length == 0) return;
        var path = lyrics_cache_path (uri);
        var now = (int64) GLib.get_real_time () / 1000000;

        var builder = new Json.Builder ();
        builder.begin_object ();
        builder.set_member_name ("uri");
        builder.add_string_value (uri);
        builder.set_member_name ("provider");
        builder.add_string_value (provider);
        builder.set_member_name ("fetched_at");
        builder.add_int_value (now);
        builder.set_member_name ("offset_ms");
        builder.add_int_value (offset);
        builder.set_member_name ("lyrics");
        builder.add_string_value (raw);
        builder.end_object ();

            var gen = new Json.Generator ();
            gen.root = builder.get_root () ?? new Json.Node (Json.NodeType.OBJECT);

        try {
            gen.to_file (path);
            lyrics_log ("Cache saved to %s".printf (path));
        } catch (Error e) {
            lyrics_log ("Cache save failed: %s".printf (e.message));
        }
    }

    public bool lyrics_load_cache (string uri, out string raw, out string provider, out int64 offset) {
        raw = "";
        provider = "";
        offset = 0;

        if (uri.length == 0) return false;
        var path = lyrics_cache_path (uri);

        try {
            var parser = new Json.Parser ();
            parser.load_from_file (path);
            var root_obj = parser.get_root ()?.get_object ();
            if (root_obj == null) return false;
            var obj = (!)root_obj;

            var fetched_at = obj.get_int_member ("fetched_at");
            var now = (int64) GLib.get_real_time () / 1000000;
            if (fetched_at > 0 && (now - fetched_at) > 7 * 24 * 3600) {
                lyrics_log ("Cache is stale (>7 days), will re-fetch");
                return false;
            }

            provider = obj.get_string_member ("provider");
            offset = obj.get_int_member ("offset_ms");
            raw = obj.get_string_member ("lyrics");

            lyrics_log ("Cache hit: provider='%s', offset=%lld, raw length=%d".printf (
                provider, offset, raw.length));

            if (raw.length == 0) {
                lyrics_log ("Cache has empty lyrics, ignoring");
                return false;
            }

            return true;
        } catch (Error e) {
            lyrics_log ("No cache for this track");
            return false;
        }
    }

    public void lyrics_clear_cache (string uri) {
        if (uri.length == 0) return;
        var path = lyrics_cache_path (uri);
        FileUtils.unlink (path);
        lyrics_log ("Cache cleared: %s".printf (path));
    }
}
