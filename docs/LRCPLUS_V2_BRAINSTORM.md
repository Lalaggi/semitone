# LRC+ v2 — Brainstorm / RFC

This document is **not** normative. It explores your prompt: richer `{…}` styling, Enhanced-LRC-style word lines, graceful degradation, per-word effects, voice separation, and keeping LRC+ independent from Semitone.

---

## 1. Design Principles for v2

1. **Graceful degradation at every level** — unknown `{key}` / `{key:value}` / per-word `{…}` must be droppable. A v1 parser should still render the line text; a line-synced parser should still render the line; a plain-text parser should still show something.
2. **No breakage of legacy LRC** — `*.lrc` readers that only understand `[mm:ss.xx]Text` must never see `{…}` noise unless they already opted into LRC+. Rule: `{…}` only on blocks that have a word-timing line (enforced in `LRCPLUS_SPEC.md:8`).
3. **Human-editable** — keep line-per-voice, short tags, visible timings. No binary/JSON envelope.
4. **Unambiguous grammar** — eliminate the `:`/`|`/`>` collisions in current `parse_word_timings` (`src/lyrics/parser.vala:607` uses `split(":")`/`split("|")`).
5. **Independent spec** — semitone consumes v2; it doesn't own it.

---

## 2. Your Proposal Summarised

> Convert generic `{v1}` → `{voice:v1|effect:shake|format:bold,underline}` on header lines, offer TTML-like feature-set, allow players to skip anything unknown and still work as plain LRC. Replace `<word:start:end|…>` bulk line with EnhancedLRC-style `<start:end>Word` sequence, allow per-word `{…}` for effects. Keep multi-voice as separate lines (don't merge multiple voices onto one line) for readability/parsing. Isolate `{…}` to word-synced blocks only.

All of these are compatible with principles above, with caveats discussed below.

---

## 3. Header Attribute Block — `{k:v|k:v}`

### 3.1 Current v1 — `src/lyrics/parser.vala:204`

```
[00:10.00]{v2}Text
```

`{v2}` is opaque string.

### 3.2 Proposed v2

```
[00:10.00]{voice:v2|effect:shake|format:bold,underline}Text
[00:12.00]{voice:bg|format:italic}Background line
[00:14.00]{lang:en}Original   ; future: translation track?
```

**Grammar:**

```
attr-block = "{" attr *("|" attr) "}"
attr       = key [":" value]
key        = ALPHA *(ALPHA / DIGIT / "-" / "_")
value      = *(value-char except "|" / "}" / ",") *("," *(value-char except "|" / "}" / ","))
```

- `key` is case-insensitive, canonical lowercase.
- `value` may be comma-list (for `format:bold,underline`), otherwise single token.
- Unknown `key` → **must ignore** that attr, keep rest of block.
- Unknown `value` token → ignore that token only (e.g. `effect:unknown` → no effect, no error).
- Empty block `{}` → no attrs.
- Duplicated key → last wins.

**Backward compat:** v1 parsers that do `role = inner` will see `"voice:v2|effect:shake"` as a single voice string. That's not fatal but noisy. Options:

- **A) Dual-write:** keep `{v2}` shorthand as alias for `{voice:v2}`. Parser accepts both: if inner contains `:` or `|` treat as v2 kv-block, else treat as legacy `voice`.
- **B) Version flag:** `[ve: LRC+2]` header signals new block — old parsers that ignore unknown metadata still degrade (they'll show the kv string). Mitigated by principle 2: those lines already have a word line and legacy plain-LRC readers skip the word line but *would* show `{voice:v2|…}` as text. So for strict legacy plain-LRC safety, producers targeting plain-LRC fallback should avoid kv on non-word lines (already required) and ideally keep kv short. Tradeoff noted.

**Recommended keys:**

| Key | Values | Notes | TTML equivalent |
|---|---|---|---|
| `voice` | `v1` `v2` `bg` `lead` `duet` … | singer/part | `agent`, `role=x-bg` (`src/lyrics/parser.vala:456`) |
| `effect` | `shake` `wobble` `glow` `karaoke` … | animation; skip if unknown | `style` |
| `format` | `bold` `italic` `underline` `strike` | inline style, comma-list | `tts:fontWeight` etc |
| `color` | `#RRGGBB` `red` … | optional | `tts:color` |
| `lang` | `en` `ja` `romanized` | future multi-track | `xml:lang` |

Players skipping unknown keys satisfy "skip ANYTHING they don't understand".

### 3.3 Voice-on-same-line vs. separate-line

You noted: separate lines per voice even at same timestamp are easier to parse/edit and already work. Agree.

- **Keep as v2 SHOULD:** one voice per block. If duet simultaneous, duplicate timestamp:
  ```
  [00:10.00]{voice:v1}Hello
  <Hello:10.000:10.400>
  [00:10.00]{voice:v2}World
  <World:10.000:10.460>
  ```
  Renderer can overlap them or stack; per `src/lyrics/lyrics-sheet.vala:367` active voices tracked by `voice_role`, so overlap is already supported.
- **MUST NOT** introduce `{voice:v1,v2}` or inline voice switch mid-line — harder to edit and to degrade. If needed, allow but define as two blocks instead — mention as "discouraged".
- Exception: `{voice:bg}` often coincides temporally with lead; keep separate line as semitone already does (`src/lyrics/parser.vala:519` emits bg as separate `LyricLine` at same `ms`).

---

## 4. Word-Timing Line Redesign — From Bulk to Inline

### 4.1 Current v1 — `src/lyrics/parser.vala:669`

```
[00:10.00]Hello world
<Hello:10.000:10.320|world:10.330:10.800>
```
Problems: `:`/`|` in text breaks `split`, no per-word attrs, dense, not skippable word-by-word.

### 4.2 Proposed v2 — EnhancedLRC-style with per-word attrs

Two variants discussed; both keep the *separate-line* placement (so plain LRC ignores it):

**Variant A — Absolute LRC timestamps (preferred for legacy familiarity):**

```
[00:10.00]{voice:v1}Hello world
<00:10.00:00:10.32>Hello <00:10.33:00:10.80>world
<00:10.00:00:10.32>{format:bold}Hello <00:10.33:00:10.80>{effect:shake}world
```

- `<mm:ss.xx:mm:ss.xx>` or `<mm:ss.xx>` (end inferred from next start / line end) before each word.
- Per-word `{…}` optional **after** the timing, before the word — unknown attrs skipped, word still renders.
- Whitespace between timing and word is significant delimiter but collapsed to one space on render.

**Variant B — Relative floats (closer to v1):**

```
<10.000:10.320>Hello <10.330:10.800>world
```

Less readable, millisecond drift, harder to eyeball — not recommended. Stay with `mm:ss.xx` like EnhancedLRC so `parse_timestamp` (`src/lyrics/parser.vala:633`) can be reused.

**Recommendation:** Adopt Variant A. Provide both `start` only and `start:end` forms:

```
word-timing-line = * ( [WS] "<" timestamp [":" timestamp] ">" [WS] [word-attrs] word-text )
word-attrs       = "{" attr *("|" attr) "}"
timestamp        = minutes ":" seconds "." fraction  ; same as header, 1-3 frac digits
```

- If `end` omitted, consumer infers `end = next_word_start` or `line_end` (as `src/lyrics/parser.vala:298` does for Extended LRC).
- Timing is **absolute track time**, not line-relative — avoids cumulative error and makes line reordering safe.
- Word text runs up to next `<` or EOL; therefore word may contain `:` `|` without escaping — fixes limitation #1 in `LRCPLUS_SPEC.md:10`.

**Degradation:**

- Plain LRC reader: skips entire line (starts with `<`) → clean fallback.
- v1 LRC+ reader: would not understand new line; but still shows header line. That's acceptable v1→v2 compat. To aid mixed fleets, producers may emit *both* lines during transition? Not ideal. Better to bump detection (file contains `<mm:ss` pattern → v2) and treat v1 `<word:…>` as deprecated.
- Per-word `{…}`: parser that doesn't understand it strips it and keeps word.

### 4.3 Selective emission rule (your constraint)

> `{…}` blocks only on LRC+ lines, NOT on plain LRC lines.

Enforce:

- `LRC` block (no timing line) → `header-line = "[" timestamp "]" text` **no** `{…}` allowed (lint error if present; parser may treat as text to force visibility of misuse).
- `LRC+` block (has timing line) → header `attr-block` + per-word `attr-block` allowed.

This makes a file valid in `mp3tag` / old players without modification.

### 4.4 Escaping

Because word text no longer uses `:`/`|` separators, only `<` and `{` need handling if they appear literally in lyrics:

- Escape as `&lt;` `&gt;` `&amp;` (already supported via `decode_html_entities` `src/lyrics/parser.vala:625`) or `\<`.
- Keep HTML entities for compatibility.
- Document that raw `<` not followed by timestamp pattern is treated as text (tolerant).

---

## 5. Styling Choices — What to Standardise vs. Leave Application-Defined

Effect/format keys should be **advisory**. Suggested v2 core set is small; everything else is extension:

- **Core (must be recognised if present):** `voice`, `format:bold,italic,underline,strike`, `lang`.
- **Extension (may be ignored):** `effect:shake,wobble,glow,blur`, `color`, `ruby`, `outline`.
- Value `format` comma-list allows combining: `format:bold,underline`.
- Document example CSS-like mapping but don't mandate rendering. TTML `style` already has this philosophy (`src/lyrics/parser.vala:470` `role=x-bg`).

Implementation advice: semitone's `lyrics-sheet.vala:565` would map `format:bold` → `font-weight`, `effect:shake` → animation tag if known, else no-op.

---

## 6. Open Questions / Tradeoffs

1. **Timestamp granularity** — Keep `mm:ss.xx` (centisecond) string but parse with 1-3 digits. Serializing currently truncates (`cs = ms%1000/10`): should v2 keep ms precision (`mm:ss.xxx`, 3 digits) to avoid loss?
2. **Line delimiter** — Should there be an explicit block terminator or is adjacency (`header-line` then `timing-line`) sufficient? Adjacency is fragile if editor inserts blank line; maybe allow but define that blank line inside a block is ignored.
3. **Compression** — For dense rap, Variant A adds ~14 chars per word. Acceptable, but worth noting vs. compact `<w:s:e|…>`. Tradeoff: readability/escaping vs. size.
4. **Duplicate timestamp sharing** — If two words share same start (chord), Variant A repeats full timestamp; okay.
5. **Multi-track translations** — Out of scope for this header-role focus, but note that `lang` opens path to `[00:10.00]{lang:ja}…` parallel lines. Should they share timings or have independent timing lines? Recommend independent.
6. **Detection** — Update `detect_lyrics_format` (`src/lyrics/parser.vala:43`) to distinguish v2 inline timings after header vs. v1 bulk line; both start with `<` but v2 contains `:` with `mm:ss` pattern while v1 contains `word:` — can key on that.

---

## 7. Migration Path (for semitone as consumer)

1. Parser: branch `parse_lrc_plus_v2` that first tries inline `<mm:ss` pattern, falls back to v1 bulk `<word:`; both populate same `LyricWord[]`/`LyricLine.voice_role` plus new `attrs` bag.
2. Serializer flag: `--lrcplus-version 1|2` (default 2 for new files, 1 for compat).
3. Keep cache `serialize_to_lrc_plus` (`src/lyrics/lyrics-sheet.vala:803`) version-aware; bump cache key if format changed.
4. Lint in editor (`src/lyrics/lyrics-sheet.vala:633` edit dialog) to warn if `{…}` on plain-LRC line.

---

## 8. Minimal v2 Example (applying all suggestions)

```
[ti: Example]
[ar: Test]
[00:10.00]{voice:v1|format:bold}Hello world
<00:10.00:00:10.32>Hello <00:10.33:00:10.80>world

[00:12.00]{voice:v2|effect:shake}Answer you
<00:12.00:00:12.40>{format:underline}Answer <00:12.41:00:12.90>you

[00:14.00]{voice:bg|format:italic}ooh ah
<00:14.00:00:14.50>ooh <00:14.51:00:15.00>ah

[00:20.00]Plain line with no word timings - no attrs, safe for old players
```

- Plain player shows 4 lines, timing line skipped, `{…}` only on first 3 lines (which that player already skips word lines for) — so degradation is clean if the player also skips `{…}`? Wait: plain player would still see `{voice:v1|format:bold}` as text. Mitigated by principle 2's exemption: those lines *do* have word lines, so plain player that skips word lines but renders header lines literally *will* see kv. Solution: document that strict legacy fallback requires stripping `attr-block` before display — recommend legacy players upgrade to at least strip `{…}` via regex. Alternatively, producers targeting maximum legacy should continue emitting `{v1}` shorthand which old LRC+ aware players hide. Discuss.

---

## 9. Decisions Locked (2026-08-27 — post-crash answers)

- [x] `key:value|key:value` KV blocks — **Yes, use KV** (not `key=value;`)
- [x] Word timing — **Variant A absolute** `<mm:ss.xx:mm:ss.xx>Word` (not floats/bulk)
- [x] Styling key — **`style`** (not `format`): `style:bold,underline`
- [x] Strict isolation — **Strict, enforce**: no `{…}` without following timing line
- [x] Voice alias — **Alias, keep {v1}** as shorthand for `{voice:v1}`

→ Folded into normative `LRCPLUS_SPEC_V2.md:1`.

