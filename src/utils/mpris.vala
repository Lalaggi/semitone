namespace G4 {

    [DBus (name = "org.mpris.MediaPlayer2.Player")]
    public class MprisPlayer : Object {
        [DBus (visible = false)]
        private unowned Application _app;
        private unowned DBusConnection _connection;
        private bool _cover_parsed = false;
        private int64 _current_duration = 0;
        private Music? _current_music = null;
        private HashTable<string, Variant> _metadata = new HashTable<string, Variant> (str_hash, str_equal);
        private unowned Thread<void> _main_thread;
        private string _loop_status = "None";
        private double _rate = 1.0;

        public signal void seeked (int64 position);

        public MprisPlayer (Application app, DBusConnection connection) {
            _app = app;
            _connection = connection;
            _main_thread = Thread<void>.self ();

            app.index_changed.connect (on_index_changed);
            app.music_changed.connect (on_music_changed);
            app.music_cover_parsed.connect (on_music_cover_parsed);
            app.player.state_changed.connect (on_state_changed);
            app.player.duration_changed.connect (on_duration_changed);
        }

        public bool can_control {
            get {
                return true;
            }
        }

        public bool can_go_next {
            get {
                return _app.current_item < (int) _app.current_list.get_n_items () - 1;
            }
        }

        public bool can_go_previous {
            get {
                return _app.current_item > 0;
            }
        }

        public bool can_play {
            get {
                return _app.current_music != null;
            }
        }

        public bool can_pause {
            get {
                return _app.current_music != null;
            }
        }

        public bool can_seek {
            get {
                return _app.current_music != null;
            }
        }

        public HashTable<string, Variant> metadata {
            get {
                return _metadata;
            }
        }

        public int64 position {
            get {
                // Cached value updated every 100ms by GstPlayer.parse_position.
                // Never query the pipeline here: a live query_position from a
                // D-Bus handler would block the main loop on network stalls
                // and wedge every MPRIS client (see docs/MPRIS_FREEZE_BUG_REPORT.md).
                var pos = _app.player.position;
                return pos != Gst.CLOCK_TIME_NONE ? (int64) pos / Gst.USECOND : 0;
            }
        }

        public string loop_status {
            owned get {
                return _loop_status;
            }
            set {
                _loop_status = value;
                // Map MPRIS LoopStatus onto the app repeat modes (best effort)
                switch (value) {
                    case "Track":
                        _app.repeat_mode = 2; // RepeatMode.ONE
                        break;
                    case "Playlist":
                        _app.repeat_mode = 1; // RepeatMode.ALL
                        break;
                    default:
                        _loop_status = "None";
                        _app.repeat_mode = 0; // RepeatMode.NONE
                        break;
                }
            }
        }

        public double rate {
            get {
                return _rate;
            }
            set {
                // Playback rate control is not supported; accept 1.0 only
                _rate = value == 0 ? 1.0 : value;
            }
        }

        public double minimum_rate {
            get {
                return 1.0;
            }
        }

        public double maximum_rate {
            get {
                return 1.0;
            }
        }

        public string playback_status {
            owned get {
                return get_mpris_status(_app.player.state);
            }
        }

        public bool shuffle {
            get {
                return _app.sort_mode == SortMode.SHUFFLE;
            }
            set {
                if (value && (_app.sort_mode != SortMode.SHUFFLE)) {
                    _app.sort_mode = SortMode.SHUFFLE;
                } else {
                    _app.sort_mode = SortMode.TITLE;
                }
            }
        }

        public double volume {
            get {
                return _app.player.volume;
            }
            set {
                _app.player.volume = value;
            }
        }

        // All control methods return immediately and defer pipeline work to
        // an idle callback. GDBus sends the method reply when the handler
        // returns, so doing set_state/seek synchronously here would make the
        // reply wait on GStreamer (network stalls, sink reconfig) and time out
        // every MPRIS client polling us. Deferring keeps replies < 1ms.

        public void next () throws Error {
            Idle.add (() => {
                _app.play_next ();
                return false;
            });
        }

        public void previous () throws Error {
            Idle.add (() => {
                _app.play_previous ();
                return false;
            });
        }

        public void play_pause () throws Error {
            Idle.add (() => {
                _app.play_pause ();
                return false;
            });
        }

        public void play () throws Error {
            Idle.add (() => {
                _app.player.play ();
                return false;
            });
        }

        public void pause () throws Error {
            Idle.add (() => {
                _app.player.pause ();
                return false;
            });
        }

        public void stop () throws Error {
            Idle.add (() => {
                _app.player.state = Gst.State.READY;
                return false;
            });
        }

        public void seek (int64 offset) throws Error {
            var pos = _app.player.position;
            if (pos == Gst.CLOCK_TIME_NONE) return;
            var new_pos = (int64) pos + offset * Gst.USECOND;
            if (new_pos < 0) new_pos = 0;
            var final_pos = new_pos; // capture by value for closure
            Idle.add (() => {
                _app.player.position = (Gst.ClockTime) final_pos;
                seeked (final_pos / Gst.USECOND);
                return false;
            });
        }

        public void set_position (ObjectPath track_id, int64 position) throws Error {
            if (track_id != current_track_id ()) return;
            if (position < 0) return;
            var new_pos = (Gst.ClockTime) (position * Gst.USECOND);
            Idle.add (() => {
                _app.player.position = new_pos;
                seeked (position);
                return false;
            });
        }

        public void open_uri (string uri) throws Error {
            var copy = uri;
            Idle.add (() => {
                _app.open_uri_async.begin (copy);
                return false;
            });
        }

        private void on_duration_changed (Gst.ClockTime duration) {
            var ms = duration != Gst.CLOCK_TIME_NONE ? (int64) duration / Gst.USECOND : 0;
            if (_current_duration != ms) {
                _metadata.insert ("mpris:length", new Variant.int64 (ms));
                if (_cover_parsed)
                    send_property ("Metadata", _metadata);
                _current_duration = ms;
            }
        }

        private void on_index_changed (int index, uint size) {
            var builder = new VariantBuilder (new VariantType ("a{sv}"));
            builder.add ("{sv}", "CanGoNext", new Variant.boolean (index < (int) size - 1));
            builder.add ("{sv}", "CanGoPrevious", new Variant.boolean (index > 0));
            builder.add ("{sv}", "CanPlay", new Variant.boolean (_app.current_music != null));
            builder.add ("{sv}", "CanPause", new Variant.boolean (_app.current_music != null));
            send_properties (builder);
        }

        private void on_music_changed (Music? music) {
            _cover_parsed = false;
            _current_music = music;
            _current_duration = 0;
            _metadata.remove_all ();
            if (music != null) {
                var artists = new VariantBuilder (new VariantType ("as"));
                artists.add ("s", music?.artist ?? "");
                _metadata.insert ("xesam:artist", artists.end());
                _metadata.insert ("xesam:title", new Variant.string (music?.title ?? ""));
                _metadata.insert ("xesam:album", new Variant.string (music?.album ?? ""));
                _metadata.insert ("xesam:url", new Variant.string (music?.uri ?? ""));
                _metadata.insert ("mpris:trackid", new Variant.object_path (current_track_id ()));
                _metadata.insert ("mpris:length", new Variant.int64 (_current_duration));
            }
        }

        private void on_music_cover_parsed (Music music, Gdk.Pixbuf? pixbuf, string? uri) {
            if (_current_music != music) {
                on_music_changed (music);
            }
            if (uri != null) {
                _metadata.insert ("mpris:artUrl", new Variant.string ((!)uri));
            } else {
                _metadata.remove ("mpris:artUrl");
            }
            send_property ("Metadata", _metadata);
            _cover_parsed = true;
        }

        private void on_state_changed (Gst.State state) {
            send_property ("PlaybackStatus", new Variant.string (get_mpris_status(state)));
        }

        private string current_track_id () {
            // Stable per-track object path; falls back to index 0 when unknown.
            var index = _app.current_item;
            if (index < 0) index = 0;
            return "/org/mpris/MediaPlayer2/Track/%d".printf (index);
        }

        private void send_property (string name, Variant variant) {
            var builder = new VariantBuilder (new VariantType ("a{sv}"));
            builder.add ("{sv}", name, variant);
            send_properties (builder);
        }

        private void send_properties (VariantBuilder builder) {
            // Gst bus callbacks may arrive off the main thread; D-Bus
            // emission must happen on the main context to avoid deadlock.
            // We MUST end the builder here into a Variant before crossing threads,
            // because GVariantBuilder itself is not thread-safe.
            Variant props;
            try {
                props = builder.end ();
            } catch (Error e) {
                warning ("Failed to build MPRIS props: %s\n", e.message);
                return;
            }

            unowned Thread<void> self = Thread<void>.self ();
            if (self != _main_thread) {
                // Marshal to main loop. props is already frozen.
                Idle.add (() => {
                    send_variant (props);
                    return false;
                });
                return;
            }
            send_variant (props);
        }

        private void send_variant (Variant props) {
            // props is already a{sv}. Build empty as array as Variant, not builder.
            // Use @ to embed existing Variants: "(s@a{sv}@as)" -> string, Variant a{sv}, Variant as
            var invalid_builder = new VariantBuilder (new VariantType ("as"));
            var invalid_variant = invalid_builder.end (); // empty array

            try {
                _connection.emit_signal (
                    null,
                    "/org/mpris/MediaPlayer2",
                    "org.freedesktop.DBus.Properties",
                    "PropertiesChanged",
                    new Variant (
                        "(s@a{sv}@as)",
                        "org.mpris.MediaPlayer2.Player",
                        props,
                        invalid_variant
                    )
                );
            } catch (Error e) {
                warning ("Send MPRIS failed: %s\n", e.message);
            }
        }

        private string get_mpris_status (Gst.State state) {
            switch (state) {
                case Gst.State.PLAYING:
                    return "Playing";
                case Gst.State.PAUSED:
                    return "Paused";
                default:
                    return "Stopped";
            }
        }
    }

    [DBus (name = "org.mpris.MediaPlayer2")]
    public class MprisRoot : Object {
        private unowned Application _app;

        public MprisRoot (Application app) {
            _app = app;
        }

        public bool can_quit {
            get {
                return true;
            }
        }

        public bool can_raise {
            get {
                return true;
            }
        }

        public bool has_track_list {
            get {
                return false;
            }
        }

        public string desktop_entry {
            get {
                return _app.application_id;
            }
        }

        public string identity {
            get {
                return _app.name;
            }
        }

        public string[] supported_uri_schemes {
            owned get {
                return {"file", "smb"};
            }
        }

        public string[] supported_mime_types {
            owned get {
                return {"audio/*"};
            }
        }

        public void quit () throws Error {
            _app.quit ();
        }

        public void raise () throws Error {
            _app.activate ();
        }
    }
}
