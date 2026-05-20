namespace G4 {

    public struct LyricWord {
        public string text;
        public double start_sec;
        public double end_sec;
    }

    public struct LyricLine {
        public int64 time_ms;   // -1 = unsynced
        public string text;
        public LyricWord[] words;
        public bool is_bg;
    }

    public static bool lyrics_debug_enabled = false; // Set to false for release

    public class LyricsSheet : Object {
        private Application _app;
        private Gtk.ListBox _list_box;
        private Gtk.ScrolledWindow _scroll;
        private LyricLine[] _lines = {};
        private bool _is_synced = false;
        private int _current_index = -1;
        private Gtk.Label _provider_label;
        private Gtk.Label _offset_label;
        private Gtk.Box _offset_box;
        private Gtk.Box _box;
        private int64 _offset_ms = 0;
        private string _current_uri = "";
        private string _current_raw = "";
        public Adw.BottomSheet bottom_sheet;

        private const int PROVIDER_TIMEOUT_MS = 5000;
        private const int PROVIDER_FAIL_TIMEOUT_MS = 60000;
        private bool _timeout_triggered = false;
        private LyricsCandidate? _best_candidate = null;
        private string _best_candidate_provider = "";
        private double _best_candidate_score = 0.0;
        private bool _loading_completed = false;
        private GLib.Mutex _candidate_lock = GLib.Mutex ();
        private bool _is_instrumental = false;
        private bool _loading_in_progress = false;

        private static Soup.Session? _http_session = null;

        private static Soup.Session http_session () {
            if (_http_session == null)
                _http_session = new Soup.Session ();
            return (!)_http_session;
        }

        private void log (string msg) {
            GLib.message ("[Lyrics] %s", msg);
        }

        public LyricsSheet (Application app) {
            _app = app;

            _box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            _box.vexpand = true;
            _box.valign = Gtk.Align.FILL;

            var header = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
            header.add_css_class ("toolbar");
            header.margin_top = 24;
            header.hexpand = true;
            var title = new Gtk.Label (_("Lyrics"));
            title.add_css_class ("title-4");
            title.halign = Gtk.Align.CENTER;
            title.hexpand = true;
            header.append (title);
            _box.append (header);

            _provider_label = new Gtk.Label ("");
            _provider_label.add_css_class ("dim-label");
            _provider_label.add_css_class ("caption");
            _provider_label.margin_bottom = 4;
            _box.append (_provider_label);

            _list_box = new Gtk.ListBox ();
            _list_box.selection_mode = Gtk.SelectionMode.NONE;
            _list_box.vexpand = true;
            _list_box.valign = Gtk.Align.FILL;
            _list_box.margin_start = 16;
            _list_box.margin_end = 16;
            _list_box.margin_top = 8;
            _list_box.margin_bottom = 8;
            _list_box.row_activated.connect ((row) => {
                if (!_is_synced) return;
                var index = row.get_index ();
                if (index >= 0 && index < _lines.length && _lines[index].time_ms >= 0) {
                    var ms = _lines[index].time_ms - _offset_ms;
                    _app.player.seek (GstPlayer.from_second (ms / 1000.0));
                }
            });

            _scroll = new Gtk.ScrolledWindow ();
            _scroll.child = _list_box;
            _scroll.vexpand = true;
            _scroll.valign = Gtk.Align.FILL;
            _scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
            _scroll.vscrollbar_policy = Gtk.PolicyType.AUTOMATIC;
            _box.append (_scroll);

            // ── Bottom bar ───────────────────────────────────────────
            var bar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
            bar.add_css_class ("toolbar");
            bar.margin_start = 8;
            bar.margin_end = 8;

            var refresh_btn = new Gtk.Button ();
            refresh_btn.icon_name = "view-refresh-symbolic";
            refresh_btn.tooltip_text = _("Refresh lyrics");
            refresh_btn.add_css_class ("flat");
            refresh_btn.clicked.connect (() => {
                log ("Manual refresh requested, clearing cache");
                clear_cache (_current_uri);
                load_lyrics.begin ();
            });
            bar.append (refresh_btn);

            _offset_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 4);
            _offset_box.halign = Gtk.Align.CENTER;
            _offset_box.hexpand = true;

            var minus_btn = new Gtk.Button.with_label ("-100ms");
            minus_btn.add_css_class ("flat");
            minus_btn.add_css_class ("pill");
            minus_btn.clicked.connect (() => {
                _offset_ms -= 100;
                update_offset_label ();
                save_cache (_current_uri, _current_raw, _provider_label.label, _offset_ms);
            });

            _offset_label = new Gtk.Label ("0ms");
            _offset_label.width_chars = 7;
            _offset_label.halign = Gtk.Align.CENTER;

            var plus_btn = new Gtk.Button.with_label ("+100ms");
            plus_btn.add_css_class ("flat");
            plus_btn.add_css_class ("pill");
            plus_btn.clicked.connect (() => {
                _offset_ms += 100;
                update_offset_label ();
                save_cache (_current_uri, _current_raw, _provider_label.label, _offset_ms);
            });

            _offset_box.append (minus_btn);
            _offset_box.append (_offset_label);
            _offset_box.append (plus_btn);
            bar.append (_offset_box);

            var edit_btn = new Gtk.Button ();
            edit_btn.icon_name = "document-edit-symbolic";
            edit_btn.tooltip_text = _("Edit lyrics");
            edit_btn.add_css_class ("flat");
            edit_btn.clicked.connect (open_edit_dialog);
            bar.append (edit_btn);

            _box.append (bar);

            bottom_sheet = new Adw.BottomSheet ();
            bottom_sheet.sheet = _box;
            bottom_sheet.modal = true;

            bottom_sheet.notify["open"].connect (() => {
                if (bottom_sheet.open) {
                    update_box_height ();
                    if (_resize_timeout == 0) {
                        _resize_timeout = GLib.Timeout.add (100, on_resize_timeout);
                    }
                    _app.player.position_updated.connect (on_position_updated);
                    load_lyrics.begin ();
                } else {
                    if (_resize_timeout != 0) {
                        GLib.Source.remove (_resize_timeout);
                        _resize_timeout = 0;
                    }
                    _app.player.position_updated.disconnect (on_position_updated);
                }
            });

            app.music_changed.connect ((music) => {
                _current_index = -1;
                _offset_ms = 0;
                update_offset_label ();
                if (bottom_sheet.open)
                    load_lyrics.begin ();
            });

            apply_lyrics_css ();
        }

        public void open () {
            bottom_sheet.open = true;
        }

        private void update_box_height () {
            var win = bottom_sheet.get_root () as Gtk.Window;
            if (win != null) {
                var win_height = ((!)win).get_height ();
                var sheet_height = (int) (win_height * 0.85);
                _box.height_request = sheet_height;
            }
        }

        private uint _resize_timeout = 0;

        private bool on_resize_timeout () {
            if (bottom_sheet.open) {
                update_box_height ();
            }
            return true;
        }

        // ── Offset ───────────────────────────────────────────────────

        private void update_offset_label () {
            _offset_label.label = "%lldms".printf (_offset_ms);
        }

        // ── Position tracking ────────────────────────────────────────

        private void on_position_updated (Gst.ClockTime position) {
            if (!_is_synced) return;
            var sec = GstPlayer.to_second (position);
            var ms = (int64) (sec * 1000) + _offset_ms;
            var adj_sec = (double) ms / 1000.0;
            update_current_line (ms, adj_sec);
        }

        private void update_current_line (int64 ms, double sec) {
            if (_lines.length == 0) return;

            var new_index = 0;
            for (var i = 0; i < _lines.length; i++) {
                if (_lines[i].time_ms <= ms)
                    new_index = i;
                else
                    break;
            }

            var old_index = _current_index;
            update_word_highlights (new_index, sec);

            if (new_index == old_index) return;

            if (old_index >= 0 && old_index < _lines.length) {
                update_word_highlights (old_index, -1);
            }

            _current_index = new_index;

            var idx = 0;
            var child = _list_box.get_first_child ();
            while (child != null) {
                var next = ((!)child).get_next_sibling ();
                if (child is Gtk.ListBoxRow) {
                    var row = (Gtk.ListBoxRow)(!)child;
                    if (idx == _current_index) {
                        row.remove_css_class ("lyrics-row-inactive");
                        row.add_css_class ("lyrics-row-active");
                    } else {
                        row.remove_css_class ("lyrics-row-active");
                        row.add_css_class ("lyrics-row-inactive");
                    }
                    idx++;
                }
                child = next;
            }

            var active_row = _list_box.get_row_at_index (_current_index);
            if (active_row != null) {
                Idle.add (() => {
                    var r = (!)active_row;
                    var alloc = Gtk.Allocation ();
                    r.get_allocation (out alloc);
                    var adj = _scroll.vadjustment;
                    var target = alloc.y - (adj.page_size / 2.0) + (alloc.height / 2.0);
                    adj.set_value (target.clamp (adj.lower, adj.upper - adj.page_size));
                    return false;
                });
            }
        }

        private void update_word_highlights (int line_index, double sec) {
            var row = _list_box.get_row_at_index (line_index);
            if (row == null) return;
            var label = ((!)row).child as Gtk.Label;
            if (label == null) return;
            ((!)label).set_label (build_line_markup (_lines[line_index], sec));
        }

        private string build_line_markup (LyricLine line, double sec) {
            if (line.words.length == 0) {
                return Markup.escape_text (line.text.length > 0 ? line.text : "·");
            }
            var sb = new StringBuilder ();
            foreach (var word in line.words) {
                var escaped = Markup.escape_text (word.text);
                if (sec < 0) {
                    sb.append ("<span alpha='40%%'>%s</span> ".printf (escaped));
                } else if (sec >= word.start_sec && sec < word.end_sec) {
                    sb.append ("<span alpha='100%%' underline='single'>%s</span> ".printf (escaped));
                } else if (sec >= word.end_sec) {
                    sb.append ("<span alpha='65%%'>%s</span> ".printf (escaped));
                } else {
                    sb.append ("<span alpha='40%%'>%s</span> ".printf (escaped));
                }
            }
            return sb.str.strip ();
        }

        // ── UI state ─────────────────────────────────────────────────

        private void set_provider (string name) {
            _provider_label.label = name;
        }

        private void clear_list () {
            var child = _list_box.get_first_child ();
            while (child != null) {
                var next = ((!)child).get_next_sibling ();
                _list_box.remove ((!)child);
                child = next;
            }
        }

        private void populate_list () {
            clear_list ();
            _offset_box.visible = _is_synced;

            foreach (var line in _lines) {
                var synced = line.time_ms >= 0;
                var line_label = new Gtk.Label ("");
                line_label.use_markup = true;
                line_label.wrap = true;
                line_label.wrap_mode = Pango.WrapMode.WORD_CHAR;

                if (_is_synced) {
                    line_label.justify = Gtk.Justification.CENTER;
                    line_label.halign = Gtk.Align.CENTER;
                    line_label.margin_top = line.is_bg ? 2 : 8;
                    line_label.margin_bottom = line.is_bg ? 2 : 8;
                    line_label.add_css_class (line.is_bg ? "lyrics-word-bg" : "lyrics-word");
                    line_label.set_label (build_line_markup (line, -1.0));
                } else {
                    line_label.justify = Gtk.Justification.LEFT;
                    line_label.halign = Gtk.Align.START;
                    line_label.margin_top = 2;
                    line_label.margin_bottom = 2;
                    line_label.add_css_class ("lyrics-plain");
                    line_label.set_label (
                        Markup.escape_text (line.text.length > 0 ? line.text : ""));
                }

                var row = new Gtk.ListBoxRow ();
                row.child = line_label;
                row.activatable = synced && _is_synced;
                row.selectable = false;
                if (_is_synced)
                    row.add_css_class ("lyrics-row-inactive");
                _list_box.append (row);
            }
        }

        private void show_not_found () {
            clear_list ();
            _lines = {};
            _current_index = -1;
            var label = new Gtk.Label (_("Lyrics Not Found"));
            label.add_css_class ("dim-label");
            label.add_css_class ("title-4");
            label.margin_top = 48;
            var row = new Gtk.ListBoxRow ();
            row.child = label;
            row.activatable = false;
            row.selectable = false;
            _list_box.append (row);
        }

        private void show_instrumental () {
            clear_list ();
            _lines = {};
            _current_index = -1;
            var label = new Gtk.Label (_("Instrumental"));
            label.add_css_class ("dim-label");
            label.add_css_class ("title-4");
            label.margin_top = 48;
            var row = new Gtk.ListBoxRow ();
            row.child = label;
            row.activatable = false;
            row.selectable = false;
            _list_box.append (row);
        }

        private void show_loading () {
            set_provider ("");
            clear_list ();
            var spinner = new Gtk.Spinner ();
            spinner.spinning = true;
            spinner.margin_top = 48;
            var row = new Gtk.ListBoxRow ();
            row.child = spinner;
            row.activatable = false;
            row.selectable = false;
            _list_box.append (row);
        }

        // ── Edit dialog ──────────────────────────────────────────────

        private void open_edit_dialog () {
            var dialog = new Adw.Dialog ();
            dialog.title = _("Edit Lyrics");
            dialog.content_width = 600;
            dialog.content_height = 500;

            var toolbar_view = new Adw.ToolbarView ();
            var header_bar = new Adw.HeaderBar ();
            toolbar_view.add_top_bar (header_bar);

            var save_btn = new Gtk.Button.with_label (_("Save"));
            save_btn.add_css_class ("suggested-action");
            header_bar.pack_end (save_btn);

            var scroll = new Gtk.ScrolledWindow ();
            scroll.vexpand = true;
            scroll.hexpand = true;

            var text_view = new Gtk.TextView ();
            text_view.monospace = true;
            text_view.wrap_mode = Gtk.WrapMode.NONE;
            text_view.margin_start = 12;
            text_view.margin_end = 12;
            text_view.margin_top = 8;
            text_view.margin_bottom = 8;
            text_view.buffer.text = _current_raw;
            scroll.child = text_view;

            toolbar_view.content = scroll;
            dialog.child = toolbar_view;

            save_btn.clicked.connect (() => {
                var new_raw = text_view.buffer.text;
                _current_raw = new_raw;
                save_cache (_current_uri, new_raw, _provider_label.label, _offset_ms);
                _lines = {};
                _current_index = -1;
                _lines = parse_extended_lrc (new_raw);
                if (_lines.length == 0)
                    _lines = parse_ttml (new_raw);
                if (_lines.length == 0)
                    _lines = parse_lrc (new_raw);
                if (_lines.length > 0) {
                    _is_synced = true;
                    populate_list ();
                } else {
                    _lines = parse_plain (new_raw);
                    if (_lines.length > 0) {
                        _is_synced = false;
                        populate_list ();
                    } else {
                        show_not_found ();
                    }
                }
                dialog.close ();
            });

            var win = bottom_sheet.get_root () as Gtk.Window;
            dialog.present (win);
        }

        // ── Cache ────────────────────────────────────────────────────

        private string get_cache_path (string uri) {
            var cache_dir = GLib.Path.build_filename (
                GLib.Environment.get_user_cache_dir (), "semitone", "lyrics");
            DirUtils.create_with_parents (cache_dir, 0755);
            var hash = GLib.Checksum.compute_for_string (GLib.ChecksumType.MD5, uri, -1);
            return GLib.Path.build_filename (cache_dir, hash + ".json");
        }

        private void save_cache (string uri, string raw, string provider, int64 offset) {
            if (uri.length == 0) return;
            var path = get_cache_path (uri);
            var now = (int64) GLib.get_real_time () / 1000000;
            var escaped_uri = uri.replace ("\\", "\\\\").replace ("\"", "\\\"");
            var escaped_provider = provider.replace ("\"", "\\\"");
            var escaped_raw = raw.replace ("\\", "\\\\")
                                 .replace ("\"", "\\\"")
                                 .replace ("\n", "\\n")
                                 .replace ("\r", "");
            var json = "{\"uri\":\"%s\",\"provider\":\"%s\",\"fetched_at\":%lld,\"offset_ms\":%lld,\"lyrics\":\"%s\"}"
                .printf (escaped_uri, escaped_provider, now, offset, escaped_raw);
            try {
                FileUtils.set_contents (path, json);
                log ("Cache saved to %s".printf (path));
            } catch (Error e) {
                log ("Cache save failed: %s".printf (e.message));
            }
        }

        private bool load_cache (string uri) {
            if (uri.length == 0) return false;
            var path = get_cache_path (uri);
            string contents;
            try {
                FileUtils.get_contents (path, out contents);
            } catch (Error e) {
                log ("No cache for this track");
                return false;
            }

            var fetched_at = extract_json_int (contents, "fetched_at");
            var now = (int64) GLib.get_real_time () / 1000000;
            if (fetched_at > 0 && (now - fetched_at) > 7 * 24 * 3600) {
                log ("Cache is stale (>7 days), will re-fetch");
                return false;
            }

            var provider = extract_json_string (contents, "provider");
            var offset = extract_json_int (contents, "offset_ms");
            var raw = extract_json_string (contents, "lyrics");

            log ("Cache hit: provider='%s', offset=%lld, raw length=%d".printf (
                provider, offset, raw.length));

            if (raw.length == 0) {
                log ("Cache has empty lyrics, ignoring");
                return false;
            }

            _current_raw = raw;
            _offset_ms = offset;
            update_offset_label ();
            set_provider (provider + " (cached)");

            if (provider == "instrumental" || raw == "[instrumental]") {
                log ("Cache: track is marked as instrumental");
                _is_instrumental = true;
                _lines = {};
                show_instrumental ();
                return true;
            }

            if (try_parse_synced (raw)) {
                log ("Cache: synced parsed %d lines".printf (_lines.length));
                _is_synced = true;
            } else {
                _lines = parse_plain (raw);
                log ("Cache: plain parsed %d lines".printf (_lines.length));
                _is_synced = false;
            }

            return _lines.length > 0;
        }

        private void clear_cache (string uri) {
            if (uri.length == 0) return;
            var path = get_cache_path (uri);
            FileUtils.unlink (path);
            log ("Cache cleared: %s".printf (path));
        }

        private string extract_json_string (string json, string key) {
            var search = "\"" + key + "\":\"";
            var idx = json.index_of (search);
            if (idx < 0) return "";
            var start = idx + search.length;
            var sb = new StringBuilder ();
            var i = start;
            while (i < json.length) {
                var c = json[i];
                if (c == '\\' && i + 1 < json.length) {
                    var next = json[i + 1];
                    if (next == 'n') sb.append_c ('\n');
                    else if (next == '\\') sb.append_c ('\\');
                    else if (next == '"') sb.append_c ('"');
                    else sb.append_c (next);
                    i += 2;
                } else if (c == '"') {
                    break;
                } else {
                    sb.append_c (c);
                    i++;
                }
            }
            return sb.str;
        }

        private int64 extract_json_int (string json, string key) {
            var search = "\"" + key + "\":";
            var idx = json.index_of (search);
            if (idx < 0) return 0;
            var start = idx + search.length;
            var end = start;
            while (end < json.length && (json[end].isdigit () || json[end] == '-'))
                end++;
            return int64.parse (json.substring (start, end - start));
        }

        // ── Helpers ──────────────────────────────────────────────────

        private bool try_parse_synced (string raw) {
            _lines = parse_extended_lrc (raw);
            if (_lines.length > 0) return true;
            _lines = parse_ttml (raw);
            if (_lines.length > 0) return true;
            _lines = parse_lrc (raw);
            return _lines.length > 0;
        }

        private string? read_api_key_file (string filename) {
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

        // ── Lyrics quality scoring ────────────────────────────────────

        private struct LyricsCandidate {
            public string raw;
            public string provider;
            public LyricLine[] lines;
            public bool is_synced;
            public double score;
        }

        private double score_candidate (LyricLine[] lines, bool is_synced, string raw, int provider_index, string provider_name) {
            double provider_bonus = 0.0;
            if (provider_name == "PaxSenix")
                provider_bonus = 16.0;
            else if (provider_name == "SimpMusic")
                provider_bonus = 15.0;
            else if (provider_name == "BetterLyrics")
                provider_bonus = 14.0;
            else if (provider_name == "LRCLib")
                provider_bonus = 13.0;
            else if (provider_name == "NetEase")
                provider_bonus = 5.0;
            else if (provider_name == "Musixmatch")
                provider_bonus = 3.0;

            double format_score = 0.0;
            if (is_synced) {
                if (raw.contains ("<tt") || raw.contains ("<body"))
                    format_score = 40.0;
                else if (lines.length > 0 && lines[0].words.length > 0)
                    format_score = 40.0;
                else
                    format_score = 20.0;
            }

            int non_empty = 0;
            foreach (var l in lines)
                if (l.text.strip ().length > 0) non_empty++;
            double completion = lines.length > 0 ? (double) non_empty / lines.length : 0.0;
            double completion_score = completion * 10.0;

            double order_score = -(provider_index * 0.1);

            return provider_bonus + format_score + completion_score + order_score;
        }

        private void process_candidate (LyricsCandidate c) {
            _candidate_lock.lock ();
            bool is_best = false;

            if (_best_candidate == null || c.score > _best_candidate_score) {
                _best_candidate = c;
                _best_candidate_score = c.score;
                _best_candidate_provider = c.provider;
                is_best = true;
            }
            bool was_timeout = _timeout_triggered;
            _candidate_lock.unlock ();

            if (is_best) {
                log ("New best candidate: %s (score=%.1f)".printf (c.provider, c.score));

                if (was_timeout) {
                    log ("Updating display with better background result: %s".printf (c.provider));
                    _current_raw = c.raw;
                    _lines = c.lines;
                    _is_synced = c.is_synced;
                    set_provider (c.provider);
                    save_cache (_current_uri, c.raw, c.provider, 0);
                    populate_list ();
                }
            }
        }

        private void trigger_timeout () {
            _candidate_lock.lock ();
            if (_timeout_triggered) {
                _candidate_lock.unlock ();
                return;
            }
            _timeout_triggered = true;
            var best = _best_candidate;
            _candidate_lock.unlock ();

            log ("=== PROVIDER TIMEOUT (15s) ===");
            if (best != null) {
                var b = (!)best;
                log ("Using best so far: %s (score=%.1f, %d lines)".printf (
                    b.provider, b.score, b.lines.length));
                _current_raw = b.raw;
                _lines = b.lines;
                _is_synced = b.is_synced;
                set_provider (b.provider);
                save_cache (_current_uri, b.raw, b.provider, 0);
                populate_list ();
            } else {
                log ("No candidates yet, waiting...");
            }
        }

        // ── Main load ────────────────────────────────────────────────

        private async void load_lyrics () {
            if (_loading_in_progress) {
                log ("load_lyrics: already in progress, skipping");
                return;
            }
            _loading_in_progress = true;
            _lines = {};
            _is_synced = false;
            _current_index = -1;
            _current_raw = "";
            _offset_ms = 0;
            update_offset_label ();
            show_loading ();

            _timeout_triggered = false;
            _best_candidate = null;
            _best_candidate_provider = "";
            _best_candidate_score = 0.0;
            _loading_completed = false;

            var music = _app.current_music;
            if (music == null) {
                log ("No current music, aborting");
                _loading_in_progress = false;
                show_not_found ();
                return;
            }
            var m = (!)music;
            _current_uri = m.uri;

            log ("Loading lyrics for: '%s' by '%s' (album: '%s')".printf (
                m.title, m.artist, m.album));

            log ("Checking cache...");
            if (load_cache (_current_uri)) {
                log ("Loaded from cache, %d lines".printf (_lines.length));
                _loading_in_progress = false;
                populate_list ();
                return;
            }

            _is_instrumental = false;

            var test_file = File.new_for_path (
                GLib.Environment.get_home_dir () + "/Documents/LyricsTest.txt");
            if (test_file.query_exists ()) {
                try {
                    uint8[] data;
                    test_file.load_contents (null, out data, null);
                    var raw = (string) data;
                    if (raw.length > 0) {
                        log ("Using test file");
                        _current_raw = raw;
                        if (try_parse_synced (raw)) {
                            _is_synced = true;
                        } else {
                            _lines = parse_plain (raw);
                            _is_synced = false;
                        }
                        set_provider ("Test File");
                        populate_list ();
                        return;
                    }
                } catch (Error e) {}
            }

            var settings = _app.settings;
            bool prefer_synced  = settings.get_boolean ("lyrics-prefer-synced");
            bool auto_select    = settings.get_boolean ("lyrics-auto-select");
            bool plain_fallback = settings.get_boolean ("lyrics-plain-fallback");

            var order_str = settings.get_string ("lyrics-provider-order");
            if (order_str == "")
                order_str = "paxsenix,betterlyrics,simpmusic,lyricsplus,lrclib,netease,megalobiz,genius,musixmatch";
            string[] provider_order = order_str.split (",");

            var timeout_id = Timeout.add (PROVIDER_TIMEOUT_MS, () => {
                trigger_timeout ();
                return GLib.Source.REMOVE;
            });

            LyricsCandidate[] candidates = {};
            string? lrclib_plain_raw = null;

            for (int pi = 0; pi < provider_order.length; pi++) {
                var pid = provider_order[pi].strip ();

                if (pid == "paxsenix") {
                    if (!settings.get_boolean ("lyrics-paxsenix-enabled")) {
                        log ("PaxSenix: disabled"); continue;
                    }
                    log ("Trying PaxSenix...");
                    var duration_ms = (int) (GstPlayer.to_second (_app.player.duration) * 1000);
                    var raw = yield fetch_paxsenix (m.title, m.artist, duration_ms, m.album);
                    if (raw != null) {
                        LyricLine[] parsed = {};
                        bool synced = false;
                        parsed = parse_extended_lrc ((!)raw);
                        if (parsed.length > 0) {
                            synced = true;
                        } else {
                            parsed = parse_lrc ((!)raw);
                            if (parsed.length > 0) {
                                synced = true;
                            } else {
                                parsed = parse_plain ((!)raw);
                                synced = false;
                            }
                        }
                        if (parsed.length > 0) {
                            var score = score_candidate (parsed, synced, (!)raw, pi, "PaxSenix");
                            log ("PaxSenix: %d lines synced=%s score=%.1f".printf (
                                parsed.length, synced.to_string (), score));
                            LyricsCandidate c = { (!)raw, "PaxSenix", parsed, synced, score };
                            process_candidate (c);
                        }
                    } else {
                        log ("PaxSenix: no response");
                    }

                } else if (pid == "betterlyrics") {
                    if (!settings.get_boolean ("lyrics-betterlyrics-enabled")) {
                        log ("BetterLyrics: disabled"); continue;
                    }
                    log ("Trying BetterLyrics...");
                    var duration_sec = (int) (GstPlayer.to_second (_app.player.duration));
                    var raw = yield fetch_betterlyrics (m.title, m.artist, m.album, duration_sec);
                    if (raw != null) {
                        LyricLine[] parsed = {};
                        bool synced = false;
                        if (parse_extended_lrc ((!)raw).length > 0) {
                            parsed = parse_extended_lrc ((!)raw); synced = true;
                        } else if (parse_lrc ((!)raw).length > 0) {
                            parsed = parse_lrc ((!)raw); synced = true;
                        } else if (parse_plain ((!)raw).length > 0) {
                            parsed = parse_plain ((!)raw); synced = false;
                        }
                        if (parsed.length > 0) {
                            var score = score_candidate (parsed, synced, (!)raw, pi, "BetterLyrics");
                            log ("BetterLyrics: %d lines synced=%s, score=%.1f".printf (parsed.length, synced.to_string (), score));
                            LyricsCandidate c = { (!)raw, "BetterLyrics", parsed, synced, score };
                            process_candidate (c);
                        } else {
                            log ("BetterLyrics: parse returned 0 lines");
                        }
                    } else {
                        log ("BetterLyrics: no response");
                    }

                } else if (pid == "simpmusic") {
                    if (!settings.get_boolean ("lyrics-simpmusic-enabled")) {
                        log ("SimpMusic: disabled"); continue;
                    }
                    string? yt_id = get_youtube_id_from_all_metadata (m.uri);
                    if (yt_id == null) {
                        yt_id = extract_youtube_id (m.comment);
                        if (yt_id != null) {
                            log ("Found YouTube ID in comment field (fallback): %s".printf ((!)yt_id));
                        }
                    }
                    if (yt_id == null) {
                        log ("SimpMusic: no YouTube ID found in any metadata, skipping"); continue;
                    }
                    log ("SimpMusic: using YouTube ID %s".printf ((!)yt_id));
                    var raw = yield fetch_simpmusic ((!)yt_id);
if (raw != null) {
                        LyricLine[] parsed = {};
                        bool synced = false;
                        bool has_word_timing = ((!)raw).contains ("<") && ((!)raw).contains (">");
                        if (has_word_timing && parse_extended_lrc ((!)raw).length > 0) {
                            parsed = parse_extended_lrc ((!)raw); synced = true;
                        } else if (parse_lrc ((!)raw).length > 0) {
                            parsed = parse_lrc ((!)raw); synced = true;
                        } else if (parse_plain ((!)raw).length > 0) {
                            parsed = parse_plain ((!)raw); synced = false;
                        }
                        if (parsed.length > 0) {
                            var score = score_candidate (parsed, synced, (!)raw, pi, "SimpMusic");
                            log ("SimpMusic: %d lines synced=%s score=%.1f".printf (
                                parsed.length, synced.to_string (), score));
                            LyricsCandidate c = { (!)raw, "SimpMusic", parsed, synced, score };
                            process_candidate (c);
                        }
                    } else {
                        log ("SimpMusic: no response");
                    }

                } else if (pid == "lyricsplus") {
                    if (!settings.get_boolean ("lyrics-lyricsplus-enabled")) {
                        log ("LyricsPlus: disabled"); continue;
                    }
                    log ("Trying LyricsPlus...");
                    var duration_sec = (int) (GstPlayer.to_second (_app.player.duration));
                    var raw = yield fetch_lyricsplus (m.title, m.artist, m.album, duration_sec);
                    if (raw != null) {
                        LyricLine[] parsed = {};
                        bool synced = false;
                        if (parse_extended_lrc ((!)raw).length > 0) {
                            parsed = parse_extended_lrc ((!)raw); synced = true;
                        } else if (parse_lrc ((!)raw).length > 0) {
                            parsed = parse_lrc ((!)raw); synced = true;
                        } else if (parse_plain ((!)raw).length > 0) {
                            parsed = parse_plain ((!)raw); synced = false;
                        }
                        if (parsed.length > 0) {
                            var score = score_candidate (parsed, synced, (!)raw, pi, "LyricsPlus");
                            log ("LyricsPlus: %d lines synced=%s, score=%.1f".printf (parsed.length, synced.to_string (), score));
                            LyricsCandidate c = { (!)raw, "LyricsPlus", parsed, synced, score };
                            process_candidate (c);
                        } else {
                            log ("LyricsPlus: parse returned 0 lines");
                        }
                    } else {
                        log ("LyricsPlus: no response");
                    }

                } else if (pid == "lrclib") {
                    if (!settings.get_boolean ("lyrics-lrclib-enabled")) {
                        log ("LRCLib: disabled"); continue;
                    }
                    log ("Trying LRCLib...");
                    var result = yield fetch_lrclib (m.title, m.artist, m.album);
                    if (result != null) {
                        var lr = (!)result;
                        if (lr.instrumental) {
                            log ("LRCLib: track marked as instrumental, skipping other providers");
                            _is_instrumental = true;
                            trigger_timeout ();
                            break;
                        }
                        if (lr.synced.length > 0) {
                            var parsed = parse_lrc (lr.synced);
                            if (parsed.length > 0) {
                                var score = score_candidate (parsed, true, lr.synced, pi, "LRCLib");
                                log ("LRCLib synced: %d lines, score=%.1f".printf (parsed.length, score));
                                LyricsCandidate c = { lr.synced, "LRCLib", parsed, true, score };
                                process_candidate (c);
                            }
                        }
                        if (lr.plain.length > 0)
                            lrclib_plain_raw = lr.plain;
                    } else {
                        log ("LRCLib: no response");
                    }

                } else if (pid == "netease") {
                    if (!settings.get_boolean ("lyrics-netease-enabled")) {
                        log ("NetEase: disabled"); continue;
                    }
                    log ("Trying NetEase...");
                    var raw = yield fetch_netease (m.title, m.artist);
                    if (raw != null) {
                        var parsed = parse_lrc ((!)raw);
                        if (parsed.length > 0) {
                            var score = score_candidate (parsed, true, (!)raw, pi, "NetEase");
                            log ("NetEase: %d lines, score=%.1f".printf (parsed.length, score));
                            LyricsCandidate c = { (!)raw, "NetEase", parsed, true, score };
                            process_candidate (c);
                        }
                    } else {
                        log ("NetEase: no response");
                    }

                } else if (pid == "megalobiz") {
                    if (!settings.get_boolean ("lyrics-megalobiz-enabled")) {
                        log ("Megalobiz: disabled"); continue;
                    }
                    log ("Trying Megalobiz...");
                    var raw = yield fetch_megalobiz (m.title, m.artist);
                    if (raw != null) {
                        var parsed = parse_lrc ((!)raw);
                        bool synced = parsed.length > 0;
                        if (!synced) parsed = parse_plain ((!)raw);
                        if (parsed.length > 0) {
                            var score = score_candidate (parsed, synced, (!)raw, pi, "Megalobiz");
                            log ("Megalobiz: %d lines synced=%s score=%.1f".printf (
                                parsed.length, synced.to_string (), score));
                            LyricsCandidate c = { (!)raw, "Megalobiz", parsed, synced, score };
                            process_candidate (c);
                        }
                    } else {
                        log ("Megalobiz: no response");
                    }

                } else if (pid == "genius") {
                    if (!settings.get_boolean ("lyrics-genius-enabled")) {
                        log ("Genius: disabled"); continue;
                    }
                    log ("Trying Genius...");
                    var raw = yield fetch_genius (m.title, m.artist);
                    if (raw != null) {
                        var parsed = parse_plain ((!)raw);
                        if (parsed.length > 0) {
                            var score = score_candidate (parsed, false, (!)raw, pi, "Genius");
                            log ("Genius: %d lines, score=%.1f".printf (parsed.length, score));
                            LyricsCandidate c = { (!)raw, "Genius", parsed, false, score };
                            process_candidate (c);
                        }
                    } else {
                        log ("Genius: no response");
                    }

                } else if (pid == "musixmatch") {
                    if (!settings.get_boolean ("lyrics-musixmatch-enabled")) {
                        log ("Musixmatch: disabled"); continue;
                    }
                    var mm_key = read_api_key_file ("musixmatch-api-key");
                    if (mm_key == null) {
                        log ("Musixmatch: no API key, skipping"); continue;
                    }
                    log ("Trying Musixmatch...");
                    var raw = yield fetch_musixmatch (m.title, m.artist, (!)mm_key);
                    if (raw != null) {
                        var parsed = parse_plain ((!)raw);
                        if (parsed.length > 0) {
                            var score = score_candidate (parsed, false, (!)raw, pi, "Musixmatch");
                            log ("Musixmatch: %d lines, score=%.1f".printf (parsed.length, score));
                            LyricsCandidate c = { (!)raw, "Musixmatch", parsed, false, score };
                            process_candidate (c);
                        }
                    } else {
                        log ("Musixmatch: no response");
                    }
                }
            }

            if (plain_fallback && lrclib_plain_raw != null) {
                var parsed = parse_plain ((!)lrclib_plain_raw);
                if (parsed.length > 0) {
                    int lrclib_pi = 0;
                    for (int pi = 0; pi < provider_order.length; pi++)
                        if (provider_order[pi].strip () == "lrclib") { lrclib_pi = pi; break; }
                    var score = score_candidate (parsed, false, (!)lrclib_plain_raw, lrclib_pi, "LRCLib");
                    log ("LRCLib plain: %d lines, score=%.1f".printf (parsed.length, score));
                    LyricsCandidate c = { (!)lrclib_plain_raw, "LRCLib", parsed, false, score };
                    process_candidate (c);
                }
            }

            _candidate_lock.lock ();
            var best_candidate = _best_candidate;
            _loading_completed = true;
            _loading_in_progress = false;
            _candidate_lock.unlock ();

            Source.remove (timeout_id);

            if (best_candidate == null) {
                log ("All providers failed or returned nothing");
                set_provider ("");
                if (_is_instrumental) {
                    log ("Track is instrumental, caching and showing");
                    _current_raw = "[instrumental]";
                    save_cache (_current_uri, _current_raw, "instrumental", 0);
                    show_instrumental ();
                } else {
                    show_not_found ();
                }
                return;
            }
            var best = (!)best_candidate;

            log ("Best candidate: %s (score=%.1f, %d lines, synced=%s)".printf (
                best.provider, best.score, best.lines.length, best.is_synced.to_string ()));

            _current_raw = best.raw;
            _lines = best.lines;
            _is_synced = best.is_synced;
            set_provider (best.provider);
            save_cache (_current_uri, best.raw, best.provider, 0);
            populate_list ();
        }

        // ── HTTP ─────────────────────────────────────────────────────

        private async string? http_get (string url) {
            try {
                var msg = new Soup.Message ("GET", url);
                msg.request_headers.append ("User-Agent", "Semitone/1.0");
                var stream = yield http_session ().send_async (msg, GLib.Priority.DEFAULT, null);
                if (msg.status_code != 200) {
                    log ("HTTP %u for %s".printf (msg.status_code, url));
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
                log ("HTTP error for %s: %s".printf (url, e.message));
                return null;
            }
        }

        private async string? http_get_with_headers (string url, string[,] headers) {
            try {
                var msg = new Soup.Message ("GET", url);
                for (var i = 0; i < headers.length[0]; i++)
                    msg.request_headers.append (headers[i, 0], headers[i, 1]);
                var stream = yield http_session ().send_async (msg, GLib.Priority.DEFAULT, null);
                if (msg.status_code != 200) {
                    log ("HTTP %u for %s".printf (msg.status_code, url));
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
                log ("HTTP error for %s: %s".printf (url, e.message));
                return null;
            }
        }

        private async string? http_get_with_headers_allow_4xx (string url, string[,] headers) {
            try {
                var msg = new Soup.Message ("GET", url);
                for (var i = 0; i < headers.length[0]; i++)
                    msg.request_headers.append (headers[i, 0], headers[i, 1]);
                var stream = yield http_session ().send_async (msg, GLib.Priority.DEFAULT, null);
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
                    log ("HTTP %u for %s, body: %.200s".printf (msg.status_code, url, sb.str));
                }
                return sb.str;
            } catch (Error e) {
                log ("HTTP error for %s: %s".printf (url, e.message));
                return null;
            }
        }

        // ── PaxSenix ─────────────────────────────────────────────────

        private string paxsenix_clean_title (string title) {
            string cleaned = title.strip ();
            string[] patterns = {
                "\\s*\\(.*?(?:official|video|audio|lyrics?|visualizer|hd|hq|4k|remaster|remix|live|acoustic|version|edit|extended|radio|clean|explicit).*?\\)",
                "\\s*\\[.*?(?:official|video|audio|lyrics?|visualizer|hd|hq|4k|remaster|remix|live|acoustic|version|edit|extended|radio|clean|explicit).*?\\]",
                "\\s*\\|.*$",
                "\\s*-\\s*(?:official|video|audio|lyrics?|visualizer).*$",
                "\\s*\\(feat\\..*?\\)",
                "\\s*\\(ft\\..*?\\)",
                "\\s*feat\\..*$",
                "\\s*ft\\..*$",
                "\\s*\\([^)]*\\d{4}[^)]*\\)"
            };
            foreach (var pattern in patterns) {
                try {
                    var re = new Regex (pattern, RegexCompileFlags.CASELESS);
                    cleaned = re.replace (cleaned, -1, 0, "");
                } catch (RegexError e) {}
            }
            return cleaned.strip ();
        }

        private string paxsenix_clean_artist (string artist) {
            string[] separators = { " & ", " and ", ", ", " x ", " X ", " feat. ", " feat ",
                                    " ft. ", " ft ", " featuring ", " with " };
            var cleaned = artist.strip ();
            foreach (var sep in separators) {
                var lower = cleaned.down ();
                var sep_lower = sep.down ();
                var idx = lower.index_of (sep_lower);
                if (idx >= 0) {
                    cleaned = cleaned.substring (0, idx);
                    break;
                }
            }
            return cleaned.strip ();
        }

        private struct PaxSenixResult {
            public string id;
            public string display_name;
            public string display_artist;
            public int duration_ms;
            public double score;
        }

        private async PaxSenixResult[] paxsenix_search (string query) {
            var url = "https://lyrics.paxsenix.org/apple-music/search?q=%s".printf (
                Uri.escape_string (query, null, false));
            string[,] headers = { { "User-Agent", "Semitone/1.0" } };
            var body = yield http_get_with_headers (url, headers);
            if (body == null) return {};

            PaxSenixResult[] results = {};
            try {
                var parser = new Json.Parser ();
                parser.load_from_data ((!)body);
                var arr = parser.get_root ()?.get_array ();
                if (arr == null) return {};
                ((!)arr).foreach_element ((a, i, node) => {
                    var obj = node.get_object ();
                    if (obj == null) return;
                    var o = (!)obj;
                    var id          = o.has_member ("id")            ? o.get_string_member ("id")            : "";
                    var disp_name   = o.has_member ("displayName")   ? o.get_string_member ("displayName")   : "";
                    var disp_artist = o.has_member ("displayArtist") ? o.get_string_member ("displayArtist") : "";
                    int dur_ms      = o.has_member ("duration")      ? (int) o.get_int_member ("duration")   : 0;
                    if (id.length > 0) {
                        PaxSenixResult r = { id, disp_name, disp_artist, dur_ms, 0.0 };
                        results += r;
                    }
                });
            } catch (Error e) {
                log ("PaxSenix search parse error: %s".printf (e.message));
            }
            return results;
        }

        private PaxSenixResult[] paxsenix_score (PaxSenixResult[] results,
                                                  string title, string artist,
                                                  int duration_ms) {
            var cleanup_re_str = "\\s*\\(.*?\\)|\\s*\\[.*?\\]";
            Regex? cleanup_re = null;
            try { cleanup_re = new Regex (cleanup_re_str); } catch (RegexError e) {}

            var clean_title  = cleanup_re != null ? ((!)cleanup_re).replace (title, -1, 0, "").down ().strip ()
                                                  : title.down ().strip ();
            var clean_artist = paxsenix_clean_artist (artist).down ();
            bool target_is_remix = title.down ().contains ("remix");
            bool target_is_mixed = title.down ().contains ("mixed");

            PaxSenixResult[] scored = results;
            for (var i = 0; i < scored.length; i++) {
                double score = 0.0;
                var r = scored[i];

                if (r.duration_ms > 0) {
                    var diff = (r.duration_ms - duration_ms).abs ();
                    if (diff <= 2000)       score += 100.0;
                    else if (diff <= 5000)  score += 50.0;
                    else if (diff <= 10000) score += 10.0;
                    else                    score -= 50.0;
                }

                var result_clean = cleanup_re != null
                    ? ((!)cleanup_re).replace (r.display_name, -1, 0, "").down ().strip ()
                    : r.display_name.down ().strip ();
                if (result_clean == clean_title)
                    score += 80.0;
                else if (result_clean.contains (clean_title) || clean_title.contains (result_clean))
                    score += 40.0;

                bool result_is_remix = r.display_name.down ().contains ("remix");
                bool result_is_mixed = r.display_name.down ().contains ("mixed");
                if (result_is_remix && !target_is_remix) score -= 40.0;
                if (result_is_mixed && !target_is_mixed) score -= 60.0;

                var result_artist_lower = r.display_artist.down ();
                if (result_artist_lower.contains (clean_artist)) {
                    score += 50.0;
                } else {
                    foreach (var word in clean_artist.split (" ")) {
                        if (word.length > 2 && result_artist_lower.contains (word)) {
                            score += 25.0;
                            break;
                        }
                    }
                }

                scored[i].score = score;
            }

            for (var i = 1; i < scored.length; i++) {
                var key = scored[i];
                var j = i - 1;
                while (j >= 0 && scored[j].score < key.score) {
                    scored[j + 1] = scored[j];
                    j--;
                }
                scored[j + 1] = key;
            }

            PaxSenixResult[] filtered = {};
            foreach (var r in scored)
                if (r.score > 0) filtered += r;

            return filtered;
        }

        private async string? paxsenix_fetch_track (string id) {
            var url = "https://lyrics.paxsenix.org/apple-music/lyrics?id=%s".printf (
                Uri.escape_string (id, null, false));
            string[,] headers = { { "User-Agent", "Semitone/1.0" } };
            var body = yield http_get_with_headers (url, headers);
            if (body == null) return null;

            try {
                var parser = new Json.Parser ();
                parser.load_from_data ((!)body);
                var root_obj = parser.get_root ()?.get_object ();
                if (root_obj == null) return null;
                var obj = (!)root_obj;

                if (obj.has_member ("ttmlContent")) {
                    var ttml = obj.get_string_member ("ttmlContent");
                    if (ttml.length > 0) {
                        if (G4.lyrics_debug_enabled) {
                            print ("[DEBUG] PaxSenix: got ttmlContent, length=%d\n", ttml.length);
                        }
                        var lines = parse_ttml (ttml);
                        if (G4.lyrics_debug_enabled) {
                            print ("[DEBUG] PaxSenix: parse_ttml returned %d lines\n", lines.length);
                        }
                        if (lines.length > 0) {
                            var converted = lyrics_lines_to_string (lines);
                            log ("PaxSenix: using ttmlContent, converted to %s format, %d chars".printf (
                                converted.contains ("[") ? "LRC" : "plain", converted.length));
                            return converted;
                        }
                    }
                }

                if (obj.has_member ("elrcMultiPerson")) {
                    var elrc = obj.get_string_member ("elrcMultiPerson");
                    if (elrc.length > 0) {
                        log ("PaxSenix: using elrcMultiPerson");
                        return elrc;
                    }
                }
                if (obj.has_member ("elrc")) {
                    var elrc = obj.get_string_member ("elrc");
                    if (elrc.length > 0) {
                        log ("PaxSenix: using elrc");
                        return elrc;
                    }
                }

                if (obj.has_member ("content")) {
                    var content = obj.get_array_member ("content");
                    if (content == null) return null;
                    if (((!)content).get_length () > 0) {
                        var lrc_type = obj.has_member ("type") ? obj.get_string_member ("type") : "";
                        bool has_word_level = lrc_type == "Syllable";
                        log ("PaxSenix: using content array, type=%s has_word_level=%s".printf (
                            lrc_type, has_word_level.to_string ()));

                        var sb = new StringBuilder ();
                        ((!)content).foreach_element ((arr, idx, node) => {
                            var line_obj = node.get_object ();
                            if (line_obj == null) return;
                            var lo = (!)line_obj;

                            int64 time_ms = lo.has_member ("timestamp") ? lo.get_int_member ("timestamp") : 0;
                            bool is_bg    = lo.has_member ("background")   && lo.get_boolean_member ("background");
                            bool opp_turn = lo.has_member ("oppositeTurn") && lo.get_boolean_member ("oppositeTurn");

                            var words_arr = lo.has_member ("text") ? lo.get_array_member ("text") : null;
                            if (words_arr == null) return;
                            var wa = (!)words_arr;

                            var line_text_sb = new StringBuilder ();
                            wa.foreach_element ((wai, wi, wnode) => {
                                var w = wnode.get_object ();
                                if (w == null) return;
                                var wo = (!)w;
                                var wtext = wo.has_member ("text") ? wo.get_string_member ("text") : "";
                                if (wtext.length > 0) {
                                    if (line_text_sb.len > 0) line_text_sb.append_c (' ');
                                    line_text_sb.append (wtext);
                                }
                            });

                            var line_text = line_text_sb.str.strip ();
                            if (line_text.length == 0) return;

                            int64 mins   = time_ms / 1000 / 60;
                            int64 secs   = (time_ms / 1000) % 60;
                            int64 centis = (time_ms % 1000) / 10;

                            string agent_tag = "";
                            if (is_bg)        agent_tag = "{bg}";
                            else if (opp_turn) agent_tag = "{agent:v2}";

                            sb.append ("[%02lld:%02lld.%02lld]%s%s\n".printf (
                                mins, secs, centis, agent_tag, line_text));

                            if (has_word_level) {
                                var words_timing_sb = new StringBuilder ();
                                wa.foreach_element ((wai, wi, wnode) => {
                                    var w = wnode.get_object ();
                                    if (w == null) return;
                                    var wo = (!)w;
                                    var wtext  = wo.has_member ("text")      ? wo.get_string_member ("text")      : "";
                                    int64 wstart = wo.has_member ("timestamp") ? wo.get_int_member ("timestamp") : 0;
                                    int64 wend   = wo.has_member ("endtime")   ? wo.get_int_member ("endtime")   : wstart;
                                    if (wtext.length > 0) {
                                        if (words_timing_sb.len > 0) words_timing_sb.append_c ('|');
                                        words_timing_sb.append ("%s:%.3f:%.3f".printf (
                                            wtext,
                                            (double) wstart / 1000.0,
                                            (double) wend   / 1000.0));
                                    }
                                });
                                if (words_timing_sb.len > 0)
                                    sb.append ("<%s>\n".printf (words_timing_sb.str));
                            }
                        });

                        var result = sb.str.strip ();
                        if (G4.lyrics_debug_enabled) {
                            print ("[DEBUG] content array result: length=%d\n", result.length);
                        }
                        if (result.length > 0) return result;
                    }
                }

                if (obj.has_member ("plain")) {
                    var plain = obj.get_string_member ("plain");
                    if (plain.length > 0) {
                        log ("PaxSenix: using plain fallback");
                        return plain;
                    }
                }

                return null;
            } catch (Error e) {
                log ("PaxSenix fetch_track parse error: %s".printf (e.message));
                return null;
            }
        }

        private async string? fetch_paxsenix (string title, string artist,
                                               int duration_ms, string album) {
            var clean_title  = paxsenix_clean_title (title);
            var clean_artist = paxsenix_clean_artist (artist);

            log ("PaxSenix: title='%s' artist='%s' dur=%dms".printf (
                clean_title, clean_artist, duration_ms));

            string[] queries = {
                "%s %s".printf (clean_title, clean_artist)
            };
            if (album.length > 0)
                queries += "%s %s %s".printf (clean_title, clean_artist, album);

            PaxSenixResult[] scored = {};
            foreach (var query in queries) {
                if (scored.length > 0) break;
                log ("PaxSenix: searching '%s'".printf (query));
                var raw_results = yield paxsenix_search (query);
                if (raw_results.length > 0)
                    scored = paxsenix_score (raw_results, title, artist, duration_ms);
            }

            if (scored.length == 0) {
                log ("PaxSenix: no search results");
                return null;
            }

            log ("PaxSenix: %d scored results, trying top 3".printf (scored.length));

            string? plain_fallback = null;
            var limit = int.min (3, scored.length);
            for (var i = 0; i < limit; i++) {
                var r = scored[i];
                log ("PaxSenix: trying id=%s '%s' by '%s' (score=%.1f)".printf (
                    r.id, r.display_name, r.display_artist, r.score));
                var lrc = yield paxsenix_fetch_track (r.id);
                if (lrc == null) continue;

                bool has_word_timing = ((!)lrc).contains ("<tt")
                    || ((!)lrc).contains ("<body")
                    || (((!)lrc).contains ("<") && ((!)lrc).contains (":") && ((!)lrc).contains (">"));

                if (has_word_timing) {
                    log ("PaxSenix: word-timed result from '%s'".printf (r.display_name));
                    return lrc;
                }

                if (plain_fallback == null)
                    plain_fallback = lrc;
            }

            if (plain_fallback != null) {
                log ("PaxSenix: no word-timed result, using plain fallback");
                return plain_fallback;
            }

            log ("PaxSenix: all candidates returned null");
            return null;
        }

        // ── BetterLyrics ─────────────────────────────────────────────

        private async string? fetch_betterlyrics (string title, string artist, string album, int duration) {
            var url = "https://lyrics-api.boidu.dev/getLyrics?s=%s&a=%s&al=%s&d=%d".printf (
                Uri.escape_string (title, null, false),
                Uri.escape_string (artist, null, false),
                Uri.escape_string (album, null, false),
                duration);
            log ("BetterLyrics URL: %s".printf (url));
            var api_key = read_api_key_file ("betterlyrics-api-key");
            string[,] headers = {
                { "User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" },
                { "Accept", "application/json" }
            };
            if (api_key != null) {
                log ("BetterLyrics: using API key");
                string[,] new_headers = {
                    { "User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" },
                    { "Accept", "application/json" },
                    { "X-API-Key", (!)api_key }
                };
                headers = new_headers;
            } else {
                log ("BetterLyrics: no API key found - create ~/.config/semitone/betterlyrics-api-key to enable");
            }
            var body = yield http_get_with_headers_allow_4xx (url, headers);
            int body_len = body != null ? ((!)body).length : 0;
            int log_len = body_len > 500 ? 500 : body_len;
            log ("BetterLyrics response (len=%d): %s".printf (body_len, body != null ? ((!)body).substring (0, log_len) : "null"));
            if (body == null) return null;
            try {
                var parser = new Json.Parser ();
                parser.load_from_data ((!)body);
                var root_obj = parser.get_root ()?.get_object ();
                if (root_obj == null) return null;
                var obj = (!)root_obj;
                if (obj.has_member ("error")) {
                    var err_msg = obj.get_string_member ("error");
                    log ("BetterLyrics API error: %s".printf (err_msg));
                    if (err_msg.contains ("API key required")) {
                        log ("BetterLyrics: API key required for uncached songs. Create ~/.config/semitone/betterlyrics-api-key or try a more popular song");
                    }
                    return null;
                }
                if (obj.has_member ("ttml")) {
                    var ttml = obj.get_string_member ("ttml");
                    if (G4.lyrics_debug_enabled) {
                        print ("[DEBUG] BetterLyrics raw TTML (%d chars): %s\n", ttml.length, ttml.substring (0, int.min (500, ttml.length)));
                    }
                    var lines = parse_ttml (ttml);
                    if (lines.length > 0) {
                        var converted = lyrics_lines_to_extended_lrc (lines);
                        bool has_word_timing = false;
                        bool has_line_timing = false;
                        foreach (var l in lines) {
                            if (l.words.length > 0) { has_word_timing = true; break; }
                        }
                        if (!has_word_timing) {
                            foreach (var l in lines) {
                                if (l.time_ms >= 0) { has_line_timing = true; break; }
                            }
                        }
                        string format = has_word_timing ? "ExtendedLRC" : (has_line_timing ? "LRC" : "plain");
                        log ("BetterLyrics: converted TTML to %s format, %d chars".printf (format, converted.length));
                        return converted;
                    }
                    return null;
                }
                if (obj.has_member ("lyrics")) {
                    return obj.get_string_member ("lyrics");
                }
                return null;
            } catch (Error e) {
                log ("BetterLyrics: JSON parse error: %s".printf (e.message));
                return null;
            }
        }

        // ── LyricsPlus ────────────────────────────────────────────────

        private async string? fetch_lyricsplus (string title, string artist, string album, int duration) {
            string[] base_urls = {
                "https://lyricsplus.binimum.org",
                "https://lyricsplus.atomix.one",
                "https://lyricsplus-seven.vercel.app",
                "https://lyricsplus.prjktla.workers.dev",
                "https://lyrics-plus-backend.vercel.app"
            };
            string? result = null;
            foreach (var base_url in base_urls) {
                var url = "%s/v2/lyrics/get?title=%s&artist=%s&duration=%d&source=apple,lyricsplus,musixmatch,spotify,musixmatch-word".printf (
                    base_url,
                    Uri.escape_string (title, null, false),
                    Uri.escape_string (artist, null, false),
                    duration);
                if (album.length > 0) {
                    url += "&album=%s".printf (Uri.escape_string (album, null, false));
                }
                log ("LyricsPlus: trying %s".printf (base_url));
                var body = yield http_get (url);
                if (body != null && ((!)body).length > 0) {
                    try {
                        var parser = new Json.Parser ();
                        parser.load_from_data ((!)body);
                        var root_obj = parser.get_root ()?.get_object ();
                        if (root_obj != null) {
                            var obj = (!)root_obj;
                            var type = obj.has_member ("type") ? obj.get_string_member ("type") : "Line";
                            if (obj.has_member ("lyrics")) {
var lyrics_arr = obj.get_array_member ("lyrics");
                                    if (lyrics_arr != null && ((!)lyrics_arr).get_length () > 0) {
                                        log ("LyricsPlus: got lyrics from %s, type=%s".printf (base_url, type));
                                        result = convert_richsync_json ((!)lyrics_arr, type);
                                        break;
                                    }
                            }
                        }
                    } catch (Error e) {
                        log ("LyricsPlus: parse error from %s: %s".printf (base_url, e.message));
                    }
                }
            }
            return result;
        }

        private string convert_richsync_json (Json.Array lyrics_arr, string type) {
            var sb = new StringBuilder ();
            if (type == "Word") {
                int64 prev_time = -1;
                lyrics_arr.foreach_element ((arr, i, node) => {
                    var obj_n = node.get_object ();
                    if (obj_n == null) return;
                    var lyric_obj = (!)obj_n;

                    var time_ms = lyric_obj.get_int_member ("time");
                    var text = lyric_obj.get_string_member ("text");
                    if (text.length == 0) return;

                    bool new_line = (prev_time < 0) || (time_ms - prev_time > 2000);
                    if (new_line) {
                        if (sb.len > 0 && sb.str[sb.len - 1] != '\n') sb.append_c ('\n');
                        int64 mins = time_ms / 1000 / 60;
                        int64 secs = (time_ms / 1000) % 60;
                        int64 ms = (time_ms % 1000) / 10;
                        sb.append ("[%02lld:%02lld.%02lld]".printf (mins, secs, ms));
                        sb.append ("<%02lld:%02lld.%02lld>".printf (mins, secs, ms));
                    } else {
                        int64 w_mins = time_ms / 1000 / 60;
                        int64 w_secs = (time_ms / 1000) % 60;
                        int64 w_ms = (time_ms % 1000) / 10;
                        sb.append ("<%02lld:%02lld.%02lld>".printf (w_mins, w_secs, w_ms));
                    }
                    sb.append (text);
                    prev_time = time_ms;
                });
                if (sb.len > 0) sb.append_c ('\n');
            } else {
                lyrics_arr.foreach_element ((arr, i, node) => {
                    var obj_n = node.get_object ();
                    if (obj_n == null) return;
                    var lyric_obj = (!)obj_n;

                    var time_ms = lyric_obj.get_int_member ("time");
                    var text = lyric_obj.get_string_member ("text");
                    if (text.length == 0) return;

                    int64 mins = time_ms / 1000 / 60;
                    int64 secs = (time_ms / 1000) % 60;
                    int64 ms = (time_ms % 1000) / 10;
                    sb.append ("[%02lld:%02lld.%02lld]".printf (mins, secs, ms));
                    sb.append (text);
                    sb.append_c ('\n');
                });
            }
            return sb.str;
        }

        // ── Metadata-based YouTube ID Extraction ─────────────────────

        private string? get_all_string_metadata_text (string uri) {
            var file = GLib.File.new_for_uri (uri);
            if (!file.query_exists ()) {
                log ("File does not exist: %s".printf (uri));
                return null;
            }

            var tags = G4.parse_gst_tags (file);
            if (tags == null) {
                log ("No tags found for: %s".printf (uri));
                return null;
            }

            var sb = new GLib.StringBuilder ();
            var tag_list = (!)tags;

            string[] string_tags = {
                Gst.Tags.TITLE,
                Gst.Tags.ARTIST,
                Gst.Tags.ALBUM,
                Gst.Tags.ALBUM_ARTIST,
                Gst.Tags.GENRE,
                Gst.Tags.COMMENT,
                Gst.Tags.EXTENDED_COMMENT,
                Gst.Tags.COMPOSER,
                Gst.Tags.LYRICS,
                Gst.Tags.CONDUCTOR,
                Gst.Tags.PERFORMER,
                Gst.Tags.ENCODER,
                Gst.Tags.ENCODED_BY,
                Gst.Tags.COPYRIGHT,
                Gst.Tags.LICENSE,
                Gst.Tags.LOCATION,
                Gst.Tags.HOMEPAGE,
                Gst.Tags.DESCRIPTION,
                Gst.Tags.VERSION,
                Gst.Tags.ISRC,
                Gst.Tags.ORGANIZATION,
                Gst.Tags.CONTACT
            };

            foreach (var tag_name in string_tags) {
                var values = new GLib.GenericArray<string> ();
                G4.get_one_tag (tag_list, tag_name, values);

                foreach (var value in values) {
                    var trimmed = value.strip ();
                    if (trimmed.length > 0) {
                        sb.append (trimmed).append ("\n");
                        if (lyrics_debug_enabled) {
                            var truncated = trimmed.length > 100 ?
                                trimmed.substring (0, 100) + "..." : trimmed;
                            log ("Metadata: %s = %s".printf (tag_name, truncated));
                        }
                    }
                }
            }

            for (var i = 0; i < tag_list.n_tags (); i++) {
                var tag_name = tag_list.nth_tag_name (i);
                bool already_processed = false;
                foreach (var known_tag in string_tags) {
                    if (tag_name == known_tag) {
                        already_processed = true;
                        break;
                    }
                }

                if (!already_processed) {
                    var values = new GLib.GenericArray<string> ();
                    G4.get_one_tag (tag_list, tag_name, values);

                    foreach (var value in values) {
                        var trimmed = value.strip ();
                        if (trimmed.length > 0) {
                            sb.append (trimmed).append ("\n");
                            if (lyrics_debug_enabled) {
                                var truncated = trimmed.length > 100 ?
                                    trimmed.substring (0, 100) + "..." : trimmed;
                                log ("Additional metadata: %s = %s".printf (tag_name, truncated));
                            }
                        }
                    }
                }
            }

            if (sb.str.length > 0) {
                return sb.str;
            }
            return null;
        }

        private static string? extract_youtube_id_from_text (string text, out string? found_in_tag = null) {
            found_in_tag = null;

            if (text.length == 0) return null;

            try {
                var main_regex = "(?:youtu\\.be/|(?:music\\.)?youtube\\.com/(?:watch\\?v=|v/|embed/|shorts/))([A-Za-z0-9_-]{11})";
                var re = new GLib.Regex (main_regex, GLib.RegexCompileFlags.CASELESS | GLib.RegexCompileFlags.MULTILINE, 0);

                GLib.MatchInfo info;
                if (re.match (text, 0, out info)) {
                    var yt_id = info.fetch (1);
                    if (yt_id != null && ((!)yt_id).length == 11) {
                        return (!)yt_id;
                    }
                }

                var purl_regex = "purl=(?:https?://)?(?:www\\.)?(?:music\\.)?(?:youtube\\.com/watch\\?v=|youtu\\.be/)([A-Za-z0-9_-]{11})";
                var purl_re = new GLib.Regex (purl_regex, GLib.RegexCompileFlags.CASELESS | GLib.RegexCompileFlags.MULTILINE, 0);

                if (purl_re.match (text, 0, out info)) {
                    var yt_id = info.fetch (1);
                    if (yt_id != null && ((!)yt_id).length == 11) {
                        return (!)yt_id;
                    }
                }

                var param_regex = "(?:v=|/)([A-Za-z0-9_-]{11})(?:&|\\s|$|\")";
                var param_re = new GLib.Regex (param_regex, GLib.RegexCompileFlags.CASELESS | GLib.RegexCompileFlags.MULTILINE, 0);

                if (param_re.match (text, 0, out info)) {
                    var yt_id = info.fetch (1);
                    if (yt_id != null && ((!)yt_id).length == 11) {
                        return (!)yt_id;
                    }
                }

            } catch (GLib.RegexError e) {
                GLib.message ("[Lyrics] Regex error in YouTube ID extraction: %s".printf (e.message));
            }

            return null;
        }

        private string? get_youtube_id_from_all_metadata (string uri) {
            log ("Searching for YouTube ID in all metadata of: %s".printf (uri));

            var metadata_text = get_all_string_metadata_text (uri);
            if (metadata_text == null) {
                log ("No metadata text available");
                return null;
            }

            var text = (!)metadata_text;

            if (lyrics_debug_enabled) {
                var truncated = text.length > 500 ? text.substring (0, 500) + "..." : text;
                log ("Metadata text (%d chars):\n%s".printf (text.length, truncated));
            }

            string? found_in_tag = null;
            var yt_id = extract_youtube_id_from_text (text, out found_in_tag);

            if (yt_id != null) {
                log ("Found YouTube ID in metadata: %s".printf ((!)yt_id));
                return yt_id;
            }

            log ("No YouTube ID found in any metadata fields");
            return null;
        }

        // ── SimpMusic ────────────────────────────────────────────────

        private static string? extract_youtube_id (string comment) {
            string? dummy;
            return extract_youtube_id_from_text (comment, out dummy);
        }

        private async string? fetch_simpmusic (string video_id) {
            var url = "https://api-lyrics.simpmusic.org/v1/%s".printf (
                Uri.escape_string (video_id, null, false));
            var body = yield http_get (url);
            if (body == null) return null;
            try {
                var parser = new Json.Parser ();
                parser.load_from_data ((!)body);
                var root_obj = parser.get_root ()?.get_object ();
                if (root_obj == null) return null;
                var obj = (!)root_obj;
                if (!obj.get_boolean_member ("success")) return null;
                var data = obj.get_array_member ("data");
                if (data == null) return null;
                Json.Object? best = null;
                ((!)data).foreach_element ((arr, i, node) => {
                    if (best != null) return;
                    var track = node.get_object ();
                    if (track == null) return;
                    best = track;
                });
                if (best == null) return null;
                var b = (!)best;
                string? result = null;
                if (b.has_member ("richSyncLyrics"))
                    result = b.get_string_member ("richSyncLyrics");
                if ((result == null || ((!)result).length == 0) && b.has_member ("syncedLyrics"))
                    result = b.get_string_member ("syncedLyrics");
                if ((result == null || ((!)result).length == 0) && b.has_member ("plainLyrics"))
                    result = b.get_string_member ("plainLyrics");
                return result;
            } catch (Error e) {
                return null;
            }
        }

        // ── LRCLib ───────────────────────────────────────────────────

        private struct LrclibResult {
            public string synced;
            public string plain;
            public bool instrumental;
        }

        private async LrclibResult? fetch_lrclib (string title, string artist, string album) {
            var url = "https://lrclib.net/api/search?track_name=%s&artist_name=%s&album_name=%s".printf (
                Uri.escape_string (title, null, false),
                Uri.escape_string (artist, null, false),
                Uri.escape_string (album, null, false));
            var body = yield http_get (url);
            if (body == null) return null;
            try {
                var parser = new Json.Parser ();
                parser.load_from_data ((!)body);
                var root_arr = parser.get_root ()?.get_array ();
                if (root_arr == null) return null;
                var arr = (!)root_arr;
                if (arr.get_length () < 1) return null;
                var first_obj_node = arr.get_element (0);
                var first_obj = first_obj_node.get_object ();
                if (first_obj == null) return null;
                var obj = (!)first_obj;
                if (!obj.has_member ("trackName")) return null;
                bool instrumental = false;
                try {
                    if (obj.has_member ("instrumental"))
                        instrumental = obj.get_boolean_member ("instrumental");
                } catch {}
                string synced_val = "";
                string plain_val = "";
                string? raw_synced = obj.get_string_member ("syncedLyrics");
                if (raw_synced != null) synced_val = (!)raw_synced;
                string? raw_plain = obj.get_string_member ("plainLyrics");
                if (raw_plain != null) plain_val = (!)raw_plain;
                log ("LRCLib search: found %d results, first match instrumental=%s".printf (
                    (int) arr.get_length (), instrumental.to_string ()));
                LrclibResult result = { synced_val, plain_val, instrumental };
                return result;
            } catch (Error e) {
                log ("LRCLib parse error: %s".printf (e.message));
                return null;
            }
        }

        // ── NetEase ──────────────────────────────────────────────────

        private async string? fetch_netease (string title, string artist) {
            var search_url = "https://music.163.com/api/search/get?s=%s+%s&type=1&limit=1".printf (
                Uri.escape_string (title, null, false),
                Uri.escape_string (artist, null, false));
            string[,] headers = {
                { "User-Agent", "Mozilla/5.0" },
                { "Referer", "https://music.163.com" }
            };
            var search_body = yield http_get_with_headers (search_url, headers);
            if (search_body == null) return null;
            try {
                var parser = new Json.Parser ();
                parser.load_from_data ((!)search_body);
                var root = parser.get_root ()?.get_object ();
                if (root == null) return null;
                var result = ((!)root).get_object_member ("result");
                if (result == null) return null;
                var songs = ((!)result).get_array_member ("songs");
                if (songs == null) return null;
                if (((!)songs).get_length () == 0) return null;
                var song = ((!)songs).get_object_element (0);
                var id = song.get_int_member ("id");
                var lyric_url = "https://music.163.com/api/song/lyric?id=%lld&lv=1".printf (id);
                var lyric_body = yield http_get_with_headers (lyric_url, headers);
                if (lyric_body == null) return null;
                var parser2 = new Json.Parser ();
                parser2.load_from_data ((!)lyric_body);
                var lroot = parser2.get_root ()?.get_object ();
                if (lroot == null) return null;
                var lrc = ((!)lroot).get_object_member ("lrc");
                if (lrc == null) return null;
                var lyric = ((!)lrc).get_string_member ("lyric");
                if (lyric.strip ().length == 0) return null;
                return lyric;
            } catch (Error e) {
                log ("NetEase error: %s".printf (e.message));
                return null;
            }
        }

        // ── Megalobiz ────────────────────────────────────────────────

        private async string? fetch_megalobiz (string title, string artist) {
            var query = Uri.escape_string ("%s %s".printf (title, artist), null, false);
            var search_url = "https://www.megalobiz.com/search/all?qry=%s&display=more".printf (query);
            string[,] headers = {
                { "User-Agent", "Mozilla/5.0 (X11; Linux x86_64; rv:109.0) Gecko/20100101 Firefox/115.0" }
            };
            var search_body = yield http_get_with_headers (search_url, headers);
            if (search_body == null) return null;
            try {
                var re = new Regex ("/lrc/maker/(\\d+)");
                MatchInfo info;
                if (!re.match ((!)search_body, 0, out info)) return null;
                var lrc_id = info.fetch (1);
                var lrc_url = "https://www.megalobiz.com/lrc/maker/%s".printf ((!)lrc_id);
                var lrc_body = yield http_get_with_headers (lrc_url, headers);
                if (lrc_body == null) return null;
                var lrc_re = new Regex (
                    "<div[^>]*class=\"[^\"]*lrc[^\"]*\"[^>]*>([^<]*(?:<(?!/?div)[^<]*)*)</div>",
                    RegexCompileFlags.DOTALL);
                MatchInfo lrc_info;
                if (!lrc_re.match ((!)lrc_body, 0, out lrc_info)) {
                    var start = ((!)lrc_body).index_of ("[00:");
                    if (start < 0) return null;
                    return ((!)lrc_body).substring (start, int.min (8192, ((!)lrc_body).length - start));
                }
                return lrc_info.fetch (1)?.strip ();
            } catch (RegexError e) {
                log ("Megalobiz regex error: %s".printf (e.message));
                return null;
            }
        }

        // ── Genius ──────────────────────────────────────────────

        private async string? fetch_genius (string title, string artist) {
            var query = Uri.escape_string ("%s %s".printf (title, artist), null, false);
            var scrape_url = "https://genius.com/search?q=%s".printf (query);
            string[,] scrape_headers = {
                { "User-Agent", "Mozilla/5.0 (X11; Linux x86_64; rv:109.0) Gecko/20100101 Firefox/115.0" }
            };
            var page = yield http_get_with_headers (scrape_url, scrape_headers);
            if (page == null) return null;
            try {
                var re = new Regex ("href=\"(https://genius\\.com/[A-Za-z0-9-]+-lyrics)\"");
                MatchInfo info;
                if (!re.match ((!)page, 0, out info)) return null;
                string? song_url = info.fetch (1);
                if (song_url == null) return null;
                var song_page = yield http_get_with_headers ((!)song_url, scrape_headers);
                if (song_page == null) return null;
                var lyrics_re = new Regex (
                    "data-lyrics-container=\"true\"[^>]*>([^<]*(?:<(?!/?div)[^<]*)*)",
                    RegexCompileFlags.DOTALL);
                MatchInfo lyrics_info;
                var sb = new StringBuilder ();
                var pos = 0;
                while (lyrics_re.match_full ((!)song_page, -1, pos, 0, out lyrics_info)) {
                    var chunk = lyrics_info.fetch (1) ?? "";
                    var tag_re = new Regex ("<[^>]+>");
                    chunk = tag_re.replace (chunk, -1, 0, "");
                    sb.append (chunk.replace ("&#x27;", "'")
                                    .replace ("&amp;", "&")
                                    .replace ("&quot;", "\"")
                                    .replace ("&lt;", "<")
                                    .replace ("&gt;", ">").strip ());
                    sb.append_c ('\n');
                    int match_start, match_end;
                    lyrics_info.fetch_pos (0, out match_start, out match_end);
                    pos = match_end;
                }
                var result = sb.str.strip ();
                bool artist_match = result.down ().contains (artist.down ());
                bool title_match  = result.down ().contains (title.down ());
                if (!artist_match && !title_match) return null;
                if (result.length == 0) return null;
                return result;
            } catch (RegexError e) {
                log ("Genius regex error: %s".printf (e.message));
                return null;
            }
        }

        // ── Musixmatch ───────────────────────────────────────────────

        private async string? fetch_musixmatch (string title, string artist, string api_key) {
            var search_url = "https://api.musixmatch.com/ws/1.1/track.search?q_track=%s&q_artist=%s&apikey=%s&page_size=1&page=1&s_track_rating=desc".printf (
                Uri.escape_string (title, null, false),
                Uri.escape_string (artist, null, false),
                Uri.escape_string (api_key, null, false));
            var search_body = yield http_get (search_url);
            if (search_body == null) return null;
            try {
                var parser = new Json.Parser ();
                parser.load_from_data ((!)search_body);
                var root = parser.get_root ()?.get_object ();
                if (root == null) return null;
                var message = ((!)root).get_object_member ("message");
                if (message == null) return null;
                var body = ((!)message).get_object_member ("body");
                if (body == null) return null;
                var track_list = ((!)body).get_array_member ("track_list");
                if (track_list == null) return null;
                if (((!)track_list).get_length () == 0) return null;
                var track_obj = ((!)track_list).get_object_element (0);
                var track = track_obj.get_object_member ("track");
                if (track == null) return null;
                var track_id = ((!)track).get_int_member ("track_id");
                var lyrics_url = "https://api.musixmatch.com/ws/1.1/track.lyrics.get?track_id=%lld&apikey=%s".printf (
                    track_id, Uri.escape_string (api_key, null, false));
                var lyrics_body = yield http_get (lyrics_url);
                if (lyrics_body == null) return null;
                var parser2 = new Json.Parser ();
                parser2.load_from_data ((!)lyrics_body);
                var lroot = parser2.get_root ()?.get_object ();
                if (lroot == null) return null;
                var lmessage = ((!)lroot).get_object_member ("message");
                if (lmessage == null) return null;
                var lbody = ((!)lmessage).get_object_member ("body");
                if (lbody == null) return null;
                var lyrics_obj = ((!)lbody).get_object_member ("lyrics");
                if (lyrics_obj == null) return null;
                var lyrics_body_str = ((!)lyrics_obj).get_string_member ("lyrics_body");
                if (lyrics_body_str.strip ().length == 0) return null;
                return lyrics_body_str;
            } catch (Error e) {
                log ("Musixmatch error: %s".printf (e.message));
                return null;
            }
        }

        // ── TTML parser ──────────────────────────────────────────────

        private LyricLine[] parse_ttml (string ttml) {
            LyricLine[] result = {};
            if (!ttml.contains ("<tt") && !ttml.contains ("<body"))
                return result;
            var doc = Xml.Parser.parse_memory (ttml, ttml.length);
            if (doc == null) return result;
            unowned Xml.Node* root = doc->get_root_element ();
            if (root == null) { delete doc; return result; }

            unowned Xml.Node* body = null;
            for (var n = root->children; n != null; n = n->next) {
                if (n->name == "body") { body = n; break; }
            }
            if (body == null) { delete doc; return result; }

            bool has_line_timing = false;
            bool has_word_timing = false;

            for (var div = body->children; div != null; div = div->next) {
                if (div->type != Xml.ElementType.ELEMENT_NODE) continue;
                for (var p = div->children; p != null; p = p->next) {
                    if (p->type != Xml.ElementType.ELEMENT_NODE) continue;
                    if (p->name != "p") continue;
                    if (p->get_prop ("begin") != null) {
                        has_line_timing = true;
                    }
                    for (var span = p->children; span != null; span = span->next) {
                        if (span->type != Xml.ElementType.ELEMENT_NODE) continue;
                        if (span->name != "span") continue;
                        if (span->get_prop ("begin") != null && span->get_prop ("end") != null) {
                            has_word_timing = true;
                        }
                    }
                }
            }

            if (G4.lyrics_debug_enabled) {
                print ("[DEBUG] parse_ttml: word_timing=%s, line_timing=%s\n",
                       has_word_timing.to_string (), has_line_timing.to_string ());
            }

            if (has_word_timing) {
                return parse_ttml_word_synced (body);
            } else if (has_line_timing) {
                return parse_ttml_line_synced (body);
            } else {
                return parse_ttml_unsynced (body);
            }
        }

        private LyricLine[] parse_ttml_unsynced (unowned Xml.Node* body) {
            LyricLine[] result = {};
            for (var div = body->children; div != null; div = div->next) {
                if (div->type != Xml.ElementType.ELEMENT_NODE) continue;
                for (var p = div->children; p != null; p = p->next) {
                    if (p->type != Xml.ElementType.ELEMENT_NODE) continue;
                    if (p->name != "p") continue;
                    var text = p->get_content ();
                    if (text.strip ().length > 0) {
                        LyricWord[] empty_words = {};
                        LyricLine l = { -1, text.strip (), empty_words, false };
                        result += l;
                    }
                }
            }
            return result;
        }

        private LyricLine[] parse_ttml_line_synced (unowned Xml.Node* body) {
LyricLine[] result = {};
            for (var div = body->children; div != null; div = div->next) {
                if (div->type != Xml.ElementType.ELEMENT_NODE) continue;
                for (var p = div->children; p != null; p = p->next) {
                    if (p->type != Xml.ElementType.ELEMENT_NODE) continue;
                    if (p->name != "p") continue;

                    var begin_str = p->get_prop ("begin");
                    if (begin_str == null) continue;
                    var ms = ttml_time_to_ms ((!)begin_str);
                    if (ms < 0) continue;

                    var p_content = p->get_content ();

                    LyricWord[] main_words = {};
                    LyricWord[] bg_words = {};
                    var line_text_sb = new StringBuilder ();

                    for (var span = p->children; span != null; span = span->next) {
                        if (span->type != Xml.ElementType.ELEMENT_NODE) continue;
                        if (span->name != "span") continue;

                        var role = span->get_prop ("role");
                        bool is_this_bg = (role != null && (!)role == "x-bg");
                        var w_text = span->get_content ();

                        if (is_this_bg) {
                            for (var ws = span->children; ws != null; ws = ws->next) {
                                if (ws->type != Xml.ElementType.ELEMENT_NODE) continue;
                                var w_begin = ws->get_prop ("begin");
                                var w_end = ws->get_prop ("end");
                                var w_content = ws->get_content ();
                                if (w_begin != null && w_end != null && w_content.length > 0) {
                                    LyricWord w = {
                                        w_content,
                                        ttml_time_to_ms ((!)w_begin) / 1000.0,
                                        ttml_time_to_ms ((!)w_end) / 1000.0
                                    };
                                    bg_words += w;
                                }
                            }
                        } else {
                            var w_begin = span->get_prop ("begin");
                            var w_end = span->get_prop ("end");
                            if (w_begin != null && w_end != null && w_text.length > 0) {
                                LyricWord w = {
                                    w_text,
                                    ttml_time_to_ms ((!)w_begin) / 1000.0,
                                    ttml_time_to_ms ((!)w_end) / 1000.0
                                };
                                main_words += w;
                                line_text_sb.append (w_text);
                                line_text_sb.append_c (' ');
                            }
                        }
                    }

                    if (line_text_sb.len == 0 && p_content.length > 0) {
                        line_text_sb.append (p_content);
                    }

                    var line_text = line_text_sb.str.strip ();
                    if (line_text.length == 0) continue;

                    LyricLine main_line = { ms, line_text, main_words, false };
                    result += main_line;

                    if (bg_words.length > 0) {
                        var bg_text_sb = new StringBuilder ();
                        foreach (var bw in bg_words) {
                            bg_text_sb.append (bw.text);
                            bg_text_sb.append_c (' ');
                        }
                        LyricLine bg_line = { ms, bg_text_sb.str.strip (), bg_words, true };
                        result += bg_line;
                    }
                }
            }
            return result;
        }

        private LyricLine[] parse_ttml_word_synced (unowned Xml.Node* body) {
            LyricLine[] result = {};
            for (var div = body->children; div != null; div = div->next) {
                if (div->type != Xml.ElementType.ELEMENT_NODE) continue;
                for (var p = div->children; p != null; p = p->next) {
                    if (p->type != Xml.ElementType.ELEMENT_NODE) continue;
                    if (p->name != "p") continue;

                    var begin_str = p->get_prop ("begin");
                    if (begin_str == null) continue;
                    var line_ms = ttml_time_to_ms ((!)begin_str);
                    if (line_ms < 0) continue;

                    LyricWord[] words = {};
                    var line_text_sb = new StringBuilder ();

                    for (var span = p->children; span != null; span = span->next) {
                        if (span->type != Xml.ElementType.ELEMENT_NODE) continue;
                        if (span->name != "span") continue;

                        var role = span->get_prop ("role");
                        if (role != null && (!)role == "x-bg") continue;

                        var w_begin_str = span->get_prop ("begin");
                        var w_end_str = span->get_prop ("end");
                        var w_text = span->get_content ();

                        if (w_begin_str != null && w_end_str != null && w_text.length > 0) {
                            var w_begin = ttml_time_to_ms ((!)w_begin_str);
                            var w_end = ttml_time_to_ms ((!)w_end_str);
                            if (w_begin >= 0 && w_end >= 0) {
                                LyricWord w = { w_text, w_begin / 1000.0, w_end / 1000.0 };
                                words += w;
                                line_text_sb.append (w_text);
                                line_text_sb.append_c (' ');
                            }
                        }
                    }

                    for (var i = 0; i < words.length - 1; i++)
                        words[i].end_sec = words[i + 1].start_sec;
                    if (words.length > 0)
                        words[words.length - 1].end_sec = words[words.length - 1].start_sec + 3.0;

                    if (words.length > 0 || line_text_sb.str.strip ().length > 0) {
                        LyricLine l = { line_ms, line_text_sb.str.strip (), words, false };
                        result += l;
                    }
                }
            }
            return result;
        }

        private string lyrics_lines_to_string (LyricLine[] lines) {
            var sb = new StringBuilder ();
            bool has_timing = false;
            foreach (var l in lines) {
                if (l.time_ms >= 0) {
                    has_timing = true;
                    break;
                }
            }
            if (has_timing) {
                foreach (var l in lines) {
                    if (l.time_ms < 0) continue;
                    int64 mins = l.time_ms / 1000 / 60;
                    int64 secs = (l.time_ms / 1000) % 60;
                    int64 ms = (l.time_ms % 1000) / 10;
                    sb.append ("[%02lld:%02lld.%02lld]".printf (mins, secs, ms));
                    sb.append (l.text);
                    sb.append_c ('\n');
                }
            } else {
                foreach (var l in lines) {
                    if (l.text.length > 0) {
                        sb.append (l.text);
                        sb.append_c ('\n');
                    }
                }
            }
            return sb.str;
        }

        private string lyrics_lines_to_extended_lrc (LyricLine[] lines) {
            var sb = new StringBuilder ();
            bool has_word_timing = false;
            foreach (var l in lines) {
                if (l.words.length > 0) {
                    has_word_timing = true;
                    break;
                }
            }
            if (!has_word_timing) {
                return lyrics_lines_to_string (lines);
            }
            foreach (var l in lines) {
                if (l.time_ms < 0) continue;
                int64 mins = l.time_ms / 1000 / 60;
                int64 secs = (l.time_ms / 1000) % 60;
                int64 ms = (l.time_ms % 1000) / 10;
                sb.append ("[%02lld:%02lld.%02lld]".printf (mins, secs, ms));
                if (l.words.length > 0) {
                    foreach (var w in l.words) {
                        int64 w_mins = (int64) w.start_sec / 60;
                        int64 w_secs = (int64) w.start_sec % 60;
                        int64 w_ms = (int64) ((w.start_sec - (int64) w.start_sec) * 100);
                        sb.append ("<%02lld:%02lld.%02lld>".printf (w_mins, w_secs, w_ms));
                        sb.append (w.text);
                    }
                } else {
                    sb.append (l.text);
                }
                sb.append_c ('\n');
            }
            return sb.str;
        }

        private int64 ttml_time_to_ms (string t) {
            var parts = t.split (":");
            if (parts.length == 3) {
                var h = int.parse (parts[0]);
                var m = int.parse (parts[1]);
                var s = double.parse (parts[2]);
                return (int64) ((h * 3600 + m * 60 + s) * 1000);
            } else if (parts.length == 2) {
                var m = int.parse (parts[0]);
                var s = double.parse (parts[1]);
                return (int64) ((m * 60 + s) * 1000);
            } else {
                return (int64) (double.parse (t) * 1000);
            }
        }

        // ── Metadata tag stripping ───────────────────────────────────

        private string strip_lrc_metadata (string lrc) {
            var sb = new StringBuilder ();
            foreach (var line in lrc.split ("\n")) {
                var ls = line.strip ();
                if (ls.has_prefix ("[offset:") || ls.has_prefix ("[ti:") ||
                    ls.has_prefix ("[ar:")     || ls.has_prefix ("[al:") ||
                    ls.has_prefix ("[by:")     || ls.has_prefix ("[length:") ||
                    ls.has_prefix ("[re:")     || ls.has_prefix ("[ve:"))
                    continue;
                sb.append (ls);
                sb.append_c ('\n');
            }
            return sb.str;
        }

        // ── Extended LRC parser ────────────────────────────────────

        private LyricLine[] parse_extended_lrc (string lrc) {
            if (!lrc.contains ("<")) return {};

            LyricLine[] result = {};
            foreach (var raw_line in strip_lrc_metadata (lrc).split ("\n")) {
                var line = raw_line.strip ();
                if (line.length < 5 || line[0] != '[') continue;

                var close = line.index_of_char (']');
                if (close < 0) continue;

                var line_ts = line.substring (1, close - 1);
                var line_ms = parse_timestamp (line_ts);
                if (line_ms < 0) continue;

                var rest = line.substring (close + 1);

                LyricWord[] words = {};
                var text_sb = new StringBuilder ();
                var pos = 0;

                while (pos < rest.length) {
                    if (rest[pos] == '<') {
                        var end = rest.index_of_char ('>', pos);
                        if (end < 0) break;
                        var ts_str = rest.substring (pos + 1, end - pos - 1);
                        var word_start_ms = parse_timestamp (ts_str);
                        pos = end + 1;

                        var word_start = pos;
                        while (pos < rest.length && rest[pos] != '<')
                            pos++;
                        var word_text = rest.substring (word_start, pos - word_start);
                        word_text = decode_html_entities (word_text).strip ();

                        if (word_text.length > 0 && word_start_ms >= 0) {
                            LyricWord w = { word_text, word_start_ms / 1000.0, 0.0 };
                            words += w;
                            text_sb.append (word_text);
                            text_sb.append_c (' ');
                        }
                    } else {
                        pos++;
                    }
                }

                for (var i = 0; i < words.length - 1; i++)
                    words[i].end_sec = words[i + 1].start_sec;
                if (words.length > 0)
                    words[words.length - 1].end_sec = words[words.length - 1].start_sec + 3.0;

                LyricLine l = { line_ms, text_sb.str.strip (), words, false };
                result += l;
            }
            return result;
        }

        // ── LRC parser ───────────────────────────────────────────────

        private LyricLine[] parse_lrc (string lrc) {
            LyricLine[] result = {};
            var raw_lines = strip_lrc_metadata (lrc).split ("\n");
            var i = 0;
            while (i < raw_lines.length) {
                var line = raw_lines[i].strip ();
                i++;

                if (line.length < 5 || line[0] != '[') continue;

                var close = line.index_of_char (']');
                if (close < 0) continue;

                var timestamp = line.substring (1, close - 1);
                var rest = line.substring (close + 1).strip ();

                var is_bg = false;
                if (rest.has_prefix ("{")) {
                    var tag_end = rest.index_of_char ('}');
                    if (tag_end >= 0) {
                        var tag = rest.substring (1, tag_end - 1);
                        is_bg = tag == "bg";
                        rest = rest.substring (tag_end + 1).strip ();
                    }
                }

                var ms = parse_timestamp (timestamp);
                if (ms < 0) continue;

                LyricWord[] words = {};
                if (i < raw_lines.length && raw_lines[i].strip ().has_prefix ("<")) {
                    words = parse_word_timings (raw_lines[i].strip ());
                    i++;
                }

                var decoded_rest = decode_html_entities (rest);
                LyricLine l = { ms, decoded_rest, words, is_bg };
                result += l;
            }
            return result;
        }

        // ── Plain lyrics parser ──────────────────────────────────────

        private LyricLine[] parse_plain (string text) {
            LyricLine[] result = {};
            foreach (var line in text.split ("\n")) {
                var trimmed = line.strip ();
                if (trimmed.length > 0 && trimmed[0] == '[' && parse_timestamp (
                        trimmed.substring (1, trimmed.index_of_char (']') > 0
                            ? trimmed.index_of_char (']') - 1 : 0)) >= 0)
                    continue;
                LyricWord[] empty_words = {};
                LyricLine l = { -1, trimmed, empty_words, false };
                result += l;
            }
            var start = 0;
            var end = result.length - 1;
            while (start <= end && result[start].text.length == 0) start++;
            while (end >= start && result[end].text.length == 0) end--;
            return result[start:end + 1];
        }

        private LyricWord[] parse_word_timings (string timing_line) {
            LyricWord[] words = {};
            var inner = timing_line;
            if (inner.has_prefix ("<")) inner = inner.substring (1);
            if (inner.has_suffix (">")) inner = inner.substring (0, inner.length - 1);

            var parts = inner.split ("|");
            foreach (var part in parts) {
                var segments = part.split (":");
                if (segments.length >= 3) {
                    var text = decode_html_entities (segments[0]);
                    LyricWord w = { text, double.parse (segments[1]), double.parse (segments[2]) };
                    words += w;
                }
            }
            return words;
        }

        private string decode_html_entities (string s) {
            return s.replace ("&#x27;", "'")
                    .replace ("&quot;", "\"")
                    .replace ("&amp;", "&")
                    .replace ("&lt;", "<")
                    .replace ("&gt;", ">");
        }

        private int64 parse_timestamp (string ts) {
            var parts = ts.split (":");
            if (parts.length != 2) return -1;
            var minutes = int.parse (parts[0]);
            var sec_parts = parts[1].split (".");
            if (sec_parts.length != 2) return -1;
            var seconds = int.parse (sec_parts[0]);
            var centis = int.parse (sec_parts[1]);
            return (int64) (minutes * 60 * 1000 + seconds * 1000 + centis * 10);
        }

        // ── CSS ──────────────────────────────────────────────────────

        private void apply_lyrics_css () {
            var css = new Gtk.CssProvider ();
            css.load_from_string ("""
                .lyrics-row-inactive {
                    opacity: 0.35;
                }
                .lyrics-row-active {
                    opacity: 1.0;
                }
                .lyrics-word {
                    font-size: 20px;
                    font-weight: bold;
                    padding: 1px 8px;
                }
                .lyrics-word-bg {
                    font-size: 15px;
                    font-weight: normal;
                    padding: 1px 8px;
                }
                .lyrics-plain {
                    font-size: 15px;
                    padding: 1px 4px;
                }
            """);
            var display = Gdk.Display.get_default ();
            if (display != null) {
                Gtk.StyleContext.add_provider_for_display (
                    (!)display, css,
                    Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
                );
            }
        }
    }
}
