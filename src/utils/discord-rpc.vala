namespace G4 {

    public class DiscordRPC : Object {

        // Replace with your Discord application client ID
        private const string CLIENT_ID = "YOUR_CLIENT_ID_HERE";
        private const string LARGE_IMAGE_KEY = "music_note";

        private SocketConnection? _conn = null;
        private bool _connected = false;
        private string _current_title = "";
        private string _current_artist = "";
        private bool _playing = false;
        private uint _reconnect_source = 0;

        public DiscordRPC (Application app) {
            app.music_changed.connect (on_music_changed);
            app.player.state_changed.connect (on_state_changed);
            connect_async.begin ();
        }

        // ── Connection ───────────────────────────────────────────────

        private async void connect_async () {
            _connected = false;
            var uid = (uint) Posix.getuid ();
            var path = "/run/user/%u/discord-ipc-0".printf (uid);
            try {
                var addr = new UnixSocketAddress (path);
                var client = new SocketClient ();
                _conn = yield client.connect_async (addr, null);
                yield do_handshake ();
            } catch (Error e) {
                GLib.message ("[DiscordRPC] Connect failed: %s", e.message);
                schedule_reconnect ();
            }
        }

        private async void do_handshake () {
            var payload = "{\"v\":1,\"client_id\":\"%s\"}".printf (CLIENT_ID);
            yield send_frame (0, payload);
            // Read handshake response
            var response = yield read_frame ();
            if (response != null) {
                _connected = true;
                GLib.message ("[DiscordRPC] Connected");
                // Send current state if we already have a track
                if (_current_title.length > 0)
                    yield send_presence ();
            } else {
                schedule_reconnect ();
            }
        }

        private void schedule_reconnect () {
            if (_reconnect_source != 0) return;
            _reconnect_source = Timeout.add_seconds (10, () => {
                _reconnect_source = 0;
                connect_async.begin ();
                return false;
            });
        }

        // ── Frame I/O ────────────────────────────────────────────────

        // Discord IPC frame: [opcode: 4 bytes LE] [length: 4 bytes LE] [json: length bytes]

        private async void send_frame (uint32 opcode, string json) {
            if (_conn == null) return;
            try {
                var stream = ((!)_conn).output_stream;
                var data = json.data;
                uint32 len = (uint32) data.length;

                // Build header (8 bytes, little-endian)
                uint8 header[8];
                header[0] = (uint8) (opcode & 0xff);
                header[1] = (uint8) ((opcode >> 8) & 0xff);
                header[2] = (uint8) ((opcode >> 16) & 0xff);
                header[3] = (uint8) ((opcode >> 24) & 0xff);
                header[4] = (uint8) (len & 0xff);
                header[5] = (uint8) ((len >> 8) & 0xff);
                header[6] = (uint8) ((len >> 16) & 0xff);
                header[7] = (uint8) ((len >> 24) & 0xff);

                yield stream.write_all_async (header, Priority.DEFAULT, null, null);
                yield stream.write_all_async (data, Priority.DEFAULT, null, null);
            } catch (Error e) {
                GLib.message ("[DiscordRPC] Send error: %s", e.message);
                _connected = false;
                schedule_reconnect ();
            }
        }

        private async string? read_frame () {
            if (_conn == null) return null;
            try {
                var stream = ((!)_conn).input_stream;
                uint8 header[8];
                size_t bytes_read;
                yield stream.read_all_async (header, Priority.DEFAULT, null, out bytes_read);
                if (bytes_read < 8) return null;
                uint32 len = header[4] | ((uint32) header[5] << 8) |
                             ((uint32) header[6] << 16) | ((uint32) header[7] << 24);
                if (len == 0) return "";
                var buf = new uint8[len + 1];
                yield stream.read_all_async (buf[0:len], Priority.DEFAULT, null, out bytes_read);
                buf[len] = 0;
                return (string) buf;
            } catch (Error e) {
                GLib.message ("[DiscordRPC] Read error: %s", e.message);
                _connected = false;
                schedule_reconnect ();
                return null;
            }
        }

        // ── Presence ─────────────────────────────────────────────────

        private async void send_presence () {
            if (!_connected) return;

            var state = _playing ? _current_artist : _("Paused");
            var details = _current_title;
            var small_image = _playing ? "\"small_image\":\"play\",\"small_text\":\"Playing\"" :
                                         "\"small_image\":\"pause\",\"small_text\":\"Paused\"";

            var assets = "{\"large_image\":\"%s\",\"large_text\":\"Semitone\",%s}".printf (
                LARGE_IMAGE_KEY, small_image);

            var activity = "{\"details\":%s,\"state\":%s,\"assets\":%s}".printf (
                json_escape (details),
                json_escape (state),
                assets);

            var payload = "{\"cmd\":\"SET_ACTIVITY\",\"args\":{\"pid\":%d,\"activity\":%s},\"nonce\":\"1\"}".printf (
                (int) Posix.getpid (), activity);

            yield send_frame (1, payload);
            // Read the response to keep the socket clear
            yield read_frame ();
        }

        private void clear_presence () {
            if (!_connected) return;
            var payload = "{\"cmd\":\"SET_ACTIVITY\",\"args\":{\"pid\":%d,\"activity\":null},\"nonce\":\"1\"}".printf (
                (int) Posix.getpid ());
            send_frame.begin (1, payload, (obj, res) => {
                send_frame.end (res);
                read_frame.begin ((obj2, res2) => read_frame.end (res2));
            });
        }

        // ── Signal handlers ──────────────────────────────────────────

        private void on_music_changed (Music? music) {
            _current_title = music?.title ?? "";
            _current_artist = music?.artist ?? "";
            if (_current_title.length == 0) {
                clear_presence ();
                return;
            }
            send_presence.begin ();
        }

        private void on_state_changed (Gst.State state) {
            var now_playing = state == Gst.State.PLAYING;
            if (now_playing != _playing) {
                _playing = now_playing;
                if (_current_title.length > 0)
                    send_presence.begin ();
            }
        }

        // ── Helpers ──────────────────────────────────────────────────

        private string json_escape (string s) {
            return "\"" + s.replace ("\\", "\\\\").replace ("\"", "\\\"") + "\"";
        }
    }
}
