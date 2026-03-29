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
                    // Subtract offset: time_ms is the lyric timestamp, but playback
                    // position + offset is what the renderer compares against, so
                    // seek to (time_ms - offset) to land exactly on that line.
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
            
            // Reset the previous line to "not selected" formatting
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
            // Show offset bar only for synced lyrics
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
                    // Plain unsynced — left aligned, normal size
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
                _lines = parse_rich_sync (new_raw);
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

        // Returns true and populates _lines if any synced format parsed successfully
        private bool try_parse_synced (string raw) {
            _lines = parse_rich_sync (raw);
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

        // ── Main load ────────────────────────────────────────────────

        // ── Lyrics quality scoring ───────────────────────────────────
        //
        // Format tier (base score, higher = better):
        //   richsync (word-timed LRC)  = 40
        //   ttml (word-timed XML)      = 40
        //   lrc (line-timed)           = 20
        //   plain                      =  0
        //
        // Completion bonus: +0..10 based on (lines / track_duration_secs * 4) capped at 10.
        // Provider order bonus: -0.1 per position in user's priority list (tie-breaker only).
        //
        // The result with the highest total score wins.

        private struct LyricsCandidate {
            public string raw;
            public string provider;
            public LyricLine[] lines;
            public bool is_synced;
            public double score;
        }

        private double score_candidate (LyricLine[] lines, bool is_synced, string raw, int provider_index, string provider_name) {
            // Provider bonus - prefer specific high-quality providers
            double provider_bonus = 0.0;
            if (provider_name == "SimpMusic")
                provider_bonus = 15.0;
            else if (provider_name == "BetterLyrics")
                provider_bonus = 14.0;
            else if (provider_name == "LRCLib")
                provider_bonus = 13.0;
            else if (provider_name == "NetEase")
                provider_bonus = 5.0;
            else if (provider_name == "Musixmatch")
                provider_bonus = 3.0;

            // Format tier
            double format_score = 0.0;
            if (is_synced) {
                if (raw.contains ("<tt") || raw.contains ("<body"))
                    format_score = 40.0;   // TTML
                else if (lines.length > 0 && lines[0].words.length > 0)
                    format_score = 40.0;   // richsync (word-timed LRC)
                else
                    format_score = 20.0;   // plain LRC
            }

            // Completion bonus: ratio of non-empty lines, scaled 0-10
            int non_empty = 0;
            foreach (var l in lines)
                if (l.text.strip ().length > 0) non_empty++;
            double completion = lines.length > 0 ? (double) non_empty / lines.length : 0.0;
            double completion_score = completion * 10.0;

            // Provider order tie-breaker (lower index = slightly higher score)
            double order_score = -(provider_index * 0.1);

            return provider_bonus + format_score + completion_score + order_score;
        }

        private async void load_lyrics () {
            _lines = {};
            _is_synced = false;
            _current_index = -1;
            _current_raw = "";
            _offset_ms = 0;
            update_offset_label ();
            show_loading ();

            var music = _app.current_music;
            if (music == null) {
                log ("No current music, aborting");
                show_not_found ();
                return;
            }
            var m = (!)music;
            _current_uri = m.uri;

            log ("Loading lyrics for: '%s' by '%s' (album: '%s')".printf (
                m.title, m.artist, m.album));

            // 1. Cache
            log ("Checking cache...");
            if (load_cache (_current_uri)) {
                log ("Loaded from cache, %d lines".printf (_lines.length));
                populate_list ();
                return;
            }

            // Track if any provider found this track to be instrumental
            bool is_instrumental = false;

            // 2. Local test file (dev only)
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
            bool prefer_synced   = settings.get_boolean ("lyrics-prefer-synced");
            bool auto_select     = settings.get_boolean ("lyrics-auto-select");
            bool plain_fallback  = settings.get_boolean ("lyrics-plain-fallback");

            // Build provider order from settings
            var order_str = settings.get_string ("lyrics-provider-order");
            if (order_str == "")
                order_str = "simpmusic,lrclib,netease,lyricsovh,megalobiz,genius,musixmatch";
            string[] provider_order = order_str.split (",");

            // ── Collect candidates from all enabled providers ─────────
            //
            // We gather every result, score each one, then pick the winner.
            // LRCLib synced + plain come from one request so we handle that together.

            LyricsCandidate[] candidates = {};
            string? lrclib_plain_raw = null;  // held separately — only used if plain_fallback

            // Helper: try to parse raw into lines, detect format, score, add candidate
            // (defined inline via a local helper method below)

            // Iterate providers in user-defined order
            for (int pi = 0; pi < provider_order.length; pi++) {
                var pid = provider_order[pi].strip ();

                if (pid == "betterlyrics") {
                    if (!settings.get_boolean ("lyrics-betterlyrics-enabled")) {
                        log ("BetterLyrics: disabled"); continue;
                    }
                    log ("Trying BetterLyrics...");
                    var raw = yield fetch_betterlyrics (m.title, m.artist, m.album, 0);
                    if (raw != null) {
                        var parsed = parse_ttml ((!)raw);
                        if (parsed.length > 0) {
                            var score = score_candidate (parsed, true, (!)raw, pi, "BetterLyrics");
                            log ("BetterLyrics: %d lines, score=%.1f".printf (parsed.length, score));
                            LyricsCandidate c = { (!)raw, "BetterLyrics", parsed, true, score };
                            candidates += c;
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
                    var yt_id = extract_youtube_id (m.comment);
                    if (yt_id == null) {
                        log ("SimpMusic: no YouTube ID in comment tag, skipping"); continue;
                    }
                    log ("Trying SimpMusic (%s)...".printf ((!)yt_id));
                    var raw = yield fetch_simpmusic ((!)yt_id);
                    if (raw != null) {
                        LyricLine[] parsed = {};
                        bool synced = false;
                        if (parse_rich_sync ((!)raw).length > 0) {
                            parsed = parse_rich_sync ((!)raw); synced = true;
                        } else if (parse_ttml ((!)raw).length > 0) {
                            parsed = parse_ttml ((!)raw); synced = true;
                        } else if (parse_lrc ((!)raw).length > 0) {
                            parsed = parse_lrc ((!)raw); synced = true;
                        } else {
                            parsed = parse_plain ((!)raw); synced = false;
                        }
                        if (parsed.length > 0) {
                            var score = score_candidate (parsed, synced, (!)raw, pi, "SimpMusic");
                            log ("SimpMusic: %d lines synced=%s score=%.1f".printf (
                                parsed.length, synced.to_string (), score));
                            LyricsCandidate c = { (!)raw, "SimpMusic", parsed, synced, score };
                            candidates += c;
                        }
                    } else {
                        log ("SimpMusic: no response");
                    }

                } else if (pid == "lrclib") {
                    if (!settings.get_boolean ("lyrics-lrclib-enabled")) {
                        log ("LRCLib: disabled"); continue;
                    }
                    log ("Trying LRCLib...");
                    log ("LRCLib URL: https://lrclib.net/api/get?track_name=%s&artist_name=%s&album_name=%s".printf (
                        Uri.escape_string (m.title, null, false),
                        Uri.escape_string (m.artist, null, false),
                        Uri.escape_string (m.album, null, false)));
                    var result = yield fetch_lrclib (m.title, m.artist, m.album);
                    log ("LRCLib result: %s".printf (result != null ? "not null" : "null"));
                    if (result != null) {
                        var lr = (!)result;
                        if (lr.instrumental) {
                            log ("LRCLib: track marked as instrumental");
                            is_instrumental = true;
                        }
                        log ("LRCLib synced length: %d, plain length: %d".printf (lr.synced.length, lr.plain.length));
                        log ("LRCLib: about to parse synced lyrics");
                        if (lr.synced.length > 0) {
                            var parsed = parse_lrc (lr.synced);
                            log ("LRCLib: parsed %d lines".printf (parsed.length));
                            if (parsed.length > 0) {
                                var score = score_candidate (parsed, true, lr.synced, pi, "LRCLib");
                                log ("LRCLib synced: %d lines, score=%.1f".printf (parsed.length, score));
                                LyricsCandidate c = { lr.synced, "LRCLib", parsed, true, score };
                                candidates += c;
                            }
                        }
                        if (lr.plain.length > 0)
                            lrclib_plain_raw = lr.plain;  // used only if plain_fallback
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
                            candidates += c;
                        }
                    } else {
                        log ("NetEase: no response");
                    }

                } else if (pid == "lyricsovh") {
                    if (!settings.get_boolean ("lyrics-lyricsovh-enabled")) {
                        log ("Lyrics.ovh: disabled"); continue;
                    }
                    log ("Trying Lyrics.ovh...");
                    var raw = yield fetch_lyricsovh (m.title, m.artist);
                    if (raw != null) {
                        var parsed = parse_plain ((!)raw);
                        if (parsed.length > 0) {
                            var score = score_candidate (parsed, false, (!)raw, pi, "Lyrics.ovh");
                            log ("Lyrics.ovh: %d lines, score=%.1f".printf (parsed.length, score));
                            LyricsCandidate c = { (!)raw, "Lyrics.ovh", parsed, false, score };
                            candidates += c;
                        }
                    } else {
                        log ("Lyrics.ovh: no response");
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
                            candidates += c;
                        }
                    } else {
                        log ("Megalobiz: no response");
                    }

                } else if (pid == "genius") {
                    if (!settings.get_boolean ("lyrics-genius-enabled")) {
                        log ("LyricGenius: disabled"); continue;
                    }
                    log ("Trying LyricGenius...");
                    var raw = yield fetch_genius (m.title, m.artist);
                    if (raw != null) {
                        var parsed = parse_plain ((!)raw);
                        if (parsed.length > 0) {
                            var score = score_candidate (parsed, false, (!)raw, pi, "LyricGenius");
                            log ("LyricGenius: %d lines, score=%.1f".printf (parsed.length, score));
                            LyricsCandidate c = { (!)raw, "LyricGenius", parsed, false, score };
                            candidates += c;
                        }
                    } else {
                        log ("LyricGenius: no response");
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
                            candidates += c;
                        }
                    } else {
                        log ("Musixmatch: no response");
                    }
                }
            }

            // ── Also add LRCLib plain as candidate if plain_fallback enabled ──
            if (plain_fallback && lrclib_plain_raw != null) {
                var parsed = parse_plain ((!)lrclib_plain_raw);
                if (parsed.length > 0) {
                    // Score it at the position LRCLib sits in provider_order
                    int lrclib_pi = 0;
                    for (int pi = 0; pi < provider_order.length; pi++)
                        if (provider_order[pi].strip () == "lrclib") { lrclib_pi = pi; break; }
                    var score = score_candidate (parsed, false, (!)lrclib_plain_raw, lrclib_pi, "LRCLib");
                    log ("LRCLib plain: %d lines, score=%.1f".printf (parsed.length, score));
                    LyricsCandidate c = { (!)lrclib_plain_raw, "LRCLib", parsed, false, score };
                    candidates += c;
                }
            }

            if (candidates.length == 0) {
                log ("All providers failed or returned nothing");
                set_provider ("");
                if (is_instrumental) {
                    show_instrumental ();
                } else {
                    show_not_found ();
                }
                return;
            }

            // ── Pick best candidate ───────────────────────────────────
            //
            // If prefer_synced: only consider synced candidates; if none exist and
            // plain_fallback is on, widen to all candidates.
            LyricsCandidate[] pool = candidates;
            if (prefer_synced) {
                LyricsCandidate[] synced_only = {};
                foreach (var c in candidates)
                    if (c.is_synced) synced_only += c;
                if (synced_only.length > 0)
                    pool = synced_only;
                else if (!plain_fallback) {
                    log ("prefer-synced: no synced results and plain-fallback disabled");
                    set_provider ("");
                    if (is_instrumental) {
                        show_instrumental ();
                    } else {
                        show_not_found ();
                    }
                    return;
                }
                // else pool stays as all candidates (plain fallback allowed)
            }

            // If auto_select is enabled: pick highest-scoring candidate (existing behavior)
            // If auto_select is disabled: pick first provider in order that returned results
            LyricsCandidate best;
            if (auto_select) {
                // Original behavior: pick by score
                LyricsCandidate best_by_score = pool[0];
                foreach (var c in pool)
                    if (c.score > best_by_score.score) best_by_score = c;
                best = best_by_score;
            } else {
                // New behavior: pick first provider in order that has candidates
                best = pool[0]; // Start with first
                int best_order_idx = 999;
                foreach (var c in pool) {
                    int order_idx = 999;
                    for (int i = 0; i < provider_order.length; i++) {
                        if (provider_order[i].strip () == c.provider.down ()) {
                            order_idx = i;
                            break;
                        }
                    }
                    if (order_idx < best_order_idx) {
                        best_order_idx = order_idx;
                        best = c;
                    }
                }
                log ("Using provider order (auto-select disabled): picked %s".printf (best.provider));
            }

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
                if (root_obj == null) {
                    log ("BetterLyrics: root_obj is null");
                    return null;
                }
                var obj = (!)root_obj;
                if (!obj.has_member ("ttml")) {
                    log ("BetterLyrics: no 'ttml' field");
                    return null;
                }
                string? ttml_val = obj.get_string_member ("ttml");
                int ttml_len = ttml_val != null ? ((!)ttml_val).length : 0;
                int ttml_log_len = ttml_len > 200 ? 200 : ttml_len;
                log ("BetterLyrics ttml (len=%d): %s".printf (ttml_len, ttml_val != null ? ((!)ttml_val).substring (0, ttml_log_len) : "null"));
                return ttml_val;
            } catch (Error e) {
                log ("BetterLyrics: JSON parse error: %s".printf (e.message));
                return null;
            }
        }

        // ── SimpMusic ────────────────────────────────────────────────

        private static string? extract_youtube_id (string comment) {
            if (comment.length == 0) return null;
            try {
                var re = new Regex (
                    "(?:youtu\\.be/|youtube\\.com/(?:watch\\?v=|v/|embed/))([A-Za-z0-9_-]{11})");
                MatchInfo info;
                if (re.match (comment, 0, out info))
                    return info.fetch (1);
            } catch (RegexError e) {}
            return null;
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
            var url = "https://lrclib.net/api/get?track_name=%s&artist_name=%s&album_name=%s".printf (
                Uri.escape_string (title, null, false),
                Uri.escape_string (artist, null, false),
                Uri.escape_string (album, null, false));
            var body = yield http_get (url);
            if (body == null) return null;
            try {
                var parser = new Json.Parser ();
                parser.load_from_data ((!)body);
                var root_obj = parser.get_root ()?.get_object ();
                if (root_obj == null) {
                    log ("fetch_lrclib: root_obj is null");
                    return null;
                }
                var obj = (!)root_obj;
                
                // Check instrumental flag - try to get boolean, default to false if not present/invalid
                bool instrumental = false;
                try {
                    if (obj.has_member ("instrumental")) {
                        instrumental = obj.get_boolean_member ("instrumental");
                    }
                } catch {
                    instrumental = false;
                }
                log ("fetch_lrclib: instrumental=%d".printf (instrumental ? 1 : 0));
                
                log ("fetch_lrclib: parsing JSON, has syncedLyrics=%d, has plainLyrics=%d".printf (
                    obj.has_member ("syncedLyrics") ? 1 : 0,
                    obj.has_member ("plainLyrics") ? 1 : 0));
                string synced_val = "";
                string plain_val = "";
                string? raw_synced = obj.get_string_member ("syncedLyrics");
                if (raw_synced != null) {
                    synced_val = (!)raw_synced;
                }
                string? raw_plain = obj.get_string_member ("plainLyrics");
                if (raw_plain != null) {
                    plain_val = (!)raw_plain;
                }
                log ("fetch_lrclib: synced_val=%s, plain_val=%s".printf (
                    synced_val.length > 0 ? "not null" : "null",
                    plain_val.length > 0 ? "not null" : "null"));
                LrclibResult result = { synced_val, plain_val, instrumental };
                log ("fetch_lrclib: returning result with synced length %d".printf (result.synced.length));
                return result;
            } catch (Error e) {
                return null;
            }
        }

        // ── Lyrics.ovh ───────────────────────────────────────────────

        private async string? fetch_lyricsovh (string title, string artist) {
            var url = "https://api.lyrics.ovh/v1/%s/%s".printf (
                Uri.escape_string (artist, null, false),
                Uri.escape_string (title, null, false));
            var body = yield http_get (url);
            if (body == null) return null;
            try {
                var parser = new Json.Parser ();
                parser.load_from_data ((!)body);
                var root_obj = parser.get_root ()?.get_object ();
                if (root_obj == null) return null;
                var obj = (!)root_obj;
                if (!obj.has_member ("lyrics")) return null;
                var lyrics = obj.get_string_member ("lyrics");
                if (lyrics.strip ().length == 0) return null;
                return lyrics;
            } catch (Error e) {
                log ("Lyrics.ovh parse error: %s".printf (e.message));
                return null;
            }
        }

        // ── NetEase ──────────────────────────────────────────────────

        private async string? fetch_netease (string title, string artist) {
            // Search for the track
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

                // Fetch lyrics
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
                // Find first LRC result link: /lrc/maker/<id>
                var re = new Regex ("/lrc/maker/(\\d+)");
                MatchInfo info;
                if (!re.match ((!)search_body, 0, out info)) {
                    log ("Megalobiz: no results found");
                    return null;
                }
                var lrc_id = info.fetch (1);
                var lrc_url = "https://www.megalobiz.com/lrc/maker/%s".printf ((!)lrc_id);
                var lrc_body = yield http_get_with_headers (lrc_url, headers);
                if (lrc_body == null) return null;
                // Extract the LRC content from the page
                var lrc_re = new Regex (
                    "<div[^>]*class=\"[^\"]*lrc[^\"]*\"[^>]*>([^<]*(?:<(?!/?div)[^<]*)*)</div>",
                    RegexCompileFlags.DOTALL);
                MatchInfo lrc_info;
                if (!lrc_re.match ((!)lrc_body, 0, out lrc_info)) {
                    // Fallback: grab content between [00: and end
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

        // ── LyricGenius ──────────────────────────────────────────────

        private async string? fetch_genius (string title, string artist) {
            // Uses the public search endpoint (no API key needed for search)
            var query = Uri.escape_string ("%s %s".printf (title, artist), null, false);
            var search_url = "https://api.genius.com/search?q=%s".printf (query);
            string[,] headers = {
                { "User-Agent", "Mozilla/5.0" },
                { "Authorization", "Bearer " }  // empty — public search only
            };
            // Try scraping the Genius page directly instead
            var scrape_url = "https://genius.com/search?q=%s".printf (query);
            string[,] scrape_headers = {
                { "User-Agent", "Mozilla/5.0 (X11; Linux x86_64; rv:109.0) Gecko/20100101 Firefox/115.0" }
            };
            var page = yield http_get_with_headers (scrape_url, scrape_headers);
            int page_len = page != null ? ((!)page).length : 0;
            int page_log_len = page_len > 1000 ? 1000 : page_len;
            log ("Genius search page (len=%d): %s".printf (page_len, page != null ? ((!)page).substring (0, page_log_len) : "null"));
            if (page == null) return null;
            try {
                // Find song URL from search results
                var re = new Regex ("href=\"(https://genius\\.com/[A-Za-z0-9-]+-lyrics)\"");
                MatchInfo info;
                if (!re.match ((!)page, 0, out info)) {
                    log ("Genius: no song URL found");
                    return null;
                }
                string? song_url = info.fetch (1);
                log ("Genius song URL: %s".printf (song_url != null ? (!)song_url : "null"));
                if (song_url == null) return null;
                var song_page = yield http_get_with_headers ((!)song_url, scrape_headers);
                int song_page_len = song_page != null ? ((!)song_page).length : 0;
                int song_page_log_len = song_page_len > 1000 ? 1000 : song_page_len;
                log ("Genius song page (len=%d): %s".printf (song_page_len, song_page != null ? ((!)song_page).substring (0, song_page_log_len) : "null"));
                if (song_page == null) return null;
                // Extract lyrics from data-lyrics-container divs
                var lyrics_re = new Regex (
                    "data-lyrics-container=\"true\"[^>]*>([^<]*(?:<(?!/?div)[^<]*)*)",
                    RegexCompileFlags.DOTALL);
                MatchInfo lyrics_info;
                var sb = new StringBuilder ();
                var pos = 0;
                while (lyrics_re.match_full ((!)song_page, -1, pos, 0, out lyrics_info)) {
                    var chunk = lyrics_info.fetch (1) ?? "";
                    // Strip remaining HTML tags
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
                int result_len = result.length;
                int result_log_len = result_len > 500 ? 500 : result_len;
                log ("Genius extracted result (len=%d): %s".printf (result_len, result.substring (0, result_log_len)));
                
                // Validate: check if result contains parts of the artist or title we're looking for
                // This helps filter out wrong songs like the Bruno Mars issue
                bool artist_match = result.down ().contains (artist.down ());
                bool title_match = result.down ().contains (title.down ());
                log ("Genius validation: artist '%s' found=%d, title '%s' found=%d".printf (
                    artist, artist_match ? 1 : 0, title, title_match ? 1 : 0));
                
                // If neither artist nor title is found in the lyrics, it's probably the wrong song
                if (!artist_match && !title_match) {
                    log ("Genius: rejecting - lyrics don't match artist or title");
                    return null;
                }
                
                if (result.length == 0) return null;
                return result;
            } catch (RegexError e) {
                log ("Genius regex error: %s".printf (e.message));
                return null;
            }
        }

        // ── Musixmatch ───────────────────────────────────────────────

        private async string? fetch_musixmatch (string title, string artist, string api_key) {
            // Search for track
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

                // Fetch lyrics
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

            for (var div = body->children; div != null; div = div->next) {
                if (div->type != Xml.ElementType.ELEMENT_NODE) continue;
                for (var p = div->children; p != null; p = p->next) {
                    if (p->type != Xml.ElementType.ELEMENT_NODE) continue;
                    if (p->name != "p") continue;

                    var begin_str = p->get_prop ("begin");
                    if (begin_str == null) continue;
                    var ms = ttml_time_to_ms ((!)begin_str);
                    if (ms < 0) continue;

                    LyricWord[] main_words = {};
                    LyricWord[] bg_words = {};
                    var line_text_sb = new StringBuilder ();

                    for (var span = p->children; span != null; span = span->next) {
                        if (span->type != Xml.ElementType.ELEMENT_NODE) continue;
                        if (span->name != "span") continue;

                        var role = span->get_prop ("role");
                        bool is_this_bg = (role != null && (!)role == "x-bg");

                        if (is_this_bg) {
                            for (var ws = span->children; ws != null; ws = ws->next) {
                                if (ws->type != Xml.ElementType.ELEMENT_NODE) continue;
                                var w_begin = ws->get_prop ("begin");
                                var w_end = ws->get_prop ("end");
                                var w_text = ws->get_content ();
                                if (w_begin != null && w_end != null && w_text.length > 0) {
                                    LyricWord w = {
                                        w_text,
                                        ttml_time_to_ms ((!)w_begin) / 1000.0,
                                        ttml_time_to_ms ((!)w_end) / 1000.0
                                    };
                                    bg_words += w;
                                }
                            }
                        } else {
                            var w_begin = span->get_prop ("begin");
                            var w_end = span->get_prop ("end");
                            var w_text = span->get_content ();
                            if (w_begin != null && w_end != null && w_text.length > 0) {
                                LyricWord w = {
                                    w_text,
                                    ttml_time_to_ms ((!)w_begin) / 1000.0,
                                    ttml_time_to_ms ((!)w_end) / 1000.0
                                };
                                main_words += w;
                                line_text_sb.append (w_text);
                            }
                        }
                    }

                    LyricLine main_line = { ms, line_text_sb.str, main_words, false };
                    result += main_line;

                    if (bg_words.length > 0) {
                        var bg_text_sb = new StringBuilder ();
                        foreach (var bw in bg_words)
                            bg_text_sb.append (bw.text);
                        LyricLine bg_line = { ms, bg_text_sb.str, bg_words, true };
                        result += bg_line;
                    }
                }
            }
            delete doc;
            return result;
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

        // ── richSyncLyrics parser ────────────────────────────────────

        private LyricLine[] parse_rich_sync (string lrc) {
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
                        var word_text = rest.substring (word_start, pos - word_start)
                            .replace ("&#x27;", "'")
                            .replace ("&amp;", "&")
                            .replace ("&lt;", "<")
                            .replace ("&gt;", ">")
                            .strip ();

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

                LyricLine l = { ms, rest, words, is_bg };
                result += l;
            }
            return result;
        }

        // ── Plain lyrics parser ──────────────────────────────────────

        private LyricLine[] parse_plain (string text) {
            LyricLine[] result = {};
            foreach (var line in text.split ("\n")) {
                var trimmed = line.strip ();
                // Skip LRC-style timestamps — this is plain only
                if (trimmed.length > 0 && trimmed[0] == '[' && parse_timestamp (
                        trimmed.substring (1, trimmed.index_of_char (']') > 0
                            ? trimmed.index_of_char (']') - 1 : 0)) >= 0)
                    continue;
                LyricWord[] empty_words = {};
                LyricLine l = { -1, trimmed, empty_words, false };
                result += l;
            }
            // Trim leading/trailing blank lines
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
                    LyricWord w = { segments[0], double.parse (segments[1]), double.parse (segments[2]) };
                    words += w;
                }
            }
            return words;
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

