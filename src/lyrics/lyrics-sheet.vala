namespace G4 {

    public class LyricsSheet : Object {
        private Application _app;
        private Gtk.ListBox _list_box;
        private Gtk.ScrolledWindow _scroll;
        private LyricLine[] _lines = {};
        private bool _is_synced = false;
        private int[] _active_indices = {};
        private Gtk.Label _provider_label;
        private Gtk.Label _offset_label;
        private Gtk.Box _offset_box;
        private Gtk.Box _box;
        private int64 _offset_ms = 0;
        private string _current_uri = "";
        private string _current_raw = "";
        public Adw.BottomSheet bottom_sheet;

        private LyricsEngine _engine;
        private bool _loading_in_progress = false;
        private bool _is_instrumental = false;

        public LyricsSheet (Application app) {
            _app = app;
            _engine = new LyricsEngine ();

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
                lyrics_log ("Manual refresh requested, clearing cache");
                lyrics_clear_cache (_current_uri);
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
                lyrics_save_cache (_current_uri, _current_raw, _provider_label.label, _offset_ms);
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
                lyrics_save_cache (_current_uri, _current_raw, _provider_label.label, _offset_ms);
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
                _active_indices = {};
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

            string[] active_voices = {};
            int[] new_active = {};
            for (var i = 0; i < _lines.length; i++) {
                if (_lines[i].time_ms <= ms) {
                    bool found = false;
                    for (var j = 0; j < active_voices.length; j++) {
                        if (active_voices[j] == _lines[i].voice_role) {
                            new_active[j] = i;
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        active_voices += _lines[i].voice_role;
                        new_active += i;
                    }
                }
            }

            int[] filtered_active = {};
            for (var i = 0; i < new_active.length; i++) {
                var line = _lines[new_active[i]];
                if (line.words.length > 0) {
                    var last_word = line.words[line.words.length - 1];
                    if (sec < last_word.end_sec) {
                        filtered_active += new_active[i];
                    }
                } else {
                    filtered_active += new_active[i];
                }
            }
            new_active = filtered_active;

            for (var i = 0; i < _active_indices.length; i++) {
                bool still_active = false;
                for (var j = 0; j < new_active.length; j++) {
                    if (new_active[j] == _active_indices[i]) {
                        still_active = true;
                        break;
                    }
                }
                if (!still_active) {
                    update_word_highlights (_active_indices[i], -1);
                }
            }

            for (var i = 0; i < new_active.length; i++) {
                update_word_highlights (new_active[i], sec);
            }

            _active_indices = new_active;

            var idx = 0;
            var child = _list_box.get_first_child ();
            while (child != null) {
                var next = ((!)child).get_next_sibling ();
                if (child is Gtk.ListBoxRow) {
                    var row = (Gtk.ListBoxRow)(!)child;
                    bool is_active = false;
                    for (var j = 0; j < new_active.length; j++) {
                        if (new_active[j] == idx) {
                            is_active = true;
                            break;
                        }
                    }
                    if (is_active) {
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

            if (new_active.length > 0) {
                var first_active = new_active[0];
                var active_row = _list_box.get_row_at_index (first_active);
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
                    line_label.margin_top = line.voice_role == "bg" ? 2 : 8;
                    line_label.margin_bottom = line.voice_role == "bg" ? 2 : 8;
                    line_label.add_css_class (line.voice_role == "bg" ? "lyrics-word-bg" : "lyrics-word");
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
            _active_indices = {};
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
            _active_indices = {};
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
                lyrics_save_cache (_current_uri, new_raw, _provider_label.label, _offset_ms);
                var edit_format = detect_lyrics_format (new_raw);
                _is_synced = edit_format != LyricsFormat.PLAIN && edit_format != LyricsFormat.TTML_UNSYNCED;
                _lines = parse (new_raw, edit_format);
                if (_lines.length > 0) {
                    populate_list ();
                } else {
                    show_not_found ();
                }
                dialog.close ();
            });

            var win = bottom_sheet.get_root () as Gtk.Window;
            dialog.present (win);
        }

        // ── Main load ────────────────────────────────────────────────

        private async void load_lyrics () {
            if (_loading_in_progress) {
                lyrics_log ("load_lyrics: already in progress, skipping");
                return;
            }
            _loading_in_progress = true;
            _lines = {};
            _is_synced = false;
            _active_indices = {};
            _current_raw = "";
            _offset_ms = 0;
            update_offset_label ();
            show_loading ();

            _is_instrumental = false;

            var music = _app.current_music;
            if (music == null) {
                lyrics_log ("No current music, aborting");
                _loading_in_progress = false;
                show_not_found ();
                return;
            }
            var m = (!)music;
            _current_uri = m.uri;

            lyrics_log ("Loading lyrics for: '%s' by '%s' (album: '%s')".printf (
                m.title, m.artist, m.album));

            lyrics_log ("Checking cache...");
            string cached_raw, cached_provider;
            int64 cached_offset;
            if (lyrics_load_cache (_current_uri, out cached_raw, out cached_provider, out cached_offset)) {
                _current_raw = cached_raw;
                _offset_ms = cached_offset;
                update_offset_label ();
                set_provider (cached_provider + " (cached)");

                if (cached_provider == "instrumental" || cached_raw == "[instrumental]") {
                    lyrics_log ("Cache: track is marked as instrumental");
                    _is_instrumental = true;
                    _lines = {};
                    show_instrumental ();
                    _loading_in_progress = false;
                    return;
                }

                var format = detect_lyrics_format (cached_raw);
                _is_synced = format != LyricsFormat.PLAIN && format != LyricsFormat.TTML_UNSYNCED;
                _lines = parse (cached_raw, format);

                if (_lines.length > 0) {
                    lyrics_log ("Loaded from cache, %d lines".printf (_lines.length));
                    _loading_in_progress = false;
                    populate_list ();
                    return;
                }
            }

            var settings = _app.settings;

            ulong handler_id = 0;
            handler_id = _engine.candidate_available.connect ((c) => {
                apply_candidate (c);
            });

            var best = yield _engine.load_lyrics (m, settings);

            _engine.disconnect (handler_id);
            _loading_in_progress = false;

            if (best == null) {
                lyrics_log ("All providers failed or returned nothing");
                set_provider ("");
                if (_is_instrumental) {
                    lyrics_log ("Track is instrumental, caching and showing");
                    _current_raw = "[instrumental]";
                    lyrics_save_cache (_current_uri, _current_raw, "instrumental", 0);
                    show_instrumental ();
                } else {
                    show_not_found ();
                }
                return;
            }

            apply_candidate ((!)best);
        }

        private void apply_candidate (LyricsCandidate c) {
            lyrics_log ("Applying candidate: %s (score=%.1f, %d lines, synced=%s)".printf (
                c.provider, c.score, c.lines.length, c.is_synced.to_string ()));
            if (c.is_synced) {
                _current_raw = serialize_to_lrc_plus (c.lines);
            } else {
                _current_raw = lyrics_convert_to_plaintext (c.raw);
            }
            _lines = c.lines;
            _is_synced = c.is_synced;
            set_provider (c.provider);
            lyrics_save_cache (_current_uri, _current_raw, c.provider, 0);
            populate_list ();
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
