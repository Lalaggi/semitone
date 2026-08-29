namespace G4 {

    public class QueueSheet : Object {
        private Application _app;
        private MusicList _list;
        public Adw.BottomSheet bottom_sheet;
        private Gtk.Label _count_label;
        private Gtk.Button _clear_btn;
        private Gtk.Box _box;
        private uint _resize_timeout = 0;

        public QueueSheet (Application app) {
            _app = app;

            _box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            var box = _box;
            box.vexpand = true;
            box.valign = Gtk.Align.FILL;

            var header = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
            header.add_css_class ("toolbar");
            header.margin_top = 24;
            header.hexpand = true;
            var title = new Gtk.Label (_("Queue"));
            title.add_css_class ("title-4");
            title.halign = Gtk.Align.CENTER;
            title.hexpand = true;
            header.append (title);
            box.append (header);

            _count_label = new Gtk.Label (null);
            _count_label.add_css_class ("dim-label");
            _count_label.halign = Gtk.Align.CENTER;
            _count_label.hexpand = true;
            // keep label for footer, not header, to avoid widening header
            _clear_btn = new Gtk.Button.from_icon_name ("edit-clear-all-symbolic");
            _clear_btn.tooltip_text = _("Clear Queue");
            _clear_btn.add_css_class ("flat");
            _clear_btn.clicked.connect (on_clear_clicked);

            // Editable=true enables drag reordering + drop target; selectable=true enables multi-select remove
            _list = new MusicList (app, typeof (Music), null, true, true);
            _list.data_store = app.music_queue;
            _list.has_add_to_queue = false;
            // Force vertical single-column list (avoid left→right grid on wide windows)
            _list.max_columns = 1;
            _list.set_propagate_natural_height (false);
            // In queue context, "Add to Queue" is meaningless
            _list.vexpand = true;
            // hide Queue button in selection header for queue itself
            // access protected field via workaround: after construction, set flag via method
            // We expose via internal field; direct access allowed within same namespace
            _list.item_activated.connect ((position, obj) => {
                app.current_item = (int) position;
                app.player.play ();
            });
            var thumbnailer = app.thumbnailer;
            var loading_paintable = thumbnailer.create_simple_text_paintable ("...", Thumbnailer.ICON_SIZE);
            _list.item_binded.connect ((item) => {
                var entry = item.child as MusicEntry?;
                var music = (Music) item.item;
                if (entry == null) return;
                ((!)entry).paintable = loading_paintable;
                ((!)entry).set_titles (music, SortMode.TITLE);
            });
            _list.set_empty_text (_("Queue is empty"));
            
            box.append (_list);

            var footer = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
            footer.margin_start = 12;
            footer.margin_end = 12;
            footer.margin_bottom = 12;
            footer.margin_top = 6;
            footer.spacing = 6;

            var shuffle_btn = new Gtk.ToggleButton ();
            shuffle_btn.icon_name = "media-playlist-shuffle-symbolic";
            shuffle_btn.tooltip_text = _("Shuffle Queue");
            shuffle_btn.add_css_class ("flat");
            shuffle_btn.active = app.queue_shuffled;
            shuffle_btn.opacity = app.queue_shuffled ? 1.0 : 0.5;
            app.notify["queue-shuffled"].connect (() => {
                shuffle_btn.active = app.queue_shuffled;
                shuffle_btn.opacity = app.queue_shuffled ? 1.0 : 0.5;
            });
            shuffle_btn.toggled.connect (() => {
                app.queue_shuffled = shuffle_btn.active;
                if (shuffle_btn.active) {
                    shuffle_btn.opacity = 1.0;
                    
                    var current = app.current_music;
                    if (current != null) {
                        var store = app.music_queue;
                        var count = store.get_n_items ();
                        
                        if (count > 1) {
                            var arr = new GenericArray<Music> (count);
                            for (var pos = 0; pos < count; pos++) {
                                arr.add ((Music) store.get_item (pos));
                            }
                            
                            int current_idx = -1;
                            for (var i = 0; i < count; i++) {
                                if (arr[i].uri == ((!)current).uri) {
                                    current_idx = i;
                                    break;
                                }
                            }
                            
                            if (current_idx > 0) {
                                var temp = arr[0];
                                arr[0] = arr[current_idx];
                                arr[current_idx] = temp;
                            }
                            
                            for (var i = arr.length - 1; i > 1; i--) {
                                var r = Random.int_range (1, i + 1);
                                var s = arr[i];
                                arr[i] = arr[r];
                                arr[r] = s;
                            }
                            
                            store.splice (0, count, (Object[]) arr.data);
                        }
                    }
                } else {
                    shuffle_btn.opacity = 0.5;
                    app.restore_queue_order ();
                }
                var index = find_item_in_model (_list.filter_model, app.current_music);
                if (index != -1)
                    _list.scroll_to_item (index);
                update_count ();
            });

            footer.append (shuffle_btn);

            var jump_btn = new Gtk.Button.from_icon_name ("go-up-symbolic");
            jump_btn.tooltip_text = _("Scroll to playing");
            jump_btn.add_css_class ("flat");
            jump_btn.clicked.connect (() => {
                var idx = find_item_in_model (_list.filter_model, _app.current_music);
                if (idx != -1)
                    _list.scroll_to_item (idx);
            });
            // Highlight when current not visible
            _list.filter_model.items_changed.connect (() => {
                jump_btn.sensitive = _app.current_music != null && _app.music_queue.get_n_items () > 0;
            });
            app.music_changed.connect (() => {
                jump_btn.sensitive = _app.current_music != null;
            });
            jump_btn.sensitive = _app.current_music != null;
            footer.append (jump_btn);

            _count_label.hexpand = true;
            _count_label.vexpand = false;
            footer.append (_count_label);

            var select_btn = new Gtk.Button.from_icon_name ("checkbox-checked-symbolic");
            select_btn.tooltip_text = _("Select");
            select_btn.add_css_class ("flat");
            select_btn.clicked.connect (() => _list.multi_selection = true);
            footer.append (select_btn);

            footer.append (_clear_btn);

            box.append (footer);

            bottom_sheet = new Adw.BottomSheet ();

            bottom_sheet.sheet = box;
            bottom_sheet.modal = true;

            bottom_sheet.notify["open"].connect (() => {
                if (bottom_sheet.open) {
                    update_box_height ();
                    if (_resize_timeout == 0) {
                        _resize_timeout = GLib.Timeout.add (100, on_resize_timeout);
                    }
                } else {
                    if (_resize_timeout != 0) {
                        GLib.Source.remove (_resize_timeout);
                        _resize_timeout = 0;
                    }
                }
            });

            // Hide internal Queue button in selection header (queue already is queue)
            // Must be done after list constructed; access protected field via public tweak
            // We keep has_add_to_queue true but selection header will hide queue btn for queue store?
            // Instead we override by removing that button after header created lazily
            // Hook into multi_selection setter to adjust visibility
            _list.notify["multi-selection"].connect (() => {
                // No extra handling needed; MusicList will create header on first multi_selection
            });

            app.index_changed.connect ((index, size) => {
                _list.current_node = app.current_music;
                update_count ();
            });
            app.music_changed.connect ((music) => {
                _list.current_node = music;
                update_count ();
            });
            app.music_queue.items_changed.connect (() => {
                update_count ();
                _list.set_empty_text (_("Queue is empty"));
                // Any direct manipulation of queue (drag reorder / remove) should mark list modified
                // Avoid marking during initial loading
                if (!app.loading)
                    app.list_modified = true;
            });
            // Also update when thumbnail changes? not needed for count
            update_count ();

            app.notify["queue-shuffled"].connect (() => update_count ());
        }

        public MusicList queue_list {
            get { return _list; }
        }

        public void open () {
            var index = find_item_in_model (_list.filter_model, _app.current_music);
            if (index != -1)
                _list.scroll_to_item (index);
            bottom_sheet.open = true;
        }

        private void update_count () {
            var n = _app.music_queue.get_n_items ();
            var suffix = n == 1 ? _("1 track") : _("%u tracks").printf (n);
            // Show index if playing
            var idx = _app.current_item;
            if (idx >= 0 && n > 0)
                _count_label.label = @"$(idx+1)/$(n) · $suffix";
            else
                _count_label.label = suffix;
            _clear_btn.sensitive = n > 0;
            _clear_btn.visible = n > 0;
        }

        private void on_clear_clicked () {
            var n = _app.music_queue.get_n_items ();
            if (n == 0) return;
            show_alert_dialog.begin (_("Clear queue?"), bottom_sheet.get_root () as Gtk.Window, (obj,res) => {
                var ok = show_alert_dialog.end (res);
                if (ok) {
                    _app.clear_queue ();
                }
            });
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

        private bool on_resize_timeout () {
            if (bottom_sheet.open) {
                update_box_height ();
            }
            return true;
        }
    }
}
