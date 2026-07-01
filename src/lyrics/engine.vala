namespace G4 {

    public double lyrics_score_candidate (LyricLine[] lines, bool is_synced, string raw, int provider_index, string provider_name) {
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

            if (is_best) {
                lyrics_log ("New best candidate: %s (score=%.1f)".printf (c.provider, c.score));
                if (_timeout_triggered) {
                    candidate_available (c);
                }
            }
        }

        private void trigger_timeout () {
            if (_timeout_triggered) return;
            _timeout_triggered = true;

            lyrics_log ("=== PROVIDER TIMEOUT (%dms) ===".printf (PROVIDER_TIMEOUT_MS));
            if (_best_candidate != null) {
                var b = (!)_best_candidate;
                lyrics_log ("Using best so far: %s (score=%.1f, %d lines)".printf (
                    b.provider, b.score, b.lines.length));
                candidate_available (b);
            } else {
                lyrics_log ("No candidates yet, waiting...");
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

            var app = (Application) GLib.Application.get_default ();
            var duration = app.player.duration;
            var duration_ms = duration != Gst.CLOCK_TIME_NONE ? (int) (GstPlayer.to_second (duration) * 1000) : 0;

            var timeout_id = Timeout.add (PROVIDER_TIMEOUT_MS, () => {
                trigger_timeout ();
                return GLib.Source.REMOVE;
            });

            for (int pi = 0; pi < provider_order.length; pi++) {
                if (cancellable != null && ((!)cancellable).is_cancelled ()) {
                    lyrics_log ("load_lyrics: cancelled, stopping provider loop");
                    break;
                }
                var pid = provider_order[pi].strip ();
                lyrics_log ("Trying %s...".printf (pid));

                try {
                    var candidate = yield lyrics_fetch_provider (pid, music, duration_ms, settings, pi, cancellable);
                    if (cancellable != null && ((!)cancellable).is_cancelled ()) break;
                    if (candidate != null) {
                        var c = (!)candidate;
                        lyrics_log ("%s: %d lines synced=%s, score=%.1f".printf (
                            c.provider, c.lines.length, c.is_synced.to_string (), c.score));
                        process_candidate (c);
                    }
                } catch (Error e) {
                    lyrics_log ("Provider %s error: %s".printf (pid, e.message));
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
