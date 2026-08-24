namespace G4 {

    public enum EllipsizeMode {
        NONE = Pango.EllipsizeMode.NONE,
        START = Pango.EllipsizeMode.START,
        MIDDLE = Pango.EllipsizeMode.MIDDLE,
        END = Pango.EllipsizeMode.END,
        MARQUEE
    }

    public class StableLabel : Gtk.Widget {
        private EllipsizeMode _ellipsize = EllipsizeMode.NONE;
        private Gtk.Label _label = new Gtk.Label (null);
        private float _label_offset = 0;
        private int _label_width = 0;

        construct {
            _label.xalign = 0;
            _label.set_parent (this);
        }

        ~StableLabel () {
            _label.unparent ();
        }

        public EllipsizeMode ellipsize {
            get {
                return _ellipsize;
            }
            set {
                _ellipsize = value;
                _label.ellipsize = value == EllipsizeMode.MARQUEE ? Pango.EllipsizeMode.NONE : (Pango.EllipsizeMode) value;
                stop_tick ();
            }
        }

        public string label {
            get {
                return _label.label;
            }
            set {
                _label.label = value;
                stop_tick ();
            }
        }

        public bool marquee {
            get {
                return _ellipsize == EllipsizeMode.MARQUEE;
            }
            set {
                ellipsize = value ? EllipsizeMode.MARQUEE : EllipsizeMode.NONE;
            }
        }

        public override void measure (Gtk.Orientation orientation, int for_size, out int minimum, out int natural, out int minimum_baseline, out int natural_baseline) {
            if (orientation == Gtk.Orientation.VERTICAL) {
                // Ensure enough space for different text
                var text = _label.label;
                _label.label = "A中";
                _label.measure (orientation, for_size, out minimum, out natural, out minimum_baseline, out natural_baseline);
                _label.label = text;
            } else {
                _label.measure (orientation, for_size, out minimum, out natural, out minimum_baseline, out natural_baseline);
                _label_width = natural;
                if (marquee)
                    minimum = 0;
            }
        }

        public override void size_allocate (int width, int height, int baseline) {
            var allocation = Gtk.Allocation ();
            allocation.x = 0;
            allocation.y = 0;
            allocation.width = width;
            allocation.height = height;
            _label.allocate_size (allocation, baseline);
            update_tick_delayed ();
        }

        private static float SPACE = 40f;

        public override void snapshot (Gtk.Snapshot snapshot) {
            var width = get_width ();
            var overflow = marquee && width < _label_width;
            if (!overflow) {
                snapshot_child (_label, snapshot);
                return;
            }
            var height = get_height ();
            var total_width = _label_width + SPACE;
            var bounds = Graphene.Rect ();
            bounds.init (0, 0, width, height);
            snapshot.push_clip (bounds);
            if (_label_offset < _label_width) {
                snapshot.save ();
                var point = Graphene.Point ();
                point.init (- _label_offset, 0);
                snapshot.translate (point);
                snapshot_child (_label, snapshot);
                snapshot.restore ();
            }
            if (_label_offset >= total_width - width) {
                snapshot.save ();
                var point = Graphene.Point ();
                point.init (- _label_offset + total_width, 0);
                snapshot.translate (point);
                snapshot_child (_label, snapshot);
                snapshot.restore ();
            }
            snapshot.pop ();
        }

        private uint _pixels_per_second = 24;
        private uint _tick_handler = 0;
        private bool _tick_moving = false;
        private int64 _tick_start_time = 0;

        private bool on_tick_callback (Gtk.Widget widget, Gdk.FrameClock clock) {
            if (_tick_moving) {
                var now = get_monotonic_time ();
                var elapsed = (now - _tick_start_time) / 1e6f;
                _label_offset = elapsed * _pixels_per_second;
                if (_label_offset > _label_width + SPACE) {
                    stop_tick ();
                    update_tick_delayed ();
                }
                queue_draw ();
            }
            return true;
        }

        private void stop_tick () {
            if (_tick_handler != 0) {
                remove_tick_callback (_tick_handler);
                _tick_handler = 0;
            }
            if (_timer_id != 0) {
                Source.remove (_timer_id);
                _timer_id = 0;
            }
            _label_offset = 0;
            _tick_moving = false;
        }

        private void update_tick () {
            var need_tick = marquee && get_width () < _label_width;
            if (need_tick && _tick_handler == 0) {
                _tick_handler = add_tick_callback (on_tick_callback);
                _tick_moving = _tick_handler != 0;
                _tick_start_time = get_monotonic_time ();
            } else if (!need_tick && _tick_handler != 0) {
                stop_tick ();
            }
        }

        private static uint TICK_WAIT = 3000;
        private uint _timer_id = 0;

        private void update_tick_delayed () {
            if (_timer_id == 0) {
                _timer_id = run_timeout_once (TICK_WAIT, () => {
                    _timer_id = 0;
                    update_tick ();
                });
            }
        }
    }
}