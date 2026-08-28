# Agent Task: Port Semitone to LRC+ v2

You are a coding agent. Your job is to finish porting **Semitone** (`gitlab.com/Lalaggi/semitone`, local path `/home/elilovescomputers/Programming/Projects/semitone`) to fully support **LRC+ v2** as specified.

## Context

- LRC+ is a standalone open format; Semitone is a reference consumer, not owner.
- v1 spec: `LRCPLUS_SPEC.md:1` — extracted from `src/lyrics/parser.vala:185`, `src/lyrics/parser.vala:607`, `src/lyrics/parser.vala:669`, `src/lyrics/models.vala:39`. Strict superset of LRC with word timings on a separate line and generic `{v1}` voice tag.
- v2 brainstorm: `LRCPLUS_V2_BRAINSTORM.md:1` — now decisions locked (see `LRCPLUS_V2_BRAINSTORM.md:220`).
- v2 normative spec: `LRCPLUS_SPEC_V2.md:1` (draft 2026-08-27).

### Decisions locked (must not be re-asked)

- **Block grammar:** Yes, use KV `{key:value|key:value}` with comma-lists. Keys: `voice`, `style`, `effect`, `lang`. Unknown keys/values skipped.
- **Word timing:** Variant A absolute — inline `<mm:ss.xx:mm:ss.xx>Word` on a **separate** timing line (so plain LRC readers skip it). Per-word `{style:...,effect:...}` allowed after its timing. Absolute timestamps, not floats. Run of words until next `<` or EOL.
- **Styling key:** `style` (not `format`): `style:bold,underline`. Comma-list.
- **Legacy isolation:** Strict, enforce — `attr-block` `{…}` **MUST ONLY** appear on blocks that have a following timing line. Plain `[mm:ss.xx]Text` must have zero `{…}`. Parser must strip/clear attrs if no timing line (lint as error).
- **Voice alias:** Keep `{v1}` shorthand as alias for `{voice:v1}`. Parser accepts both: if inner contains `:` or `|` treat as KV block, else legacy voice.

## Current prototype (already land­ed, must be polished)

A prototype is already in `src/lyrics/models.vala:3` and `src/lyrics/parser.vala:253`:

- `LyricWord` now `text, start_sec, end_sec, style, effect` (`src/lyrics/models.vala:3`)
- `LyricLine` now `time_ms, text, words[], voice_role, style, effect, lang` (`src/lyrics/models.vala:11`)
- New helpers: `parse_attr_block()`, `parse_lrc_plus_header_attrs()`, `looks_like_v2_timing_line()`, `parse_word_timings_v2()` (`src/lyrics/parser.vala:253`), `build_header_attr_block()`, `format_ms_as_timestamp()`, `serialize_to_lrc_plus()` now emits v2 inline (`src/lyrics/parser.vala:913`), plus compat `serialize_to_lrc_plus_v1()` (`src/lyrics/parser.vala:953`)
- `parse_lrc_plus()` now branches v2-first then v1 fallback (`src/lyrics/parser.vala:363`) and enforces strict isolation.
- `detect_lyrics_format()` updated for v2 detection (`src/lyrics/parser.vala:43`)
- `parse_extended_lrc`, `parse_lrc`, `parse_plain`, `parse_ttml_*` updated for new struct fields.

Build currently passes: `ninja -C build` links `src/semitone`. Test harness at `/tmp/test_lrc_plus.vala` validates round-trip.

## Your job: complete the port

### 1. Parser completeness
- Review `src/lyrics/parser.vala:287` `parse_word_timings_v2`: ensure `end` inference correct (next start or caller-supplied line end), handle single-timestamp case, and per-word attrs robustly. Handle escaped `&lt;` etc.
- Ensure `strip_lrc_metadata()` (`src/lyrics/parser.vala:168`) still correct for v2.
- Ensure `lyrics_build_candidate()` scoring still fair for v2 (word-synced already 50 pts in `src/lyrics/engine.vala:3`).
- Add unit tests for: v1 bulk round-trip, v2 inline with `voice`+`style`+`effect`+`lang`, per-word `{style:}`, strict isolation (`[00:20.00]{voice:v1}Plain` → voice cleared), unknown key skip, colon/pipe inside word text.

### 2. Provider conversions
- `src/lyrics/providers/lyricsplus.vala:61` `convert_richsync_json` currently emits v1 bulk `<word:sec:sec|...>` — port to emit v2 inline `<mm:ss.xx:mm:ss.xx>Word` with correct `voice`+`style` if applicable. Keep timestamps absolute.
- Check `src/lyrics/providers/paxsenix.vala:193`, `betterlyrics`, `simpmusic` etc. if they emit LRC+ style via `serialize_to_lrc_plus`.

### 3. Serialization & cache
- Decide default: new files should be v2; provide flag to emit v1 for compat if needed. Ensure `src/lyrics/lyrics-sheet.vala:803` `serialize_to_lrc_plus` cache write uses v2 and that old cached v1 files still parse (they do via fallback). Bump cache schema or handle transparent read.
- Fix timestamp formatting: currently `format_ms_as_timestamp` truncates to cs (`%02lld`); ensure ms precision not unintentionally lost vs. v1 `%02lld` expectation.

### 4. UI rendering
- `src/lyrics/lyrics-sheet.vala:296` `build_line_markup*` and `src/lyrics/lyrics-sheet.vala:565` style classes: map `LyricLine.style` (`bold,italic,underline,strike`) and `LyricWord.style`/`effect` to Pango markup. Unknown effect → no-op (graceful). `voice:bg` still special small style.
- Ensure per-word style highlights respect new `style`/`effect` (e.g., `style:underline` already used for active word — extend).

### 5. Strict isolation & editor
- Editor dialog `src/lyrics/lyrics-sheet.vala:633` — add lint: warn/error if `{…}` on plain line without timing. Strip attrs on save if violated.
- Ensure detection in `detect_lyrics_format` correctly distinguishes Extended LRC (`[00:00.00]<00:00.00>word`) from v2 LRC+ timing lines (they look similar but Extended has inline after `]` vs. LRC+ has separate line starting with `<`).

### 6. Docs & compat
- Update `LRCPLUS_SPEC.md:1` header to note v1 frozen; ensure `LRCPLUS_SPEC_V2.md:1` is canonical for v2.
- Ensure no breakage of existing pure LRC / Extended LRC / TTML paths.

### 7. Verification
- `ninja -C build` must pass with no errors (warnings ok).
- Run `/tmp/test_lrc_plus` (compile via `valac --pkg glib-2.0 --pkg libxml-2.0 --pkg json-glib-1.0 /tmp/test_lrc_plus.vala src/lyrics/models.vala src/lyrics/parser.vala -o /tmp/test_lrc_plus`) and add your own tests.
- Manual test: load the example in `LRCPLUS_SPEC_V2.md:40` and `LRCPLUS_SPEC_V2.md:70` in Semitone’s lyrics sheet, verify fallback to plain LRC in a legacy viewer (hide the `<…>` lines).

## Constraints
- Do not re-ask the five locked decisions; implement them.
- Keep LRC+ independent from Semitone in spec language; code references with `file:line`.
- Maintain backward read compat for v1 files (`<word:sec:sec|...>`).
- Unknown attributes must be silently ignored — not error — to keep “skip anything you don’t understand” guarantee.

Deliver: patched source, passing build, brief notes on what you changed vs. prototype.

