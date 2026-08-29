# LRC+ v2 — Official Specification (Draft)

**Version:** 2.0-draft (decisions locked 2026-08-27)  
**Replaces:** `LRCPLUS_SPEC.md:1` (v1) for normative purposes; v1 file kept as historical.  
**Status:** Canonical spec incorporating user decisions: KV blocks yes, Variant A absolute timings, `style` key, strict isolation, `{v1}` alias kept.  
**Independence:** Standalone format; Semitone `src/lyrics/parser.vala:185` is reference impl.

Changes from v1: §3 header `attr-block`, §4 inline word timings with per-word attrs, §8 strict isolation now normative, §10 expanded keys.

---

## 1. File Structure (unchanged framing)

```
[metadata]*
(block)*
```

Metadata header per `LRCPLUS_SPEC.md:32` (`[ti:`, `[ar:`, `[al:`, `[offset:`, etc.) must-ignore.

Block is 1 or 2 physical lines:

```
[mm:ss.xx]{attrs}Text
<timing {word-attrs}Word ...>
```

Second line only if word-synced. Empty lines skipped.

---

## 2. Header Line — v2

```
header-line = "[" timestamp "]" [attr-block] text
timestamp   = minutes ":" seconds "." fraction  ; per src/lyrics/parser.vala:633, 1-3 frac digits
attr-block  = "{" attr *("|" attr) "}" / "{" legacy-voice "}"
attr        = key [":" value]
key         = ALPHA *(ALPHA/DIGIT/"-"/"_")   ; case-insensitive, canonical lower
value       = value-token *("," value-token)
value-token = 1*(%x21-7C except "|" / "}" / "," / "<" / ">") ; no pipes/commas/braces
legacy-voice= 1*(%x20-7C except "}" / ":" / "|") ; v1 compat like v1, v2, bg
text        = *(%x00-10FFFF except LF)
```

**Alias rule (Decision: Alias, keep {v1}):** If inner contains `:` or `|` → parse as KV `attr-block`; else treat as `voice` shorthand: `{v2}` ≡ `{voice:v2}` , `{bg}` ≡ `{voice:bg}`. Parser must support both (`src/lyrics/parser.vala:204` extension).

**Strict isolation (Decision: Strict, enforce):** `attr-block` **MUST NOT** appear on a header whose block has no following timing line. That is, plain LRC `[mm:ss.xx]Text` must have zero `{…}`. Producers must enforce; consumers: if seen, SHOULD strip it for legacy display but MAY treat as lint error. This guarantees legacy LRC (`LRCPLUS_SPEC.md:8`) shows clean text.

**Unknown handling:** Unknown `key` → ignore that `attr` entirely; unknown `value-token` within known key → ignore that token only. Empty `attr-block` `{}` → no attrs.

**Duplicated key:** last wins.

---

## 3. Keys — Decision: `style` not `format`

Canonical keys (lowercase):

| Key | Value examples | Semantics | Degradation |
|---|---|---|---|
| `voice` | `v1`, `v2`, `bg`, `lead` | Singer/part. `bg` renders smaller per `src/lyrics/lyrics-sheet.vala:565`. | Unknown voice → treat as `v1`/default |
| `display` | `Glinda`, `"Elphaba"` (also `name`, `label` aliases; comma shorthand `voice:v2,"Glinda"`) | Pretty display name for `voice` id. TTML `ttm:agent` `ttm:name` maps here. | Unknown → ignored, badge falls back to `voice` id |
| `style` | `bold`, `italic`, `underline`, `strike` (comma-list) | Inline style advisory. Example: `style:bold,underline`. | Unknown token → ignore token |
| `effect` | `shake`, `wobble`, `glow` | Animation; purely advisory. | Unknown → no effect |
| `color` | `#RRGGBB`, `red` | Text color. | Unknown → ignore |
| `lang` | `en`, `ja`, `romanized` | Language/track tag. | Ignore if not handling i18n |

All other keys are extension — must be skipped. This satisfies "skip ANYTHING they don't understand and still work as plain LRC".

**Voice pretty-name:** `voice` is the stable id (`v2`, `v1000`, `bg`) used for deduplication/duet grouping and color hashing. `display` (aliases `name`, `label`) is the human label (`Elphaba`, `Glinda`). Serialized as `{voice:v2|display:Glinda}` or shorthand `{voice:v2,"Glinda"}` (comma + optional quotes). Parser accepts both (`src/lyrics/parser.vala:215`): `voice:v2,Glinda` or `voice:v2,"Glinda"` or `display:Glinda`. TTML importer extracts `head/metadata/ttm:agent` `xml:id` → `voice` and child `ttm:name` → `display`. Badge renders `display` when present, falling back to `voice` id.

---

## 4. Word-Timing Line — v2 Variant A Absolute (Decision)

### 4.1 Grammar

```
timing-line  = 1*( [WS] "<" timestamp [":" timestamp] ">" [WS] [word-attr-block] word-text )
word-attr-block = "{" attr *("|" attr) "}"   ; same attr grammar as header
timestamp    = minutes ":" seconds "." fraction ; absolute track time, same as header
word-text    = 1*(%x00-10FFFF except "<" / LF) trimmed ; up to next "<" or EOL
```

- First `timestamp` is `start`; optional second after `:` is `end`. If `end` omitted → infer as next word's `start`, or line end + 3s fallback per `src/lyrics/parser.vala:298` philosophy.
- Absolute track time, not line-relative — avoids drift.
- Per-word `word-attr-block` optional, appears **after** its timing and **before** its word (e.g. `<00:10.00:00:10.32>{style:bold}Hello`). Unknown keys inside ignored.
- Word text consumes until next `<` or EOL, so `:` and `|` inside word need no escaping — fixes `LRCPLUS_SPEC.md:146` delimiter bug.
- Line must start with `<` (after strip) to be detected as timing line; plain LRC readers skip it.

**Replaces v1 bulk:** `<Hello:10.000:10.320|world:10.330:10.800>` (`src/lyrics/parser.vala:607`) is deprecated. Parsers should accept both during transition by branching: if first `<…>` inner matches `^\d+:\d+\.` → v2; else if contains `word:` and `|` → v1 fallback.

### 4.2 Examples

```
[00:10.00]{voice:v1|style:bold}Hello world
<00:10.00:00:10.32>Hello <00:10.33:00:10.80>world

[00:12.00]{voice:v2|effect:shake}Answer you
<00:12.00:00:12.40>{style:underline}Answer <00:12.41:00:12.90>you

[00:14.00]{voice:bg|style:italic}ooh ah
<00:14.00:00:14.50>ooh <00:14.51:00:15.00>ah

[00:20.00]Plain line - no attrs, safe for legacy
```

Shorthand voice: `[00:10.00]{v1}Hello world` identical to `{voice:v1}`.

Per-word styling with strict degradation: renderer that doesn't know `effect:shake` shows plain "you".

### 4.3 Escaping

- Literal `<`, `>`, `{`, `}` in word text → encode as `&lt;` `&gt;` `&amp;` (already `decode_html_entities` `src/lyrics/parser.vala:625`) or backslash-escape. Parser that sees `<` not followed by valid `timestamp` treats it as text.
- Keep existing entity set plus `&apos;`.

### 4.4 Voice-per-line

One `voice` per block. Simultaneous duet = duplicate timestamp on separate blocks (`LRCPLUS_V2_BRAINSTORM.md:80`):

```
[00:10.00]{v1}Hello
<00:10.00:00:10.40>Hello
[00:10.00]{v2}World
<00:10.00:00:10.46>World
```

No `voice:v1,v2` nor mid-line voice switch.

---

## 5. Detection

Update `src/lyrics/parser.vala:43` `detect_lyrics_format`:

- `<` + `:` + `|` + no `mm:ss` pattern → `LRC_PLUS` v1.
- `<mm:ss.` pattern → `LRC_PLUS` v2.
Both route to `parse_lrc_plus` with v2-first branch.

---

## 6. Conformance Summary (incorporating decisions)

- KV blocks: yes (`{k:v|k:v}`, comma-list values).
- Word timings: Variant A absolute `mm:ss.xx`.
- Styling key is `style` (not `format`).
- Strict isolation: no `{…}` without timing line — normative.
- Voice alias: `{v1}` shorthand preserved.

---

## 7. References

- v1 spec: `LRCPLUS_SPEC.md:1`
- Brainstorm: `LRCPLUS_V2_BRAINSTORM.md:1`
- Implementation points: `src/lyrics/parser.vala:185`, `src/lyrics/parser.vala:607`, `src/lyrics/parser.vala:633`, `src/lyrics/lyrics-sheet.vala:367`, `src/lyrics/lyrics-sheet.vala:565`

