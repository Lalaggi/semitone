namespace G4 {

    public class LyricsSheet : Object {
        private Application _app;
        private Gtk.ListBox _list_box;
        private Gtk.ScrolledWindow _scroll;
        private Gtk.Overlay _scroll_overlay;
        private Gtk.Revealer _resume_revealer;
        private Gtk.Button _resume_button;
        private LyricLine[] _lines = {};
        private bool _is_synced = false;
        private int[] _active_indices = {};
        private Gtk.Label _provider_label;
        private Gtk.Label _offset_label;
        private Gtk.Scale _offset_scale;
        private Gtk.Box _offset_box;
        private Gtk.Box _box;
        private int64 _offset_ms = 0;
        private string _current_uri = "";
        private string _current_raw = "";
        public Adw.BottomSheet bottom_sheet;

        private LyricsEngine _engine;
        private bool _loading_in_progress = false;
        private bool _is_instrumental = false;
        private GLib.Cancellable? _load_cancellable;
        private int _load_gen = 0;
        private bool _user_scrolling = false;
        private uint _auto_scroll_timeout = 0;
        private bool _programmatic_scroll = false;
        private int _previous_first_active = -1;
        private string[] _last_markup = {};
        private Adw.TimedAnimation? _scroll_animation = null;
        private uint _word_fade_timer = 0;
        // per-line fade state (supports concurrent duet fades)
        private double[] _fade_progress = {};
        private double[] _fade_target_sec = {};
        private bool[] _fade_active = {};
        private uint _resume_countdown_id = 0;
        private int _resume_remaining_ms = 0;
        private double _current_sec = -1;

        // scroll anchor: 0.38 puts active line slightly above center for preview of next lines
        private const double SCROLL_ANCHOR = 0.38;

        public LyricsSheet (Application app) {
            _app = app;
            _engine = new LyricsEngine ();

            _box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            _box.vexpand = true;
            _box.valign = Gtk.Align.FILL;
            _box.hexpand = true;
            _box.halign = Gtk.Align.FILL;

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
            _list_box.hexpand = true;
            _list_box.halign = Gtk.Align.FILL;
            _list_box.margin_start = 4;
            _list_box.margin_end = 4;
            _list_box.margin_top = 4;
            _list_box.margin_bottom = 4;
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
            _scroll.hexpand = true;
            _scroll.halign = Gtk.Align.FILL;
            _scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
            _scroll.vscrollbar_policy = Gtk.PolicyType.AUTOMATIC;
            _scroll.vadjustment.value_changed.connect (on_scroll_value_changed);

            // overlay for resume chip
            _scroll_overlay = new Gtk.Overlay ();
            _scroll_overlay.child = _scroll;
            _scroll_overlay.vexpand = true;

            _resume_button = new Gtk.Button.with_label (_("Resume auto-scroll"));
            _resume_button.add_css_class ("pill");
            _resume_button.add_css_class ("suggested-action");
            _resume_button.tooltip_text = _("Resume auto-scroll");
            _resume_button.clicked.connect (() => {
                cancel_auto_scroll_timeout ();
                hide_resume_chip ();
                // scroll to current active immediately
                if (_active_indices.length > 0) {
                    scroll_to_active_group (true);
                } else if (_previous_first_active >= 0) {
                    scroll_to_active_group (true);
                }
            });
            var resume_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            resume_box.append (new Gtk.Image.from_icon_name ("go-down-symbolic"));
            resume_box.append (_resume_button);
            // revealer wraps the box for animation
            _resume_revealer = new Gtk.Revealer ();
            _resume_revealer.transition_type = Gtk.RevealerTransitionType.SLIDE_UP;
            _resume_revealer.reveal_child = false;
            _resume_revealer.halign = Gtk.Align.CENTER;
            _resume_revealer.valign = Gtk.Align.END;
            _resume_revealer.margin_bottom = 12;
            var chip = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
            chip.add_css_class ("lyrics-resume-chip");
            chip.append (_resume_button);
            _resume_revealer.child = chip;
            _scroll_overlay.add_overlay (_resume_revealer);

            _box.append (_scroll_overlay);

            // ── Bottom bar ───────────────────────────────────────────
            var bar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 4);
            bar.add_css_class ("toolbar");
            bar.add_css_class ("lyrics-bottom-bar");
            bar.hexpand = true;
            bar.halign = Gtk.Align.FILL;
            bar.margin_start = 4;
            bar.margin_end = 4;
            bar.margin_top = 4;
            bar.margin_bottom = 4;

            var refresh_btn = new Gtk.Button ();
            refresh_btn.icon_name = "view-refresh-symbolic";
            refresh_btn.tooltip_text = _("Refresh lyrics");
            refresh_btn.add_css_class ("flat");
            refresh_btn.clicked.connect (() => {
                cancel_current_load ();
                lyrics_clear_cache (_current_uri);
                load_lyrics.begin ();
            });
            bar.append (refresh_btn);

            _offset_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            _offset_box.halign = Gtk.Align.CENTER;
            _offset_box.hexpand = true;
            _offset_box.valign = Gtk.Align.CENTER;

            var minus_btn = new Gtk.Button.from_icon_name ("list-remove-symbolic");
            minus_btn.add_css_class ("flat");
            minus_btn.add_css_class ("circular");
            minus_btn.tooltip_text = _("-50 ms");
            minus_btn.clicked.connect (() => {
                _offset_ms -= 50;
                update_offset_ui ();
                lyrics_save_cache (_current_uri, _current_raw, _provider_label.label, _offset_ms);
            });

            _offset_label = new Gtk.Label ("0ms");
            _offset_label.width_chars = 5;
            _offset_label.halign = Gtk.Align.CENTER;
            _offset_label.add_css_class ("caption");
            _offset_label.add_css_class ("dim-label");

            _offset_scale = new Gtk.Scale.with_range (Gtk.Orientation.HORIZONTAL, -1000, 1000, 10);
            _offset_scale.draw_value = false;
            _offset_scale.hexpand = true;
            _offset_scale.hexpand_set = true;
            _offset_scale.halign = Gtk.Align.FILL;
            _offset_scale.width_request = 80;
            _offset_scale.tooltip_text = _("Fine offset adjustment");
            _offset_scale.add_mark (0, Gtk.PositionType.BOTTOM, null);
            _offset_scale.value_changed.connect (() => {
                // avoid feedback loop when we set value programmatically
                if (_programmatic_scroll) return;
                var v = (int) _offset_scale.get_value ();
                if (v == _offset_ms) return;
                _offset_ms = v;
                update_offset_label ();
                lyrics_save_cache (_current_uri, _current_raw, _provider_label.label, _offset_ms);
            });

            var plus_btn = new Gtk.Button.from_icon_name ("list-add-symbolic");
            plus_btn.add_css_class ("flat");
            plus_btn.add_css_class ("circular");
            plus_btn.tooltip_text = _("+50 ms");
            plus_btn.clicked.connect (() => {
                _offset_ms += 50;
                update_offset_ui ();
                lyrics_save_cache (_current_uri, _current_raw, _provider_label.label, _offset_ms);
            });

            _offset_box.append (minus_btn);
            _offset_box.append (_offset_scale);
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
                    cancel_auto_scroll_timeout ();
                    hide_resume_chip ();
                    _app.player.position_updated.connect (on_position_updated);
                    load_lyrics.begin ();
                } else {
                    if (_resize_timeout != 0) {
                        GLib.Source.remove (_resize_timeout);
                        _resize_timeout = 0;
                    }
                    cancel_auto_scroll_timeout ();
                    hide_resume_chip ();
                    cancel_scroll_animation ();
                    cancel_word_fade_timer ();
                    _app.player.position_updated.disconnect (on_position_updated);
                    cancel_current_load ();
                }
            });

            app.music_changed.connect ((music) => {
                cancel_current_load ();
                cancel_auto_scroll_timeout ();
                hide_resume_chip ();
                cancel_scroll_animation ();
                cancel_word_fade_timer ();
                _active_indices = {};
                _last_markup = {};
                _fade_progress = {};
                _fade_target_sec = {};
                _fade_active = {};
                _previous_first_active = -1;
                _offset_ms = 0;
                update_offset_ui ();
                scroll_to_top ();
                if (bottom_sheet.open)
                    load_lyrics.begin ();
            });

            // voice display mode / colors changes should refresh badges
            _app.settings.changed["lyrics-voice-display-mode"].connect (() => {
                if (_is_synced && _lines.length > 0) {
                    _last_markup = {};
                    for (var i = 0; i < _lines.length; i++) {
                        double sec = -1;
                        foreach (var a in _active_indices) if (a == i) { sec = _current_sec; break; }
                        update_word_highlights (i, sec);
                    }
                }
            });
            _app.settings.changed["lyrics-voice-colors-enabled"].connect (() => {
                if (_is_synced && _lines.length > 0) {
                    _last_markup = {};
                    for (var i = 0; i < _lines.length; i++) {
                        double sec = -1;
                        foreach (var a in _active_indices) if (a == i) { sec = _current_sec; break; }
                        update_word_highlights (i, sec);
                    }
                }
            });

            apply_lyrics_css ();
        }

        public void open () {
            bottom_sheet.open = true;
        }

        private void scroll_to_top () {
            cancel_scroll_animation ();
            var adj = _scroll.vadjustment;
            _programmatic_scroll = true;
            adj.value = adj.lower;
            _programmatic_scroll = false;
        }

        private void update_box_height () {
            var win = bottom_sheet.get_root () as Gtk.Window;
            if (win != null) {
                var win_height = ((!)win).get_height ();
                var sheet_height = (int) (win_height * 0.85);
                _box.height_request = sheet_height;
            }
        }

        public void set_sheet_width (int width) {
            _box.width_request = width > 0 ? width : -1;
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
            _offset_label.label = "%ldms".printf ((long) _offset_ms);
        }

        private void update_offset_ui () {
            update_offset_label ();
            // sync scale without triggering value_changed recursion
            var adj = _offset_scale.adjustment;
            if ((int) adj.value != _offset_ms) {
                _programmatic_scroll = true;
                adj.value = _offset_ms.clamp (-1000, 1000);
                _programmatic_scroll = false;
            }
        }

        // ── Smooth scroll animation ──────────────────────────────────

        private void cancel_scroll_animation () {
            if (_scroll_animation != null) {
                ((!)_scroll_animation).pause ();
                _scroll_animation = null;
            }
        }

        private void animate_scroll_to (double target) {
            var adj = _scroll.vadjustment;
            var current = adj.value;
            var clamped = target.clamp (adj.lower, adj.upper - adj.page_size);
            if ((clamped - current).abs () < 1.0) {
                _programmatic_scroll = true;
                adj.value = clamped;
                _programmatic_scroll = false;
                return;
            }

            cancel_scroll_animation ();

            var duration_ms = (uint) ((clamped - current).abs () / adj.page_size * 550).clamp (180, 700);
            var target_val = clamped;
            var start_val = current;

            var cb = new Adw.CallbackAnimationTarget ((value) => {
                _programmatic_scroll = true;
                adj.value = value;
                _programmatic_scroll = false;
            });
            _scroll_animation = new Adw.TimedAnimation (
                _scroll, start_val, target_val, duration_ms, cb
            );
            ((!)_scroll_animation).easing = Adw.Easing.EASE_OUT_CUBIC;
            ((!)_scroll_animation).play ();
        }

        // ── Word fade animation (per-line concurrent) ────────────────

        private void cancel_word_fade_timer () {
            if (_word_fade_timer != 0) {
                GLib.Source.remove (_word_fade_timer);
                _word_fade_timer = 0;
            }
            _fade_progress = {};
            _fade_target_sec = {};
            _fade_active = {};
        }

        private void ensure_fade_arrays () {
            if (_fade_progress.length != _lines.length) {
                _fade_progress.resize (_lines.length);
                _fade_target_sec.resize (_lines.length);
                _fade_active.resize (_lines.length);
                // initialize new slots to 0/false (resize does)
            }
        }

        private void start_word_fade (int line_index, double target_sec) {
            ensure_fade_arrays ();
            if (line_index < 0 || line_index >= _lines.length) return;
            _fade_active[line_index] = true;
            _fade_progress[line_index] = 0.0;
            _fade_target_sec[line_index] = target_sec;
            if (_word_fade_timer == 0) {
                var step_ms = 16;
                var total_ms = 110;
                _word_fade_timer = GLib.Timeout.add (step_ms, () => {
                    bool any_active = false;
                    for (var i = 0; i < _lines.length; i++) {
                        if (i >= _fade_active.length || !_fade_active[i]) continue;
                        _fade_progress[i] += (double) step_ms / total_ms;
                        if (_fade_progress[i] >= 1.0) {
                            _fade_progress[i] = 1.0;
                            update_word_fade_markup (i, _fade_target_sec[i], 1.0);
                            _fade_active[i] = false;
                        } else {
                            update_word_fade_markup (i, _fade_target_sec[i], _fade_progress[i]);
                            any_active = true;
                        }
                    }
                    if (!any_active) {
                        _word_fade_timer = 0;
                        return false;
                    }
                    return true;
                });
            }
        }

        private void update_word_fade_markup (int line_index, double sec, double progress) {
            var row = _list_box.get_row_at_index (line_index);
            if (row == null) return;
            var label = ((!)row).child as Gtk.Label;
            if (label == null) return;
            var markup = build_line_markup_faded (_lines[line_index], sec, progress);
            ((!)label).set_label (markup);
            // also update cached last_markup so subsequent non-fade updates can skip
            if (line_index >= _last_markup.length)
                _last_markup.resize (line_index + 1);
            _last_markup[line_index] = markup;
        }

        private bool voice_colors_enabled {
            get { return _app.settings.get_boolean ("lyrics-voice-colors-enabled"); }
        }

        private string voice_color_for_role (string role) {
            if (!voice_colors_enabled) return "";
            if (role == "bg") return "#a0a0a0";
            if (role == "" || role == "v1") return "";
            // palette for common roles
            switch (role.down ()) {
                case "v2": return "#e67e22";
                case "v3": return "#3498db";
                case "v4": return "#e74c3c";
                case "lead": return "";
                case "duet": return "#9b59b6";
                default: {
                    // deterministic hue from hash
                    uint h = GLib.str_hash (role);
                    int hue = (int)(h % 360);
                    // convert HSL (hue, 70%, 60%) to hex via simple HSV approx
                    // use fixed saturation/lightness -> vary hue only
                    double s = 0.68, l = 0.60;
                    double c = (1 - (2*l -1).abs()) * s;
                    double hp = hue / 60.0;
                    double x = c * (1 - (hp % 2 -1).abs());
                    double r=0,g=0,b=0;
                    if (hp < 1) { r=c; g=x; }
                    else if (hp < 2) { r=x; g=c; }
                    else if (hp < 3) { g=c; b=x; }
                    else if (hp < 4) { g=x; b=c; }
                    else if (hp < 5) { r=x; b=c; }
                    else { r=c; b=x; }
                    double m = l - c/2;
                    r+=m; g+=m; b+=m;
                    int ri = (int)(r*255).clamp(0,255);
                    int gi = (int)(g*255).clamp(0,255);
                    int bi = (int)(b*255).clamp(0,255);
                    return "#%02x%02x%02x".printf(ri,gi,bi);
                }
            }
        }

        private uint voice_display_mode {
            get { return _app.settings.get_uint ("lyrics-voice-display-mode"); }
        }

        private string voice_type_label (string vtype) {
            // Agent-type badge fallback for nameless voices (TTML agent
            // type= / @[id,...,type=X]). Only group materializes ("Group");
            // a nameless person falls through to the coded id (V3).
            if (vtype.down () == "group") return "Group";
            return "";
        }

        private string voice_badge_markup (LyricLine line) {
            uint mode = voice_display_mode; // 0 none, 1 coded, 2 pretty (recommended) with fallback
            if (mode == 0) return "";
            if (mode == 1) {
                // coded only – bg hardcoded to Background
                if (line.voice_role.length == 0) return "";
                string pretty;
                if (line.voice_role == "bg") pretty = "Background";
                else pretty = line.voice_role.up ();
                var color = voice_color_for_role (line.voice_role);
                var color_attr = color.length > 0 ? " foreground='%s'".printf(color) : "";
                return "<span size='small' alpha='75%%'%s weight='bold'>%s  </span>".printf(color_attr, Markup.escape_text (pretty));
            }
            // mode 2 pretty with fallback: pretty name -> agent type -> coded id -> none
            string pretty = "";
            if (line.voice_role == "bg") {
                // hardcoded pretty for bg
                if (line.voice_display.length > 0) pretty = line.voice_display;
                else pretty = "Background";
            } else if (line.voice_display.length > 0) pretty = line.voice_display;
            else if (line.voice_role.length > 0) {
                pretty = voice_type_label (line.voice_type);
                if (pretty.length == 0) pretty = line.voice_role.up ();
            }
            else return "";
            var color2 = voice_color_for_role (line.voice_role);
            var color_attr2 = color2.length > 0 ? " foreground='%s'".printf(color2) : "";
            return "<span size='small' alpha='75%%'%s weight='bold'>%s  </span>".printf(color_attr2, Markup.escape_text (pretty));
        }

        private string style_attrs_for_word (LyricLine line, LyricWord word) {
            var combined = "";
            if (line.style.length > 0) combined = line.style;
            if (word.style.length > 0) {
                if (combined.length > 0) combined += "," + word.style;
                else combined = word.style;
            }
            var attrs = new StringBuilder ();
            foreach (var tok in combined.split (",")) {
                var t = tok.strip ().down ();
                if (t == "bold") attrs.append (" weight='bold'");
                else if (t == "italic") attrs.append (" style='italic'");
                else if (t == "underline") attrs.append (" underline='single'");
                else if (t == "strike") attrs.append (" strikethrough='true'");
            }
            return attrs.str;
        }

        private string effect_class_for_line (LyricLine line) {
            if (line.effect.length == 0) return "";
            var e = line.effect.down ();
            if (e.contains ("shake")) return "lyrics-effect-shake";
            if (e.contains ("glow")) return "lyrics-effect-glow";
            if (e.contains ("wobble")) return "lyrics-effect-wobble";
            return "";
        }

        private string build_line_markup_faded (LyricLine line, double sec, double progress) {
            var badge = voice_badge_markup (line);
            if (line.words.length == 0) {
                var txt = Markup.escape_text (line.text.length > 0 ? line.text : "\u00B7");
                LyricWord empty = { "", 0, 0, "", "", true };
                var la = style_attrs_for_word (line, empty);
                var base_alpha = line.voice_role == "bg" ? "60%%" : "85%%";
                if (la.length > 0) return badge + "<span alpha='%s'%s>%s</span>".printf(base_alpha, la, txt);
                return badge + "<span alpha='%s'>%s</span>".printf(base_alpha, txt);
            }
            var sb = new StringBuilder ();
            sb.append (badge);
            for (var wi = 0; wi < line.words.length; wi++) {
                var word = line.words[wi];
                // Syllable continuations glue to the previous unit with no
                // space; a space is emitted only before a new word.
                if (wi > 0 && word.word_start) sb.append_c (' ');
                var escaped = Markup.escape_text (word.text);
                var extra = style_attrs_for_word (line, word);
                bool has_underline = extra.contains ("underline");
                // intra-word progress for smoother fill
                double word_progress = 0.0;
                if (sec >= word.start_sec && sec < word.end_sec) {
                    var dur = word.end_sec - word.start_sec;
                    if (dur > 0.02) word_progress = ((sec - word.start_sec) / dur).clamp(0.0,1.0);
                    else word_progress = 1.0;
                } else if (sec >= word.end_sec) word_progress = 1.0;
                if (sec < 0) {
                    sb.append ("<span alpha='42%%'%s>%s</span>".printf (extra, escaped));
                } else if (sec + 0.05 >= word.start_sec && sec < word.end_sec) {
                    var alpha = 42 + (int) (58 * progress);
                    // bg lines: no underline/outline highlight; other voices get underline
                    string u = "";
                    if (line.voice_role != "bg") {
                        u = has_underline ? "" : " underline='single'";
                    }
                    // add foreground tint for voice color on active word if non-bg
                    var col = voice_color_for_role (line.voice_role);
                    var fg = (col.length > 0 && line.voice_role != "bg") ? " foreground='%s'".printf(col) : "";
                    sb.append ("<span alpha='%d%%'%s%s%s>%s</span>".printf (alpha, extra, u, fg, escaped));
                } else if (sec >= word.end_sec) {
                    // past words: slightly bolder past vs future, with intra-word highlight
                    var past_alpha = 68 + (int)(8 * word_progress);
                    sb.append ("<span alpha='%d%%'%s>%s</span>".printf (past_alpha, extra, escaped));
                } else {
                    sb.append ("<span alpha='42%%'%s>%s</span>".printf (extra, escaped));
                }
            }
            return sb.str.strip ();
        }

        // ── Position tracking ────────────────────────────────────────

        private void on_scroll_value_changed () {
            if (_programmatic_scroll) return;
            _user_scrolling = true;
            reset_auto_scroll_timeout ();
            show_resume_chip ();
        }

        private void show_resume_chip () {
            if (_resume_revealer.reveal_child) return;
            _resume_revealer.reveal_child = true;
        }
        private void hide_resume_chip () {
            _resume_revealer.reveal_child = false;
            if (_resume_countdown_id != 0) {
                GLib.Source.remove (_resume_countdown_id);
                _resume_countdown_id = 0;
            }
        }

        private void reset_auto_scroll_timeout () {
            if (_auto_scroll_timeout != 0) {
                GLib.Source.remove (_auto_scroll_timeout);
            }
            if (_resume_countdown_id != 0) {
                GLib.Source.remove (_resume_countdown_id);
                _resume_countdown_id = 0;
            }
            var timeout_ms = _app.settings.get_int ("lyrics-autoscroll-timeout");
            if (timeout_ms <= 0) {
                _user_scrolling = false;
                _auto_scroll_timeout = 0;
                return;
            }
            _resume_remaining_ms = timeout_ms;
            _resume_button.label = _("Resume auto-scroll (%ds)").printf ((timeout_ms+999)/1000);
            // countdown tick each second to update label
            _resume_countdown_id = GLib.Timeout.add (1000, () => {
                _resume_remaining_ms -= 1000;
                if (_resume_remaining_ms <= 0) {
                    _resume_button.label = _("Resume auto-scroll");
                    _resume_countdown_id = 0;
                    return false;
                }
                _resume_button.label = _("Resume auto-scroll (%ds)").printf ((_resume_remaining_ms+999)/1000);
                return true;
            });
            _auto_scroll_timeout = GLib.Timeout.add (timeout_ms, () => {
                _user_scrolling = false;
                _auto_scroll_timeout = 0;
                hide_resume_chip ();
                // snap to current active
                if (_active_indices.length > 0) scroll_to_active_group (false);
                if (_resume_countdown_id != 0) {
                    GLib.Source.remove (_resume_countdown_id);
                    _resume_countdown_id = 0;
                }
                _resume_button.label = _("Resume auto-scroll");
                return false;
            });
        }

        private void cancel_auto_scroll_timeout () {
            if (_auto_scroll_timeout != 0) {
                GLib.Source.remove (_auto_scroll_timeout);
                _auto_scroll_timeout = 0;
            }
            if (_resume_countdown_id != 0) {
                GLib.Source.remove (_resume_countdown_id);
                _resume_countdown_id = 0;
            }
            _user_scrolling = false;
        }

        private void on_position_updated (Gst.ClockTime position) {
            if (!_is_synced) return;
            var sec = GstPlayer.to_second (position);
            var ms = (int64) (sec * 1000) + _offset_ms;
            var adj_sec = (double) ms / 1000.0;
            _current_sec = adj_sec;
            update_current_line (ms, adj_sec);
        }

        private void scroll_to_active_group (bool immediate_anchor = false) {
            if (_active_indices.length == 0) return;
            // compute union bounds of all active rows
            double min_y = double.MAX;
            double max_y = double.MIN;
            bool any = false;
            foreach (var idx in _active_indices) {
                var row = _list_box.get_row_at_index (idx);
                if (row == null) continue;
                var bounds = Graphene.Rect ();
                ((!)row).compute_bounds (_scroll, out bounds);
                var adj = _scroll.vadjustment;
                double top = bounds.get_y () + adj.get_value ();
                double bottom = top + bounds.get_height ();
                if (top < min_y) min_y = top;
                if (bottom > max_y) max_y = bottom;
                any = true;
            }
            if (!any) return;
            var adj2 = _scroll.vadjustment;
            var center = (min_y + max_y) / 2.0;
            var target = center - (adj2.page_size * SCROLL_ANCHOR);
            // if immediate (user tapped resume), use slightly faster anim
            if (immediate_anchor) {
                Idle.add (() => { animate_scroll_to (target); return false; });
            } else {
                Idle.add (() => { animate_scroll_to (target); return false; });
            }
        }

        private void update_current_line (int64 ms, double sec) {
            if (_lines.length == 0) return;

            // Lead by 50ms so fade is midpoint at actual activation
            var lead_ms = ms + 50;
            string[] active_voices = {};
            int[] new_active = {};
            for (var i = 0; i < _lines.length; i++) {
                if (_lines[i].time_ms <= lead_ms) {
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

            ensure_fade_arrays ();
            // Detect newly active lines — fade 50ms early so it's midpoint at actual time
            for (var i = 0; i < new_active.length; i++) {
                bool was_active = false;
                for (var j = 0; j < _active_indices.length; j++) {
                    if (_active_indices[j] == new_active[i]) {
                        was_active = true;
                        break;
                    }
                }
                if (!was_active && _lines[new_active[i]].words.length > 0) {
                    start_word_fade (new_active[i], sec + 0.05);
                } else if (was_active) {
                    // Skip update if this line is currently fading
                    if (_fade_active.length > new_active[i] && _fade_active[new_active[i]]) {
                        bool in_fade = false;
                        foreach (var w in _lines[new_active[i]].words) {
                            if (sec + 0.05 >= w.start_sec && sec < w.end_sec) {
                                in_fade = true; break;
                            }
                        }
                        if (in_fade) continue;
                    }
                    update_word_highlights (new_active[i], sec);
                }
            }

            for (var i = 0; i < new_active.length; i++) {
                // if newly activated, start_word_fade already queued; avoid double update for fade window
                bool newly = true;
                for (var j = 0; j < _active_indices.length; j++) if (_active_indices[j]==new_active[i]) { newly=false; break; }
                if (newly) continue;
                update_word_highlights (new_active[i], sec);
            }

            // capture group change before overwriting _active_indices
            bool group_changed = false;
            if (_active_indices.length != new_active.length) group_changed = true;
            else {
                for (var i=0;i<new_active.length;i++) if (_active_indices[i]!=new_active[i]) { group_changed=true; break; }
            }

            _active_indices = new_active;

            var first_active = new_active.length > 0 ? new_active[0] : -1;
            // update row CSS classes
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
                    // effect class
                    var line = _lines[idx];
                    var eff = effect_class_for_line (line);
                    // clean previous effect classes
                    row.remove_css_class ("lyrics-effect-shake");
                    row.remove_css_class ("lyrics-effect-glow");
                    row.remove_css_class ("lyrics-effect-wobble");
                    if (eff.length > 0 && is_active) row.add_css_class (eff);
                    // duet highlight disabled per user request – always ensure removed
                    row.remove_css_class ("lyrics-duet");

                    if (is_active) {
                        row.remove_css_class ("lyrics-row-inactive");
                        row.remove_css_class ("lyrics-row-near");
                        row.add_css_class ("lyrics-row-active");
                        // bg lines act independently but without outline/background highlight
                        row.remove_css_class ("lyrics-voice-bg-active");
                        // set per-voice border color via inline? we use CSS class generically
                    } else {
                        row.remove_css_class ("lyrics-row-active");
                        row.remove_css_class ("lyrics-voice-bg-active");
                        // consider distance to any active for multi-voice nearness
                        int min_dist = 99;
                        foreach (var a in new_active) {
                            var d = (idx - a).abs ();
                            if (d < min_dist) min_dist = d;
                        }
                        if (new_active.length > 0 && min_dist <= 2) {
                            row.add_css_class ("lyrics-row-near");
                            row.remove_css_class ("lyrics-row-inactive");
                        } else {
                            row.add_css_class ("lyrics-row-inactive");
                            row.remove_css_class ("lyrics-row-near");
                        }
                    }
                    idx++;
                }
                child = next;
            }

            bool should_scroll = false;
            if (new_active.length > 0 && !_user_scrolling) {
                if (first_active != _previous_first_active) should_scroll = true;
                else {
                    // if duet added second voice without moving first_active, still re-center
                    // detect group size change
                    if (group_changed) should_scroll = true;
                }
            }
            if (should_scroll) {
                _previous_first_active = first_active;
                scroll_to_active_group (false);
            } else if (new_active.length == 0) {
                _previous_first_active = -1;
            }
        }

        private void update_word_highlights (int line_index, double sec) {
            var row = _list_box.get_row_at_index (line_index);
            if (row == null) return;
            var label = ((!)row).child as Gtk.Label;
            if (label == null) return;
            var markup = build_line_markup (_lines[line_index], sec);
            if (line_index < _last_markup.length && _last_markup[line_index] == markup) return;
            if (line_index >= _last_markup.length)
                _last_markup.resize (line_index + 1);
            _last_markup[line_index] = markup;
            ((!)label).set_label (markup);
        }

        private string build_line_markup (LyricLine line, double sec) {
            var badge = voice_badge_markup (line);
            if (line.words.length == 0) {
                var txt = Markup.escape_text (line.text.length > 0 ? line.text : "·");
                LyricWord empty = { "", 0, 0, "", "", true };
                var la = style_attrs_for_word (line, empty);
                var alpha = line.voice_role == "bg" ? "60%%" : "85%%";
                if (la.length > 0) return badge + "<span alpha='%s'%s>%s</span>".printf(alpha, la, txt);
                return badge + "<span alpha='%s'>%s</span>".printf(alpha, txt);
            }
            var sb = new StringBuilder ();
            sb.append (badge);
            for (var wi = 0; wi < line.words.length; wi++) {
                var word = line.words[wi];
                if (wi > 0 && word.word_start) sb.append_c (' ');
                var escaped = Markup.escape_text (word.text);
                var extra = style_attrs_for_word (line, word);
                bool has_underline = extra.contains ("underline");
                var col = voice_color_for_role (line.voice_role);
                var fg_active = (col.length > 0 && line.voice_role != "bg") ? " foreground='%s'".printf(col) : "";
                if (sec < 0) {
                    sb.append ("<span alpha='42%%'%s>%s</span>".printf (extra, escaped));
                } else if (sec >= word.start_sec && sec < word.end_sec) {
                    string u = "";
                    if (line.voice_role != "bg") {
                        u = has_underline ? "" : " underline='single'";
                    }
                    sb.append ("<span alpha='100%%'%s%s%s>%s</span>".printf (extra, u, fg_active, escaped));
                } else if (sec >= word.end_sec) {
                    double word_progress = 0.0;
                    var dur = word.end_sec - word.start_sec;
                    if (dur > 0.02) word_progress = 1.0;
                    var past_alpha = 68;
                    sb.append ("<span alpha='%d%%'%s>%s</span>".printf (past_alpha, extra, escaped));
                } else {
                    sb.append ("<span alpha='42%%'%s>%s</span>".printf (extra, escaped));
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
            _last_markup = {};
            _previous_first_active = -1;
            _fade_progress = {};
            _fade_target_sec = {};
            _fade_active = {};
            _offset_box.visible = _is_synced;
            update_offset_ui ();

            for (var i = 0; i < _lines.length; i++) {
                var line = _lines[i];
                var synced = line.time_ms >= 0;
                var line_label = new Gtk.Label ("");
                line_label.use_markup = true;
                line_label.wrap = true;
                line_label.wrap_mode = Pango.WrapMode.WORD_CHAR;

                if (_is_synced) {
                    line_label.justify = Gtk.Justification.CENTER;
                    line_label.halign = Gtk.Align.CENTER;
                    if (line.voice_role == "bg") {
                        line_label.margin_top = 2;
                        line_label.margin_bottom = 2;
                        line_label.add_css_class ("lyrics-word-bg");
                    } else {
                        line_label.margin_top = 8;
                        line_label.margin_bottom = 8;
                        line_label.add_css_class ("lyrics-word");
                    }
                    // voice tint class for CSS fallback
                    if (line.voice_role != "" && line.voice_role != "bg") {
                        line_label.add_css_class ("lyrics-voice-" + line.voice_role.replace("/","-"));
                    }
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
                if (_is_synced) {
                    row.add_css_class ("lyrics-row-inactive");
                }
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

        private string lint_edit_lyrics (string raw) {
            var sb = new StringBuilder ();
            var raw_lines = raw.split ("\n");
            for (var i = 0; i < raw_lines.length; i++) {
                var ls = raw_lines[i].strip ();
                if (ls.length < 5 || ls[0] != '[' || !ls.contains ("]")) continue;
                var close = ls.index_of_char (']');
                var after = ls.substring (close + 1).strip ();
                if (!after.has_prefix ("{") || !after.contains ("}")) continue;
                bool next_is_timing = false;
                for (var j = i + 1; j < raw_lines.length; j++) {
                    var peek = raw_lines[j].strip ();
                    if (peek.length == 0) continue;
                    next_is_timing = peek.has_prefix ("<");
                    break;
                }
                if (!next_is_timing) {
                    sb.append ("⚠ %s: attrs will be stripped (no timing line)\n".printf (ls));
                }
            }
            return sb.str;
        }

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

            var lint_label = new Gtk.Label (lint_edit_lyrics (_current_raw));
            lint_label.xalign = 0;
            lint_label.wrap = true;
            lint_label.add_css_class ("caption");
            lint_label.add_css_class ("warning");
            lint_label.visible = lint_label.label.length > 0;
            lint_label.margin_start = 12;
            lint_label.margin_end = 12;

            var content_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            content_box.append (scroll);
            content_box.append (lint_label);

            toolbar_view.content = content_box;
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

        // ── Cancellation ─────────────────────────────────────────────

        private void cancel_current_load () {
            _load_gen++;
            _loading_in_progress = false;
            if (_load_cancellable != null) {
                ((!)_load_cancellable).cancel ();
                _load_cancellable = null;
            }
        }

        // ── Main load ────────────────────────────────────────────────

        private async void load_lyrics () {
            var gen = _load_gen;
            if (_loading_in_progress) {
                return;
            }
            _loading_in_progress = true;
            _load_cancellable = new GLib.Cancellable ();
            _lines = {};
            _is_synced = false;
            _active_indices = {};
            _last_markup = {};
            _fade_progress = {};
            _fade_target_sec = {};
            _fade_active = {};
            _previous_first_active = -1;
            _current_raw = "";
            _offset_ms = 0;
            update_offset_ui ();
            show_loading ();

            _is_instrumental = false;

            var music = _app.current_music;
            if (music == null) {
                _loading_in_progress = false;
                _load_cancellable = null;
                show_not_found ();
                return;
            }
            var m = (!)music;
            _current_uri = m.uri;

            string cached_raw, cached_provider;
            int64 cached_offset;
            if (lyrics_load_cache (_current_uri, out cached_raw, out cached_provider, out cached_offset)) {
                _current_raw = cached_raw;
                _offset_ms = cached_offset;
                update_offset_ui ();
                set_provider (cached_provider + " (cached)");

                if (cached_provider == "instrumental" || cached_raw == "[instrumental]") {
                    _is_instrumental = true;
                    _lines = {};
                    show_instrumental ();
                    _loading_in_progress = false;
                    _load_cancellable = null;
                    return;
                }

                var format = detect_lyrics_format (cached_raw);
                _is_synced = format != LyricsFormat.PLAIN && format != LyricsFormat.TTML_UNSYNCED;
                _lines = parse (cached_raw, format);

                if (_lines.length > 0) {
                    _loading_in_progress = false;
                    _load_cancellable = null;
                    populate_list ();
                    return;
                }
            }

            var settings = _app.settings;

            ulong handler_id = 0;
            handler_id = _engine.candidate_available.connect ((c) => {
                apply_candidate (gen, c);
            });

            var best = yield _engine.load_lyrics (m, settings, _load_cancellable);

            _engine.disconnect (handler_id);

            if (gen != _load_gen) {
                _load_cancellable = null;
                return;
            }

            _loading_in_progress = false;
            _load_cancellable = null;

            if (best == null) {
                set_provider ("");
                if (_is_instrumental) {
                    _current_raw = "[instrumental]";
                    lyrics_save_cache (_current_uri, _current_raw, "instrumental", 0);
                    show_instrumental ();
                } else {
                    show_not_found ();
                }
                return;
            }

            apply_candidate (gen, (!)best);
        }

        private void apply_candidate (int gen, LyricsCandidate c) {
            if (gen != _load_gen) {
                return;
            }
            if (c.lines.length == 0 && c.raw == "[instrumental]") {
                _is_instrumental = true;
                _current_raw = "[instrumental]";
                _lines = {};
                _is_synced = false;
                set_provider (c.provider);
                lyrics_save_cache (_current_uri, _current_raw, c.provider, 0);
                show_instrumental ();
                return;
            }
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
                    opacity: 0.32;
                    transition: opacity 260ms ease-out;
                }
                .lyrics-row-near {
                    opacity: 0.58;
                    transition: opacity 260ms ease-out;
                }
                .lyrics-row-active {
                    opacity: 1.0;
                    transition: opacity 220ms ease-out;
                }
                .lyrics-word {
                    font-size: 20px;
                    font-weight: 800;
                    padding: 2px 10px;
                    transition: all 180ms ease-out;
                }
                .lyrics-word-bg {
                    font-size: 15px;
                    font-weight: 500;
                    padding: 1px 10px;
                    opacity: 0.9;
                }
                .lyrics-plain {
                    font-size: 15px;
                    padding: 2px 6px;
                }
                .lyrics-bottom-bar {
                    min-width: 0;
                }
                .lyrics-bottom-bar scale {
                    min-width: 60px;
                }
                .lyrics-bottom-bar button.circular {
                    min-width: 28px;
                    min-height: 28px;
                    padding: 2px;
                }
                .lyrics-resume-chip {
                    background: @accent_bg_color;
                    color: @accent_fg_color;
                    border-radius: 999px;
                    padding: 6px 6px;
                    box-shadow: 0 4px 12px alpha(black, 0.25);
                }
                .lyrics-resume-chip button {
                    color: @accent_fg_color;
                }
                .lyrics-effect-shake {
                    animation: lyrics-shake 0.28s ease-in-out infinite;
                }
                .lyrics-effect-glow {
                    text-shadow: 0 0 8px alpha(@accent_color, 0.6);
                }
                .lyrics-effect-wobble {
                    animation: lyrics-wobble 0.6s ease-in-out infinite;
                }
                @keyframes lyrics-shake {
                    0% { transform: translateX(0); }
                    25% { transform: translateX(-0.6px); }
                    50% { transform: translateX(0.6px); }
                    75% { transform: translateX(-0.4px); }
                    100% { transform: translateX(0); }
                }
                @keyframes lyrics-wobble {
                    0% { transform: translateY(0); }
                    50% { transform: translateY(-1px); }
                    100% { transform: translateY(0); }
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
