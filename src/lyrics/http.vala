namespace G4 {

    private Soup.Session? _lyrics_http_session = null;

    private Soup.Session lyrics_http_session () {
        if (_lyrics_http_session == null)
            _lyrics_http_session = new Soup.Session ();
        return (!)_lyrics_http_session;
    }

    public async string? lyrics_http_get (string url) {
        try {
            var msg = new Soup.Message ("GET", url);
            msg.request_headers.append ("User-Agent", "Semitone/1.0");
            var stream = yield lyrics_http_session ().send_async (msg, GLib.Priority.DEFAULT, null);
            if (msg.status_code != 200) {
                lyrics_log ("HTTP %u for %s".printf (msg.status_code, url));
                return null;
            }
            var dis = new DataInputStream (stream);
            var sb = new StringBuilder ();
            string? line = null;
            do {
                line = yield dis.read_line_async (GLib.Priority.DEFAULT, null);
                if (line != null) {
                    sb.append ((!)line);
                    sb.append_c ('\n');
                }
            } while (line != null);
            return sb.str;
        } catch (Error e) {
            lyrics_log ("HTTP error for %s: %s".printf (url, e.message));
            return null;
        }
    }

    public async string? lyrics_http_get_with_headers (string url, string[,] headers) {
        try {
            var msg = new Soup.Message ("GET", url);
            for (var i = 0; i < headers.length[0]; i++)
                msg.request_headers.append (headers[i, 0], headers[i, 1]);
            var stream = yield lyrics_http_session ().send_async (msg, GLib.Priority.DEFAULT, null);
            if (msg.status_code != 200) {
                lyrics_log ("HTTP %u for %s".printf (msg.status_code, url));
                return null;
            }
            var dis = new DataInputStream (stream);
            var sb = new StringBuilder ();
            string? line = null;
            do {
                line = yield dis.read_line_async (GLib.Priority.DEFAULT, null);
                if (line != null) {
                    sb.append ((!)line);
                    sb.append_c ('\n');
                }
            } while (line != null);
            return sb.str;
        } catch (Error e) {
            lyrics_log ("HTTP error for %s: %s".printf (url, e.message));
            return null;
        }
    }

    public async string? lyrics_http_get_with_headers_allow_4xx (string url, string[,] headers) {
        try {
            var msg = new Soup.Message ("GET", url);
            for (var i = 0; i < headers.length[0]; i++)
                msg.request_headers.append (headers[i, 0], headers[i, 1]);
            var stream = yield lyrics_http_session ().send_async (msg, GLib.Priority.DEFAULT, null);
            var dis = new DataInputStream (stream);
            var sb = new StringBuilder ();
            string? line = null;
            do {
                line = yield dis.read_line_async (GLib.Priority.DEFAULT, null);
                if (line != null) {
                    sb.append ((!)line);
                    sb.append_c ('\n');
                }
            } while (line != null);
            if (msg.status_code < 200 || msg.status_code >= 400) {
                lyrics_log ("HTTP %u for %s, body: %.200s".printf (msg.status_code, url, sb.str));
            }
            return sb.str;
        } catch (Error e) {
            lyrics_log ("HTTP error for %s: %s".printf (url, e.message));
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
}
