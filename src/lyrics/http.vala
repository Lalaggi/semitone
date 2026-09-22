namespace G4 {

    private Soup.Session? _lyrics_http_session = null;

    private Soup.Session lyrics_http_session () {
        if (_lyrics_http_session == null)
            _lyrics_http_session = new Soup.Session ();
        return (!)_lyrics_http_session;
    }

    public async string? lyrics_http_get (string url, GLib.Cancellable? cancellable = null) {
        try {
            var msg = new Soup.Message ("GET", url);
            msg.request_headers.append ("User-Agent", "Semitone/1.0");
            var stream = yield lyrics_http_session ().send_async (msg, GLib.Priority.DEFAULT, cancellable);
            if (cancellable != null && ((!)cancellable).is_cancelled ()) return null;
            if (msg.status_code != 200) return null;
            var dis = new DataInputStream (stream);
            var sb = new StringBuilder ();
            string? line = null;
            do {
                line = yield dis.read_line_async (GLib.Priority.DEFAULT, cancellable);
                if (line != null) {
                    sb.append ((!)line);
                    sb.append_c ('\n');
                }
            } while (line != null);
            return sb.str;
        } catch (Error e) {
            return null;
        }
    }

    public async string? lyrics_http_get_with_headers (string url, string[,] headers, GLib.Cancellable? cancellable = null) {
        try {
            var msg = new Soup.Message ("GET", url);
            for (var i = 0; i < headers.length[0]; i++)
                msg.request_headers.append (headers[i, 0], headers[i, 1]);
            var stream = yield lyrics_http_session ().send_async (msg, GLib.Priority.DEFAULT, cancellable);
            if (cancellable != null && ((!)cancellable).is_cancelled ()) return null;
            if (msg.status_code != 200) return null;
            var dis = new DataInputStream (stream);
            var sb = new StringBuilder ();
            string? line = null;
            do {
                line = yield dis.read_line_async (GLib.Priority.DEFAULT, cancellable);
                if (line != null) {
                    sb.append ((!)line);
                    sb.append_c ('\n');
                }
            } while (line != null);
            return sb.str;
        } catch (Error e) {
            return null;
        }
    }

    public async string? lyrics_http_get_with_headers_allow_4xx (string url, string[,] headers, GLib.Cancellable? cancellable = null) {
        try {
            var msg = new Soup.Message ("GET", url);
            for (var i = 0; i < headers.length[0]; i++)
                msg.request_headers.append (headers[i, 0], headers[i, 1]);
            var stream = yield lyrics_http_session ().send_async (msg, GLib.Priority.DEFAULT, cancellable);
            if (cancellable != null && ((!)cancellable).is_cancelled ()) return null;
            var dis = new DataInputStream (stream);
            var sb = new StringBuilder ();
            string? line = null;
            do {
                line = yield dis.read_line_async (GLib.Priority.DEFAULT, cancellable);
                if (line != null) {
                    sb.append ((!)line);
                    sb.append_c ('\n');
                }
            } while (line != null);
            return sb.str;
        } catch (Error e) {
            return null;
        }
    }

    public string? read_api_key_file (string filename) {
        var path = Path.build_filename (
            Environment.get_home_dir (), ".config", "semitone", filename);
        string? contents = null;
        try {
            FileUtils.get_contents (path, out contents);
            return ((!)contents).strip ();
        } catch (Error e) {
            return null;
        }
    }

    public async string? lyrics_http_post (string url, string content_type, string body,
            string[,]? headers = null, GLib.Cancellable? cancellable = null,
            out uint status_code) {
        status_code = 0;
        try {
            var msg = new Soup.Message ("POST", url);
            if (headers != null) {
                for (var i = 0; i < headers.length[0]; i++)
                    msg.request_headers.append (headers[i, 0], headers[i, 1]);
            }
            msg.set_request_body_from_bytes (content_type,
                // string.data includes the trailing NUL — slice it off
                new Bytes (body.data[0:body.length]));
            var resp = yield lyrics_http_session ().send_and_read_async (
                msg, GLib.Priority.DEFAULT, cancellable);
            status_code = msg.status_code;
            // NUL-terminate a copy: raw get_data() is not a C string
            var raw = resp.get_data ();
            var buf = new uint8[raw.length + 1];
            Memory.copy (buf, raw, raw.length);
            buf[raw.length] = 0;
            return (string) buf;
        } catch (Error e) {
            GLib.message ("[http] POST %s failed: %s".printf (url, e.message));
            return null;
        }
    }

    public async string? lyrics_http_post_form (string url, HashTable<string, string> fields,
            GLib.Cancellable? cancellable = null, out uint status_code) {
        var sb = new StringBuilder ();
        bool first = true;
        foreach (var key in fields.get_keys ()) {
            if (!first) sb.append_c ('&');
            first = false;
            sb.append (Uri.escape_string (key, null, true));
            sb.append_c ('=');
            sb.append (Uri.escape_string (fields[key], null, true));
        }
        return yield lyrics_http_post (url, "application/x-www-form-urlencoded",
            sb.str, { { "User-Agent", "Semitone/1.0" } }, cancellable, out status_code);
    }
}
