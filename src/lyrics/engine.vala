namespace G4 {

    public double lyrics_score_candidate (LyricLine[] lines, LyricsFormat format, int provider_index, string provider_name) {
        double quality_score = 0.0;
        switch (format) {
            case LyricsFormat.TTML_WORD_SYNCED:
            case LyricsFormat.LRC_PLUS:
            case LyricsFormat.EXTENDED_LRC:
                quality_score = 50.0;
                break;
            case LyricsFormat.TTML_LINE_SYNCED:
            case LyricsFormat.LRC:
                quality_score = 30.0;
                break;
            case LyricsFormat.PLAIN:
            case LyricsFormat.TTML_UNSYNCED:
                quality_score = 10.0;
                break;
        }

        int non_empty = 0;
        foreach (var l in lines)
            if (l.text.strip ().length > 0) non_empty++;
        double completion = lines.length > 0 ? (double) non_empty / lines.length : 0.0;
        double completion_score = completion * 20.0;

        bool synced = format != LyricsFormat.PLAIN && format != LyricsFormat.TTML_UNSYNCED;
        double synced_pref = 0.0;
        var app = (Application) GLib.Application.get_default ();
        if (app.settings.get_boolean ("lyrics-prefer-synced"))
            synced_pref = synced ? 6.0 : -6.0;

        double order_score = GLib.Math.fmax (0.0, (10.0 - provider_index) * 1.5);

        double trust_bonus = 0.0;
        if (provider_name == "BetterLyrics" || provider_name == "Unison" || provider_name == "BiniLyrics" || provider_name == "SimpMusic")
            trust_bonus = 4.0;
        else if (provider_name == "LRCLib")
            trust_bonus = 3.0;
        else if (provider_name == "LyricsPlus" || provider_name == "NetEase" || provider_name == "KuGou")
            trust_bonus = 2.0;
        else if (provider_name == "PaxSenix")
            trust_bonus = 1.0;

        return quality_score + completion_score + synced_pref + order_score + trust_bonus;
    }

    public class LyricsEngine : Object {
        private const int PROVIDER_TIMEOUT_MS = 5000;
        private bool _timeout_triggered = false;
        private LyricsCandidate? _best_candidate = null;
        private double _best_candidate_score = 0.0;
        public signal void candidate_available (LyricsCandidate candidate);

        private void process_candidate (LyricsCandidate c) {
            bool is_best = false;

            if (_best_candidate == null || c.score > _best_candidate_score) {
                _best_candidate = c;
                _best_candidate_score = c.score;
                is_best = true;
            }

            if (is_best && _timeout_triggered) {
                candidate_available (c);
            }
        }

        private void trigger_timeout () {
            if (_timeout_triggered) return;
            _timeout_triggered = true;

            lyrics_log ("=== TIMEOUT (%dms) ===".printf (PROVIDER_TIMEOUT_MS));
            if (_best_candidate != null) {
                var b = (!)_best_candidate;
                lyrics_log ("Winner: %s (%.1f)".printf (b.provider, b.score));
                candidate_available (b);
            }
        }

        public async LyricsCandidate? load_lyrics (Music music, Settings settings, GLib.Cancellable? cancellable = null) {
            _timeout_triggered = false;
            _best_candidate = null;
            _best_candidate_score = 0.0;

            var order_str = settings.get_string ("lyrics-provider-order");
            if (order_str == "")
                order_str = DEFAULT_PROVIDER_ORDER;
            string[] provider_order = order_str.split (",");

            // Append any provider not yet in the saved order (forward compat,
            // so newly added providers are still queried for existing users)
            foreach (var p in LYRICS_PROVIDERS) {
                bool found = false;
                foreach (var id in provider_order)
                    if (id.strip () == p.id) { found = true; break; }
                if (!found) provider_order += p.id;
            }

            var app = (Application) GLib.Application.get_default ();
            var duration = app.player.duration;
            var duration_ms = duration != Gst.CLOCK_TIME_NONE ? (int) (GstPlayer.to_second (duration) * 1000) : 0;

            var timeout_id = Timeout.add (PROVIDER_TIMEOUT_MS, () => {
                trigger_timeout ();
                return GLib.Source.REMOVE;
            });

            bool auto_select = settings.get_boolean ("lyrics-auto-select");

            for (int pi = 0; pi < provider_order.length; pi++) {
                if (cancellable != null && ((!)cancellable).is_cancelled ()) break;
                var pid = provider_order[pi].strip ();

                try {
                    var candidate = yield lyrics_fetch_provider (pid, music, duration_ms, settings, pi, cancellable);
                    if (cancellable != null && ((!)cancellable).is_cancelled ()) break;
                    if (candidate != null) {
                        var c = (!)candidate;
                        if (!auto_select) {
                            if (!_timeout_triggered)
                                Source.remove (timeout_id);
                            _best_candidate = null;
                            _best_candidate_score = 0.0;
                            return c;
                        }
                        lyrics_log ("%s: Score=%.1f | Synced=%s | Source=%s".printf (
                            c.provider, c.score,
                            lyrics_format_synced (c.format),
                            lyrics_format_source (c.format)));
                        process_candidate (c);
                    } else {
                        lyrics_log ("%s: no match".printf (pid));
                    }
                } catch (Error e) {
                    lyrics_log ("%s: error: %s".printf (pid, e.message));
                }
            }

            if (!_timeout_triggered)
                Source.remove (timeout_id);

            var best = _best_candidate;
            _best_candidate = null;
            _best_candidate_score = 0.0;

            return best;
        }
    }
}
