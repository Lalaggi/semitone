namespace G4 {

    public class DiscordRPC : Object {

        private const string CLIENT_ID = "1481638961955733557";

        private SocketConnection? _conn = null;
        private bool _connected = false;
        private string _current_title = "";
        private string _current_artist = "";
        private bool _playing = false;
        private int64 _current_position_ms = 0;
        private uint _reconnect_source = 0;
        private Application? _app_ref = null;

        public DiscordRPC (Application app) {
            _app_ref = app;
            app.music_changed.connect (on_music_changed);
            app.player.state_changed.connect (on_state_changed);
            app.player.position_updated.connect (on_position_updated);
            connect_async.begin ();
        }

        private void on_position_updated (Gst.ClockTime pos) {
            if (pos == Gst.CLOCK_TIME_NONE || pos == 0) {
                _current_position_ms = 0;
            } else {
                _current_position_ms = (int64) (pos / Gst.MSECOND);
            }
        }

        private async void connect_async () {
            for (int i = 0; i < 10 && !_connected; i++) {
                var uid = (uint) Posix.getuid ();
                var path = "/run/user/%u/discord-ipc-%d".printf (uid, i);
                try {
                    var file = File.new_for_path (path);
                    if (!file.query_exists ()) continue;
                    var addr = new UnixSocketAddress (path);
                    var client = new SocketClient ();
                    _conn = yield client.connect_async (addr, null);
                    yield do_handshake ();
                    if (_connected) break;
                } catch (Error e) {
                    if (_conn != null) { try { ((!)_conn).close (); } catch {} _conn = null; }
                }
                yield delay_ms (100);
            }
            if (!_connected) schedule_reconnect ();
        }

        private async void do_handshake () {
            var payload = "{\"v\":1,\"client_id\":\"%s\"}".printf (CLIENT_ID);
            GLib.message ("[DiscordRPC] Sending handshake: %s".printf (payload));
            yield send_frame (0, payload);
            var response = yield read_frame ();
            GLib.message ("[DiscordRPC] Handshake response: %s".printf (response ?? "null"));
            if (response != null) {
                _connected = true;
                GLib.message ("[DiscordRPC] Connected");
                if (_current_title.length > 0 && _playing) yield send_presence ();
            } else {
                schedule_reconnect ();
            }
        }

        private void schedule_reconnect () {
            if (_reconnect_source != 0) return;
            _reconnect_source = Timeout.add_seconds (5, () => {
                _reconnect_source = 0;
                connect_async.begin ();
                return false;
            });
        }

        private async void send_frame (uint32 opcode, string json) {
            if (_conn == null) return;
            try {
                var stream = ((!)_conn).output_stream;
                var data = json.data;
                uint32 len = (uint32) data.length;
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
                _connected = false;
                _conn = null;
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
                uint32 len = header[4] | ((uint32) header[5] << 8) | ((uint32) header[6] << 16) | ((uint32) header[7] << 24);
                if (len == 0) return "";
                var buf = new uint8[len + 1];
                yield stream.read_all_async (buf[0:len], Priority.DEFAULT, null, out bytes_read);
                buf[len] = 0;
                return (string) buf;
            } catch (Error e) {
                _connected = false;
                _conn = null;
                schedule_reconnect ();
                return null;
            }
        }

        private async void send_presence () {
            if (!_connected) return;

            int64 start_ms;
            if (_playing && _song_start_time_ms > 0) {
                start_ms = _song_start_time_ms;
            } else {
                start_ms = (int64) (GLib.get_real_time () / 1000);
            }
            var timestamps = "{\"start\":%ld}".printf ((long) start_ms);
            var assets = "{\"large_image\":\"semitone\",\"large_text\":\"Semitone Music Player\"}";

            GLib.message ("[DiscordRPC] start_ms=%ld, playing=%s".printf ((long) start_ms, _playing.to_string ()));

            var activity = "{\"application_id\":\"%s\",\"type\":2,\"name\":\"Semitone\",\"details\":%s,\"state\":%s,\"timestamps\":%s,\"assets\":%s}".printf (
                CLIENT_ID,
                json_escape (_current_title.length > 0 ? _current_title : "Unknown"),
                json_escape (_current_artist.length > 0 ? _current_artist : "Unknown Artist"),
                timestamps,
                assets);

            var payload = "{\"cmd\":\"SET_ACTIVITY\",\"args\":{\"pid\":%d,\"activity\":%s},\"nonce\":\"%ld\"}".printf (
                (int) Posix.getpid (), activity, (long) (start_ms / 1000));

            GLib.message ("[DiscordRPC] Sending presence: %s — %s (pos=%ldms)".printf (_current_title, _current_artist, (long) _current_position_ms));
            yield send_frame (1, payload);
            
            yield delay_ms (300);
            var response = yield read_frame ();
            if (response != null) {
                GLib.message ("[DiscordRPC] Response: %s".printf ((!)response));
            }
        }

        private string json_escape (string s) {
            return "\"" + s.replace ("\\", "\\\\").replace ("\"", "\\\"").replace ("\n", "\\n").replace ("\r", "\\r") + "\"";
        }

        private async void delay_ms (uint ms) {
            GLib.Timeout.add (ms, () => {
                delay_ms.callback ();
                return false;
            });
            yield;
        }

        private int64 _song_start_time_ms = 0;
        private uint _update_presence_source = 0;

        private void on_music_changed (Music? music) {
            _current_title = music?.title ?? "";
            _current_artist = music?.artist ?? "";
            _current_position_ms = 0;
            _song_start_time_ms = (int64) (GLib.get_real_time () / 1000);
            if (_current_title.length == 0) {
                clear_presence.begin ();
                return;
            }
            if (_playing && _connected) send_presence.begin ();
        }

        private void on_state_changed (Gst.State state) {
            var was_playing = _playing;
            _playing = state == Gst.State.PLAYING;
            
            if (_current_title.length == 0) return;
            
            if (_playing && !was_playing && _current_position_ms > 0) {
                _song_start_time_ms = (int64) (GLib.get_real_time () / 1000) - _current_position_ms;
                GLib.message ("[DiscordRPC] Unpause: set start_time to %ld (pos=%ldms)".printf (
                    (long) _song_start_time_ms, (long) _current_position_ms));
            }
            
            if (_playing && _connected) {
                if (_update_presence_source > 0) {
                    Source.remove (_update_presence_source);
                }
                _update_presence_source = Timeout.add (500, () => {
                    _update_presence_source = 0;
                    send_presence.begin ();
                    return false;
                });
            } else {
                clear_presence.begin ();
            }
        }

        private async void clear_presence () {
            if (!_connected) return;
            var payload = "{\"cmd\":\"SET_ACTIVITY\",\"args\":{\"pid\":%d,\"activity\":null},\"nonce\":\"clear\"}".printf (
                (int) Posix.getpid ());
            yield send_frame (1, payload);
        }
    }
}