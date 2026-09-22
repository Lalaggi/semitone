namespace G4 {

    // Discord Rich Presence over the local client IPC socket.
    //
    // Robustness borrows from MetroList's DiscordRpcManager
    // (github.com/metrolistgroup/metrolist, GPL-3.0), adapted from their
    // token-based gateway transport to desktop local-IPC transport (which needs
    // no user token at all):
    //  - monotonic activity generation: every set/clear bumps it, queued async
    //    work re-checks before writing so stale writes are dropped instead of
    //    re-sending outdated info (e.g. across disable/re-enable);
    //  - debounce + dedup: identical song+playing state is never re-sent
    //    within 2s, and unchanged state is never re-sent at all;
    //  - single-flight connection attempts and a serialized, coalescing send
    //    queue (newer presence wins) so frames can never interleave — the
    //    cause of the "code 1003 failed reading data" errors;
    //  - reconnect backoff with jitter and a cap, then silence until the next
    //    playback event (no endless loop for users without Discord).

    private class DiscordPayload : Object {
        public string json;
        public uint64 generation;
        public bool is_clear;

        public DiscordPayload (string json, uint64 generation, bool is_clear) {
            this.json = json;
            this.generation = generation;
            this.is_clear = is_clear;
        }
    }

    public class DiscordRPC : Object {

        private const string CLIENT_ID = "1481638961955733557";
        private const uint DEBOUNCE_MS = 2000;
        private const uint MAX_RECONNECT_ATTEMPTS = 8;
        private const uint RECONNECT_BASE_S = 5;
        private const uint RECONNECT_MAX_S = 60;

        private SocketConnection? _conn = null;
        private bool _connected = false;
        private bool _connecting = false;
        private bool _enabled = true;

        // Desired state — always refreshed, even while disabled
        private string _title = "";
        private string _artist = "";
        private bool _playing = false;
        private int64 _pos_ms = 0;
        private int64 _start_s = 0;

        // Last SENT state — dedup key
        private string _sent_title = "";
        private string _sent_artist = "";
        private bool _sent_playing = false;
        private bool _sent_valid = false;
        private int64 _last_send_ms = 0;

        // MetroList-style monotonic generation: stale queued work is dropped
        private uint64 _generation = 0;

        // Coalescing outbox: at most one send in flight, one pending (newest wins)
        private DiscordPayload? _pending = null;
        private bool _sending = false;
        private bool _close_after_drain = false;

        private uint _reconnect_source = 0;
        private uint _reconnect_attempts = 0;
        private uint64 _nonce = 0;
        private uint _conn_serial = 0; // bumped on every close/connect: stale readers exit
        private string _rejected_activity = ""; // activity JSON the server 1003'd: don't hammer it
        private string _last_activity_json = "";
        private Application? _app_ref = null;

        public DiscordRPC (Application app) {
            _app_ref = app;
            app.music_changed.connect (on_music_changed);
            app.player.state_changed.connect (on_state_changed);
            app.player.position_updated.connect (on_position_updated);
            connect_async.begin ();
        }

        public void set_enabled (bool enabled) {
            if (_enabled == enabled) return;
            _enabled = enabled;
            _generation++; // invalidate anything queued before the flip
            if (!enabled) {
                if (_reconnect_source != 0) {
                    Source.remove (_reconnect_source);
                    _reconnect_source = 0;
                }
                _reconnect_attempts = 0;
                // One final clear, then close once it drains
                _close_after_drain = true;
                enqueue_clear ();
                if (!_sending && _pending == null)
                    close_connection ();
            } else {
                _close_after_drain = false;
                _rejected_activity = "";
                invalidate_sent_state ();
                refresh_from_app ();
                _reconnect_attempts = 0;
                if (!_connected && !_connecting) {
                    connect_async.begin ();
                } else if (_connected) {
                    request_update ();
                }
            }
        }

        // --- State tracking (always fresh, send-gated) ---

        private void refresh_from_app () {
            var app = _app_ref;
            if (app == null) return;
            var music = ((!)app).current_music;
            _title = music?.title ?? "";
            _artist = music?.artist ?? "";
            _playing = ((!)app).player.playing;
            var pos = ((!)app).player.position;
            _pos_ms = (pos == Gst.CLOCK_TIME_NONE || pos == 0) ? 0 : (int64) (pos / Gst.MSECOND);
            _start_s = GLib.get_real_time () / 1000000 - _pos_ms / 1000;
        }

        private void invalidate_sent_state () {
            _sent_valid = false;
            _sent_title = "";
            _sent_artist = "";
        }

        private void on_position_updated (Gst.ClockTime pos) {
            _pos_ms = (pos == Gst.CLOCK_TIME_NONE || pos == 0) ? 0 : (int64) (pos / Gst.MSECOND);
        }

        private void on_music_changed (Music? music) {
            _title = music?.title ?? "";
            _artist = music?.artist ?? "";
            _pos_ms = 0;
            _start_s = GLib.get_real_time () / 1000000;
            _generation++;
            if (!_enabled) return;
            if (_title.length == 0) {
                enqueue_clear ();
                return;
            }
            if (!_connected && !_connecting) poke ();
            if (_playing && _connected) request_update ();
        }

        private void on_state_changed (Gst.State state) {
            var playing = state == Gst.State.PLAYING;
            if (playing && !_playing && _pos_ms > 0) {
                _start_s = GLib.get_real_time () / 1000000 - _pos_ms / 1000;
            }
            _playing = playing;
            _generation++;
            if (!_enabled) return;
            if (_title.length == 0) return;
            if (!_connected && !_connecting) poke ();
            if (!_connected) return;
            request_update ();
        }

        // --- Update discipline: debounce + dedup, then queue ---

        private void request_update () {
            if (!_enabled || !_connected) return;
            if (_playing) {
                if (_sent_valid && _sent_playing
                        && _sent_title == _title && _sent_artist == _artist) {
                    return; // unchanged — Discord counts elapsed from start itself
                }
                int64 now_ms = GLib.get_real_time () / 1000;
                if (_sent_valid && _sent_playing
                        && now_ms - _last_send_ms < DEBOUNCE_MS) {
                    return;
                }
                enqueue_presence ();
            } else {
                if (_sent_valid && !_sent_playing
                        && _sent_title == _title && _sent_artist == _artist) {
                    return;
                }
                enqueue_clear ();
            }
        }

        private void enqueue_presence () {
            // IPC timestamps are UNIX seconds (not ms)
            var timestamps = "{\"start\":%ld}".printf ((long) _start_s);
            var assets = "{\"large_image\":\"semitone\",\"large_text\":\"Semitone Music Player\"}";
            var activity = "{\"application_id\":\"%s\",\"type\":2,\"name\":\"Semitone\",\"details\":%s,\"state\":%s,\"timestamps\":%s,\"assets\":%s}".printf (
                CLIENT_ID,
                json_escape (_title.length > 0 ? _title : "Unknown"),
                json_escape (_artist.length > 0 ? _artist : "Unknown Artist"),
                timestamps,
                assets);
            var payload = "{\"cmd\":\"SET_ACTIVITY\",\"args\":{\"pid\":%d,\"activity\":%s},\"nonce\":\"%lu\"}".printf (
                (int) Posix.getpid (), activity, (ulong) (++_nonce));
            if (activity == _rejected_activity) {
                GLib.message ("[DiscordRPC] Skipping payload the server rejected before (waiting for new state)");
                return;
            }
            _last_activity_json = activity;
            _sent_title = _title;
            _sent_artist = _artist;
            _sent_playing = true;
            _sent_valid = true;
            _last_send_ms = GLib.get_real_time () / 1000;
            GLib.message ("[DiscordRPC] Queue presence: %s — %s".printf (_title, _artist));
            enqueue (new DiscordPayload (payload, _generation, false));
        }

        private void enqueue_clear () {
            GLib.message ("[DiscordRPC] Queue clear (paused/stopped)");
            _sent_title = _title;
            _sent_artist = _artist;
            _sent_playing = false;
            _sent_valid = true;
            _last_send_ms = GLib.get_real_time () / 1000;
            var payload = "{\"cmd\":\"SET_ACTIVITY\",\"args\":{\"pid\":%d,\"activity\":null},\"nonce\":\"clear-%lu\"}".printf (
                (int) Posix.getpid (), (ulong) (++_nonce));
            enqueue (new DiscordPayload (payload, _generation, true));
        }

        private void enqueue (DiscordPayload payload) {
            if (_sending) {
                // Newer wins — presence only cares about the latest state
                _pending = payload;
                return;
            }
            send_queued.begin (payload);
        }

        private async void send_queued (DiscordPayload payload) {
            _sending = true;
            // Stale guard: a newer set/clear superseded this while it waited
            if (!payload.is_clear && payload.generation != _generation) {
                GLib.message ("[DiscordRPC] Dropping stale queued presence");
            } else if (_connected) {
                yield send_frame (1, payload.json);
            }
            _sending = false;
            var next = _pending;
            _pending = null;
            if (next != null && _connected && !_close_after_drain) {
                send_queued.begin ((!)next);
            } else if (next != null && _close_after_drain && ((!)next).is_clear && _connected) {
                // Drain the final clear, then close
                send_queued.begin ((!)next);
            } else if (_close_after_drain && !_connected) {
                _close_after_drain = false;
            } else if (_close_after_drain && _pending == null) {
                _close_after_drain = false;
                close_connection ();
            }
        }

        private void close_connection () {
            _conn_serial++;
            if (_conn != null) {
                try { ((!)_conn).close (); } catch {}
                _conn = null;
            }
            _connected = false;
            _connecting = false;
            invalidate_sent_state ();
        }

        // --- Connection with jittered backoff, capped attempts ---

        private async void connect_async () {
            if (_connecting || !_enabled) return;
            _connecting = true;
            for (int i = 0; i < 10 && !_connected && _enabled; i++) {
                var uid = (uint) Posix.getuid ();
                var runtime_dir = Environment.get_variable ("XDG_RUNTIME_DIR") ?? "/run/user/%u".printf (uid);
                var path = Path.build_filename (runtime_dir, "discord-ipc-%d".printf (i));
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
            _connecting = false;
            if (!_connected && _enabled) {
                _reconnect_attempts++;
                if (_reconnect_attempts > MAX_RECONNECT_ATTEMPTS) {
                    // Quiet: retry on the next track/state change instead of looping
                    // forever for users without Discord running.
                    GLib.message ("[DiscordRPC] Discord not found after %u tries, waiting for next playback event".printf (
                        MAX_RECONNECT_ATTEMPTS));
                    return;
                }
                schedule_reconnect ();
            }
        }

        private async void do_handshake () {
            var payload = "{\"v\":1,\"client_id\":\"%s\"}".printf (CLIENT_ID);
            yield send_frame (0, payload);
            var response = yield read_frame ();
            if (response != null) {
                _connected = true;
                _reconnect_attempts = 0;
                _conn_serial++;
                invalidate_sent_state (); // force a fresh send on the new connection
                GLib.message ("[DiscordRPC] Connected");
                read_loop.begin (_conn_serial);
                refresh_from_app ();
                if (_title.length > 0 && _playing && _enabled) request_update ();
            } else {
                _connected = false;
                if (_conn != null) { try { ((!)_conn).close (); } catch {} _conn = null; }
            }
        }

        private void schedule_reconnect () {
            if (_reconnect_source != 0 || !_enabled) return;
            // Exponential backoff with ±25% jitter (MetroList reconnect policy shape)
            uint exp = uint.min (_reconnect_attempts, 4u);
            double delay_s = double.min ((double) (RECONNECT_BASE_S << exp), (double) RECONNECT_MAX_S);
            double jitter = delay_s * (0.75 + Random.next_double () * 0.5);
            _reconnect_source = Timeout.add ((uint) (jitter * 1000), () => {
                _reconnect_source = 0;
                connect_async.begin ();
                return false;
            });
        }

        public void poke () {
            // A playback event happened — worth retrying if we gave up earlier
            if (_enabled && !_connected && !_connecting
                    && _reconnect_attempts > MAX_RECONNECT_ATTEMPTS) {
                _reconnect_attempts = 0;
                _rejected_activity = "";
                connect_async.begin ();
            }
        }

        // --- Raw frames: one writer (serialized outbox), one reader (loop below) ---

        // Persistent reader, like drpc/pypresence-style clients: drains server
        // responses (surfacing errors instead of corrupting framing), and notices
        // a server-side close immediately instead of on the next write (EPIPE).
        private async void read_loop (uint serial) {
            while (_connected && serial == _conn_serial) {
                var frame = yield read_frame ();
                if (serial != _conn_serial || !_connected) return;
                if (frame == null) {
                    GLib.message ("[DiscordRPC] Server closed connection, reconnecting");
                    close_connection ();
                    if (_enabled) schedule_reconnect ();
                    return;
                }
                if (((!)frame).contains ("\"code\"")) {
                    var snippet = (!)frame;
                    if (snippet.length > 300) snippet = snippet.substring (0, 300);
                    GLib.message ("[DiscordRPC] Server error: %s".printf (snippet));
                    // arRPC closes after a 1003; remember the rejected bytes so the
                    // reconnect doesn't resend identical state in a tight loop
                    _rejected_activity = _last_activity_json;
                } else if (((!)frame).contains ("SET_ACTIVITY")) {
                    _rejected_activity = "";
                }
            }
        }

        private async void send_frame (uint32 opcode, string json) {
            if (_conn == null) return;
            try {
                var stream = ((!)_conn).output_stream;
                // NOTE: string.data INCLUDES the trailing NUL in Vala — slice it off.
                var data = json.data[0:json.length];
                uint32 len = (uint32) data.length;
                // Single write: arRPC's parser does socket.read(8) then
                // socket.read(dataSize), and Node returns null (→ 1003
                // "failed reading data" + destroy) when the body hasn't
                // arrived yet. Header+body in one write keeps them in one
                // packet. See OpenAsar/arrpc src/transports/ipc.js.
                var frame = new uint8[8 + len];
                frame[0] = (uint8) (opcode & 0xff);
                frame[1] = (uint8) ((opcode >> 8) & 0xff);
                frame[2] = (uint8) ((opcode >> 16) & 0xff);
                frame[3] = (uint8) ((opcode >> 24) & 0xff);
                frame[4] = (uint8) (len & 0xff);
                frame[5] = (uint8) ((len >> 8) & 0xff);
                frame[6] = (uint8) ((len >> 16) & 0xff);
                frame[7] = (uint8) ((len >> 24) & 0xff);
                Memory.copy (&frame[8], data, len);
                yield stream.write_all_async (frame, Priority.DEFAULT, null, null);
            } catch (Error e) {
                GLib.message ("[DiscordRPC] Write failed, reconnecting: %s".printf (e.message));
                close_connection ();
                if (_enabled) schedule_reconnect ();
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
                if (len > 1024 * 1024) return null;
                var buf = new uint8[len + 1];
                yield stream.read_all_async (buf[0:len], Priority.DEFAULT, null, out bytes_read);
                buf[len] = 0;
                return (string) buf;
            } catch (Error e) {
                return null;
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
    }
}
