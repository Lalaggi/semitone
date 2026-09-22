# LRC+ Lyric Format — Official Specification

**Version:** 1.0 (frozen — for normative v2 spec see `LRCPLUS_SPEC_V2.md:1`)  
**Status:** Historical — reference implementation now follows v2; v1 file kept for backward compat reads.  
**Maintainer:** LRC+ is a standalone open format. Semitone (`gitlab.com/Lalaggi/semitone`) is a consumer/producer, not owner. Spec lives independently.  
**Encoding:** UTF-8  
**Line ending:** `LF` (`\n`, U+000A). `CRLF` tolerated on read (via `strip()`).

---

## 1. Overview

LRC+ is a strict superset of classic LRC (line-synced) that adds:

1. **Word-level timing** — start and end time per word, enabling karaoke-style highlighting.
2. **Voice / role annotation** — per-line singer / part identification (e.g. `v1`, `v2`, `bg`).

It preserves full backward compatibility with LRC: a decoder that ignores the timing lines still produces correct line-synced display. It is distinct from "Extended LRC" (`[mm:ss.xx]<mm:ss.xx>word<mm:ss.xx>word…`) which embeds inline timestamps.

MIME / informal identifier: `lrc+` (Semitone `LyricsFormat.LRC_PLUS`, source string `"lrc+"` in `src/lyrics/models.vala:56`).

---

## 2. File Structure

An LRC+ document is a sequence of **blocks** preceded by an optional **metadata header**:

```
[metadata lines]*
(block)*
```

### 2.1 Metadata header

Zero or more lines matching (case-sensitive prefix check in `src/lyrics/parser.vala:172`):

```
[offset: ±milliseconds]
[ti: title]
[ar: artist]
[al: album]
[by: author]
[length: mm:ss]
[re: player/editor]
[ve: version]
```

These lines are **must-ignore** on parse (`strip_lrc_metadata()`). Semitone strips them before parsing; serializers do not emit them. Unknown `[key: value]` lines not in this list are *not* metadata and are parsed as lyric lines if they contain a valid timestamp.

Whitespace before/after the line is ignored via `strip()`.

### 2.2 Block

Each block is **1 or 2 physical lines**:

```
[mm:ss.xx]{voice}Text<LF>
<word1:start:end|word2:start:end|…><LF>   ; optional, only if the following raw line starts with `<`
```

- The first line (header line) **must** start with `[` after stripping.
- The second line (timing line), if present, **must** start with `<` after stripping. If absent, the lyric line has no word timing (`words = []`).

Empty or whitespace-only lines are skipped.

Lines not starting with `[` are skipped. A file that contains no `<` at all yields an empty parse result (`if (!lrc.contains("<")) return {};` — `src/lyrics/parser.vala:186`).

---

## 3. Header Line — ABNF

```
header-line  = "[" timestamp "]" [voice-tag] text
timestamp    = minutes ":" seconds "." fraction
minutes      = 1*DIGIT        ; parsed as int, no upper bound; typically 0-99
seconds      = 1*DIGIT        ; parsed as int; should be 0-59 but not enforced
fraction     = 1*3DIGIT       ; 1→*100, 2→*10, 3→*1 to milliseconds; longer → error
voice-tag    = "{" role "}"
role         = *(%x20-7D except "}") ; any chars except "}", may be empty
text         = *(%x00-10FFFF except LF) ; may be empty; HTML entities decoded on parse
```

**Examples**

```
[00:12.34]Hello world
[01:05.00]{v2}Second singer line
[02:10.500]{bg}Background vocals
[00:00.10]{v1} Line with leading space preserved after strip
```

### 3.1 Timestamp semantics — `src/lyrics/parser.vala:633`

```vala
parts = ts.split(":")  // must be 2 parts
sec_parts = parts[1].split(".") // must be 2 parts
ms = minutes*60*1000 + seconds*1000 + frac_val_scaled
// frac_len 1 → *100, 2 → *10, 3 → *1; else → -1 (invalid)
```

- Return `-1` on invalid → line is **skipped** (continue).
- Range: not validated beyond parse; negative timestamps not produced except internal `-1` sentinel for unsynced lines.

Serializer (`src/lyrics/parser.vala:672`):

```vala
mins = ms / 1000 / 60
secs = (ms/1000) % 60
cs   = (ms % 1000) /10       // truncates to centiseconds
"[%02lld:%02lld.%02lld]"
```

Note: serializing loses millisecond → centisecond precision (10 ms granularity).

### 3.2 Voice tag semantics — `src/lyrics/parser.vala:204`

- If `rest` after `]` starts with `{`, scan for first `}`.
- If found, `voice_role = rest[1:tag_end-1]` and `rest` becomes `rest[tag_end+1:].strip()`.
- If no closing `}`, the `{` is treated as literal text.
- No enumeration enforced. Conventional values in Semitone codebase:
  - `""` (empty) — main voice / default (`v1` normalized to `""` in TTML paths)
  - `"bg"` — background vocals (rendered smaller, `src/lyrics/lyrics-sheet.vala:565`)
  - `"v1"`, `"v2"`, `"v3"`… — multi-person / duet.

Semitone's TTML import (`src/lyrics/parser.vala:456`) collapses `agent == "v1"` to `""`.

### 3.3 Text & entity decoding — `src/lyrics/parser.vala:625`

After extracting `rest`, `decode_html_entities` is applied:

```
&#x27; → '
&quot; → "
&amp;  → &
&lt;   → <
&gt;   → >
```

Replacement order matters (as coded). No other entities decoded.

Trailing/leading whitespace already stripped before decoding.

---

## 4. Timing Line — ABNF

```
timing-line = "<" inner ">"
inner       = word-entry *("|" word-entry)
word-entry  = word-text ":" start ":" end
word-text   = 1*(%x20-7D except ":" "|" "<" ">") ; decoded text; ":" not allowed
start       = float   ; seconds, 3 decimal places typically, parse via double.parse()
end         = float   ; seconds, >= start typically, not enforced
float       = 1*DIGIT "." 1*DIGIT ; locale-invariant "."
```

**Wire example (from `src/lyrics/providers/lyricsplus.vala:97` and serializer):**

```
<Hello:12.340:12.670|world:12.680:13.000>
```

**Parse steps — `src/lyrics/parser.vala:607`:**

1. Strip outer `<`/`>` if present.
2. `parts = inner.split("|")`
3. For each `part`: `segments = part.split(":")`; require `length >= 3`.
4. `text = decode_html_entities(segments[0])`, `start = double.parse(segments[1])`, `end = double.parse(segments[2])` — extra `:` segments beyond 3 are silently ignored (only first 3 used).

If the next raw line after a header line does **not** start with `<`, no words are attached and `i` is not advanced.

---

## 5. Data Model

After parsing, Semitone produces `LyricLine[]` (`src/lyrics/models.vala:9`):

```vala
struct LyricWord { string text; double start_sec; double end_sec; }
struct LyricLine { int64 time_ms; string text; LyricWord[] words; string voice_role; }
```

- `time_ms`: milliseconds from `parse_timestamp`; `-1` for unsynced lines (not used in LRC+).
- `text`: decoded header text.
- `words`: possibly empty; order preserved.
- `voice_role`: decoded role or `""`.

---

## 6. Format Detection — `src/lyrics/parser.vala:43`

Semitone distinguishes LRC+ from neighbours:

- If any stripped line starts with `<` and contains both `:` and `|` → `LRC_PLUS`.
- Else if any line matches `[...]` + inline `<mm:ss.xx>` → `EXTENDED_LRC`.
- Else if any line matches `[...]` with valid timestamp → `LRC`.
- Else → `PLAIN`.

This detection is **not** part of the format, but documents how Semitone routes.

---

## 7. Canonical Examples

### 7.1 Minimal line-synced LRC (also valid LRC+ without word line)

```
[00:10.00]First line
[00:15.50]Second line
```

### 7.2 Word-synced with voices

```
[00:10.00]Hello world
<Hello:10.000:10.320|world:10.330:10.800>
[00:12.00]{v2}Answer line
<Answer:12.000:12.400|line:12.410:12.900>
[00:14.00]{bg}Background oohs
<Background:14.000:14.500|oohs:14.510:15.000>
```

### 7.3 Full file with HTML entities

```
[ar: Artist]
[ti: Title]
[00:05.00]Don&#x27;t stop &amp; go
<Don&#x27;t:5.000:5.200|stop:5.210:5.400|&amp;:5.410:5.430|go:5.440:5.800>
```

### 7.4 Serialized form (Semitone canonical) — `src/lyrics/parser.vala:669`

```vala
"[%02lld:%02lld.%02lld]{voice}text\n<word:%.3f:%.3f|...>\n"
```

Voice omitted if empty. Timing line omitted if `words.length == 0`. Lines with `time_ms < 0` skipped.

---

## 8. Conformance Requirements

**Legacy-player safety (core guarantee):**

- A plain LRC parser must be able to read an LRC+ file and produce correct line-synced display by ignoring word-timing lines.
- Therefore `{attr}` / `{k:v|…}` blocks **must only appear on blocks that have a word-timing line** (i.e. LRC+ blocks). Pure line-synced blocks (`[mm:ss.xx]Text` with no following `<…>` line) **must not** emit any `{…}` block, otherwise legacy players would render it as literal text. Semitone's current `parse_lrc` also strips it, but third-party players do not.
- Similarly, unknown keys/effects inside `{…}` must be silently ignored — see §8.1.

**Producer must:**

- Emit header lines with valid `mm:ss.xx` (2-digit zero-padded via serializer).
- Emit timing line immediately after its header line, with no blank line in between.
- Preserve file order sorted ascending by `time_ms` (not enforced by parser but expected by renderer `src/lyrics/lyrics-sheet.vala:367`).
- Only emit `{…}` on lines that are followed by a timing line.

**Consumer must:**

- Strip metadata lines per §2.1.
- Ignore lines with invalid timestamps.
- Tolerate missing timing lines.
- Decode HTML entities per §3.3.
- Treat `{voice}` only when it appears immediately after `]` and is closed.

---

## 9. Differences From Extended LRC

| Feature | LRC+ | Extended LRC |
|---|---|---|
| Timing placement | Next line `<w:s:e\|…>` | Inline `<mm:ss.xx>` before each word |
| Time units | Seconds as float (`12.340`) | `mm:ss.xx` per word |
| Voice | `{role}` after timestamp | `v1:` prefix before first `<` |
| End time | Explicit per word | Inferred from next word/next line (`src/lyrics/parser.vala:298`) |

---

## 10. Known Limitations (as-implemented)

1. **Ambiguous delimiters** — `:` and `|` in word text break parsing (`split(":")` / `split("|")`).
2. **Truncation to centiseconds** on serialization loses 1-9 ms.
3. **No per-word voice** — voice is per line only.
4. **No translation/romanization tracks** — only single `text` per line.
5. **No empty timing line distinction** — `< >` vs missing line equivalent.
6. **Fraction length strictly 1-3 digits** — `00:10.5000` invalid though could be valid ms.
7. **HTML entity set minimal** — e.g. `&apos;` not decoded.
8. **`>` inside word text** not escaped.
9. Detection assumes `<` on word line; comment lines starting with `<` could mis-route.

---

## 11. References

- Implementation: `src/lyrics/parser.vala:185` `parse_lrc_plus`, `src/lyrics/parser.vala:607` `parse_word_timings`, `src/lyrics/parser.vala:669` `serialize_to_lrc_plus`, `src/lyrics/parser.vala:172` `strip_lrc_metadata`, `src/lyrics/models.vala:39` `LyricsFormat`
- TTML word-synced alternative: `src/lyrics/parser.vala:528` `parse_ttml_word_synced`
- Providers that emit LRC+: `src/lyrics/providers/lyricsplus.vala:61` `convert_richsync_json`, `src/lyrics/providers/paxsenix.vala:193` (TTML→LRC+ via `serialize_to_lrc_plus`)
- Cache/round-trip: `src/lyrics/lyrics-sheet.vala:803`

---

*End of specification.*
