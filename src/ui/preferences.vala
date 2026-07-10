namespace G4 {
    namespace BlurMode {
        public const uint NEVER = 0;
        public const uint ALWAYS = 1;
        public const uint ART_ONLY = 2;
    }

    [GtkTemplate (ui = "/com/github/lalaggi/semitone/gtk/preferences.ui")]
    public class PreferencesWindow : Adw.PreferencesWindow {
        [GtkChild]
        unowned Adw.ComboRow blur_row;
        [GtkChild]
        unowned Gtk.Scale scale_slider;
        [GtkChild]
        unowned Gtk.Switch compact_btn;
        [GtkChild]
        unowned Gtk.Switch grid_btn;
        [GtkChild]
        unowned Gtk.Switch single_btn;
        [GtkChild]
        unowned Gtk.Button music_dir_btn;
        [GtkChild]
        unowned Gtk.Switch monitor_btn;
        [GtkChild]
        unowned Gtk.Switch thumbnail_btn;
        [GtkChild]
        unowned Gtk.Switch playbkgnd_btn;
        [GtkChild]
        unowned Gtk.Switch rotate_btn;
        [GtkChild]
        unowned Gtk.Button css_file_btn;
        [GtkChild]
        unowned Gtk.Button css_reset_btn;
        [GtkChild]
        unowned Adw.ComboRow replaygain_row;
        [GtkChild]
        unowned Adw.ComboRow audiosink_row;
        [GtkChild]
        unowned Adw.ExpanderRow peak_row;
        [GtkChild]
        unowned Gtk.Entry peak_entry;
        [GtkChild]
        unowned Gtk.Switch lyrics_prefer_synced_btn;
        [GtkChild]
        unowned Gtk.Switch lyrics_auto_select_btn;
        [GtkChild]
        unowned Gtk.Switch lyrics_plain_fallback_btn;
        [GtkChild]
        unowned Gtk.SpinButton lyrics_autoscroll_timeout_btn;
        [GtkChild]
        unowned Adw.ActionRow lyrics_auto_indicator;
        [GtkChild]
        unowned Adw.PreferencesGroup lyrics_providers_group;

        private GenericArray<Gst.ElementFactory> _audio_sinks = new GenericArray<Gst.ElementFactory> (8);
        private Settings _settings;
        private string[] _provider_order;
        private HashTable<string, Adw.ActionRow> _provider_rows =
            new HashTable<string, Adw.ActionRow> (str_hash, str_equal);

        public PreferencesWindow (Application app) {
            _settings = app.settings;

            blur_row.model = new Gtk.StringList ({_("Never"), _("Always"), _("Art Only")});
            _settings.bind ("blur-mode", blur_row, "selected", SettingsBindFlags.DEFAULT);
            scale_slider.set_value (_settings.get_double ("ui-scale"));
            scale_slider.value_changed.connect (() => {
                var scale = scale_slider.get_value ();
                _settings.set_double ("ui-scale", scale);
                apply_ui_scale (scale);
            });
            _settings.bind ("compact-playlist", compact_btn, "active", SettingsBindFlags.DEFAULT);
            _settings.bind ("grid-mode", grid_btn, "active", SettingsBindFlags.DEFAULT);
            _settings.bind ("single-click-activate", single_btn, "active", SettingsBindFlags.DEFAULT);

            music_dir_btn.label = get_display_name (app.music_folder);
            music_dir_btn.clicked.connect (() => {
                pick_music_folder (app, this, (dir) => {
                    music_dir_btn.label = get_display_name (app.music_folder);
                });
            });

            _settings.bind ("monitor-changes", monitor_btn, "active", SettingsBindFlags.DEFAULT);
            _settings.bind ("remote-thumbnail", thumbnail_btn, "active", SettingsBindFlags.DEFAULT);
            _settings.bind ("play-background", playbkgnd_btn, "active", SettingsBindFlags.DEFAULT);
            _settings.bind ("rotate-cover", rotate_btn, "active", SettingsBindFlags.DEFAULT);

            update_css_file_label ();
            css_file_btn.clicked.connect (() => {
                pick_css_file (app, this);
            });
            css_reset_btn.clicked.connect (() => {
                _settings.set_string ("custom-css-path", "");
                update_css_file_label ();
            });

            replaygain_row.model = new Gtk.StringList ({_("Never"), _("Track"), _("Album")});
            _settings.bind ("replay-gain", replaygain_row, "selected", SettingsBindFlags.DEFAULT);

            _settings.bind ("show-peak", peak_row, "enable_expansion", SettingsBindFlags.DEFAULT);
            _settings.bind ("peak-characters", peak_entry, "text", SettingsBindFlags.DEFAULT);

            _settings.bind ("lyrics-prefer-synced", lyrics_prefer_synced_btn, "active", SettingsBindFlags.DEFAULT);
            _settings.bind ("lyrics-auto-select", lyrics_auto_select_btn, "active", SettingsBindFlags.DEFAULT);
            _settings.bind ("lyrics-plain-fallback", lyrics_plain_fallback_btn, "active", SettingsBindFlags.DEFAULT);

            lyrics_autoscroll_timeout_btn.set_value (_settings.get_int ("lyrics-autoscroll-timeout"));
            lyrics_autoscroll_timeout_btn.value_changed.connect (() => {
                _settings.set_int ("lyrics-autoscroll-timeout", (int) lyrics_autoscroll_timeout_btn.get_value ());
            });

            lyrics_auto_select_btn.notify["active"].connect (() => {
                update_auto_indicator ();
            });
            update_auto_indicator ();

            var order_str = _settings.get_string ("lyrics-provider-order");
            if (order_str == "") order_str = DEFAULT_PROVIDER_ORDER;
            _provider_order = order_str.split (",");

            // Append any provider not yet in saved order (forward compat)
            foreach (var p in LYRICS_PROVIDERS) {
                bool found = false;
                foreach (var id in _provider_order)
                    if (id == p.id) { found = true; break; }
                if (!found) _provider_order += p.id;
            }

            build_provider_rows ();

            GstPlayer.get_audio_sinks (_audio_sinks);
            var sink_names = new string[_audio_sinks.length];
            for (var i = 0; i < _audio_sinks.length; i++)
                sink_names[i] = get_audio_sink_name (_audio_sinks[i]);
            audiosink_row.model = new Gtk.StringList (sink_names);
            this.bind_property ("audio_sink", audiosink_row, "selected",
                BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);
        }

        private void update_auto_indicator () {
            bool auto_select = lyrics_auto_select_btn.active;
            if (auto_select) {
                lyrics_auto_indicator.title = _("Auto mode is ON");
                lyrics_auto_indicator.subtitle = _("Highest-scoring lyrics will be selected automatically");
            } else {
                lyrics_auto_indicator.title = _("Manual priority");
                lyrics_auto_indicator.subtitle = _("Provider order above will be respected");
            }
        }

        private void build_provider_rows () {
            foreach (var row in _provider_rows.get_values ())
                lyrics_providers_group.remove (row);
            _provider_rows.remove_all ();

            for (int i = 0; i < _provider_order.length; i++) {
                var id = _provider_order[i];
                LyricsProviderInfo? info = null;
                foreach (var p in LYRICS_PROVIDERS)
                    if (p.id == id) { info = p; break; }
                if (info == null) continue;
                var row = build_provider_row ((!)info, i);
                _provider_rows.set (id, row);
                lyrics_providers_group.add (row);
            }
        }

        private Adw.ActionRow build_provider_row (LyricsProviderInfo info, int index) {
            var row = new Adw.ActionRow ();
            row.title = info.display_name;
            row.subtitle = info.subtitle;
            row.add_prefix (new Gtk.Image.from_icon_name ("audio-x-generic-symbolic"));

            var up_btn = new Gtk.Button.from_icon_name ("go-up-symbolic");
            up_btn.valign = Gtk.Align.CENTER;
            up_btn.add_css_class ("flat");
            up_btn.sensitive = (index > 0);
            up_btn.tooltip_text = _("Move up");
            var captured_id = info.id;
            up_btn.clicked.connect (() => move_provider (captured_id, -1));
            row.add_prefix (up_btn);

            var down_btn = new Gtk.Button.from_icon_name ("go-down-symbolic");
            down_btn.valign = Gtk.Align.CENTER;
            down_btn.add_css_class ("flat");
            down_btn.sensitive = (index < _provider_order.length - 1);
            down_btn.tooltip_text = _("Move down");
            down_btn.clicked.connect (() => move_provider (captured_id, 1));
            row.add_prefix (down_btn);

            var sw = new Gtk.Switch ();
            sw.valign = Gtk.Align.CENTER;
            _settings.bind ("lyrics-%s-enabled".printf (info.id), sw, "active", SettingsBindFlags.DEFAULT);
            row.add_suffix (sw);
            row.activatable_widget = sw;

            return row;
        }

        private void move_provider (string id, int delta) {
            int idx = -1;
            for (int i = 0; i < _provider_order.length; i++)
                if (_provider_order[i] == id) { idx = i; break; }
            if (idx < 0) return;
            int new_idx = idx + delta;
            if (new_idx < 0 || new_idx >= _provider_order.length) return;
            var tmp = _provider_order[idx];
            _provider_order[idx] = _provider_order[new_idx];
            _provider_order[new_idx] = tmp;
            _settings.set_string ("lyrics-provider-order", string.joinv (",", _provider_order));
            build_provider_rows ();
        }

        public uint audio_sink {
            get {
                var app = (Application) GLib.Application.get_default ();
                var sink_name = app.player.audio_sink;
                for (int i = 0; i < _audio_sinks.length; i++)
                    if (sink_name == _audio_sinks[i].name) return i;
                return 0;
            }
            set {
                if (value < _audio_sinks.length) {
                    var app = (Application) GLib.Application.get_default ();
                    app.player.audio_sink = _audio_sinks[value].name;
                }
            }
        }

        public static void apply_ui_scale (double scale) {
            var win = Window.get_default ();
            if (win == null) return;
            // Scale icon sizes and apply zoom
            var css = new Gtk.CssProvider ();
            css.load_from_string ("window { -gtk-icon-size: %dpx; } .semitone-root { zoom: %g; }".printf (
                (int)(16 * scale), scale));
            var display = Gdk.Display.get_default ();
            if (display != null) {
                Gtk.StyleContext.add_provider_for_display (
                    (!)display, css,
                    Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
                );
            }
        }

        private void update_css_file_label () {
            var path = _settings.get_string ("custom-css-path");
            if (path.length == 0) {
                css_file_btn.label = _("None");
                css_reset_btn.sensitive = false;
            } else {
                var file = File.new_for_path (path);
                css_file_btn.label = file.get_basename ();
                css_reset_btn.sensitive = true;
            }
        }

        private void pick_css_file (Application app, Gtk.Window? parent) {
            var filter = new Gtk.FileFilter ();
            filter.name = _("CSS Files");
            filter.add_mime_type ("text/css");
            filter.add_pattern ("*.css");

            var current_path = _settings.get_string ("custom-css-path");
            File? initial = null;
            if (current_path.length > 0)
                initial = File.new_for_path (current_path);

#if GTK_4_10
            var filter_list = new ListStore (typeof (Gtk.FileFilter));
            filter_list.append (filter);
            var all_filter = new Gtk.FileFilter ();
            all_filter.name = _("All Files");
            all_filter.add_pattern ("*");
            filter_list.append (all_filter);
            var dialog = new Gtk.FileDialog ();
            dialog.filters = filter_list;
            dialog.set_default_filter (filter);
            if (initial != null)
                dialog.set_initial_file ((!)initial);
            dialog.modal = true;
            dialog.open.begin (parent, null, (obj, res) => {
                try {
                    var file = dialog.open.end (res);
                    var path = file.get_path ();
                    if (path != null) {
                        _settings.set_string ("custom-css-path", (!)path);
                        update_css_file_label ();
                    }
                } catch (Error e) {
                }
            });
#else
            var chooser = new Gtk.FileChooserNative (null, parent, Gtk.FileChooserAction.OPEN, null, null);
            chooser.modal = true;
            chooser.add_filter (filter);
            var all_filter = new Gtk.FileFilter ();
            all_filter.name = _("All Files");
            all_filter.add_pattern ("*");
            chooser.add_filter (all_filter);
            try {
                if (initial != null)
                    chooser.set_file ((!)initial);
            } catch (Error e) {
            }
            chooser.response.connect ((id) => {
                if (id == Gtk.ResponseType.ACCEPT) {
                    var file = chooser.get_file ();
                    if (file != null) {
                        var path = ((!)file).get_path ();
                        if (path != null) {
                            _settings.set_string ("custom-css-path", (!)path);
                            update_css_file_label ();
                        }
                    }
                }
            });
            chooser.show ();
#endif
        }
    }

    public string get_audio_sink_name (Gst.ElementFactory factory) {
        var name = factory.get_metadata ("long-name") ?? factory.name;
        name = name.replace ("Audio sink", "")
                    .replace ("Audio Sink", "")
                    .replace ("sink", "")
                    .replace ("(", "").replace (")", "");
        return name.strip ();
    }

    public delegate void FolderPicked (File dir);

    public void pick_music_folder (Application app, Gtk.Window? parent, FolderPicked picked) {
        var music_dir = File.new_for_uri (app.music_folder);
        show_select_folder_dialog.begin (parent, music_dir, (obj, res) => {
            var dir = show_select_folder_dialog.end (res);
            if (dir != null) {
                var uri = ((!)dir).get_uri ();
                if (app.music_folder != uri)
                    app.music_folder = uri;
                picked ((!)dir);
            }
        });
    }
}
