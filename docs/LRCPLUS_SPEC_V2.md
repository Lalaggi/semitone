# LRC+ v2 — Official Specification (Draft, superseded by v3)

> **Superseded by [`LRCPLUS_SPEC_V3.md`](LRCPLUS_SPEC_V3.md).** Kept for history.

**Version:** 2.0-draft (amended 2026-09-22: comma separator, `@[…]` voice table with agent types, syllable encoding, `v1` normalization, bare headers with `{…}` only on timing lines, `[Section]` markers)  
**Replaces:** `LRCPLUS_SPEC.md:1` (v1) for normative purposes; v1 file kept as historical.  
**Status:** Canonical spec incorporating user decisions: KV blocks yes, Variant A absolute timings, `style` key, strict isolation, `{v1}` alias kept — plus Sept 2026 fixes: voice table (no header leak), comma separator, syllable-vs-word encoding (validated against Apple Music TTML via Paxsenix, test song "Defying Gravity"), headers always bare, agent types in badge fallback, section markers.  
**Independence:** Standalone format; Semitone `src/lyrics/parser.vala:185` is reference impl.

Changes from v1: §3 header `attr-block`, §4 inline word timings with per-word attrs, §8 strict isolation now normative, §10 expanded keys.

---

## 1. File Structure (unchanged framing)

```
[metadata]*
(block)*
```

Metadata header per `LRCPLUS_SPEC.md:32` (`[ti:`, `[ar:`, `[al:`, `[offset:`, etc.) must-ignore. The voice table (§2.1) is also file-level metadata.

Block is 1 or 2 physical lines:

```
[mm:ss.xx]Text
[{attrs}]<timing {word-attrs}Word ...>
```

The header is ALWAYS bare `[mm:ss.xx]Text` — no `{…}` block ever — so legacy players print clean lyrics verbatim. All voice/styling tags live on the second (timing) line, which legacy players skip. Second line only if word-synced. Empty lines skipped.

### 1.1 Voice table (file-level, added 2026-09-22)

Pretty voice names are declared **once per file**, never repeated inline:

```
@[v1,"Glinda","Kristin Chenoweth",type=person]
@[v2,"Elphaba","Idina Menzel",type=person]
@[v1000,type=group]
```

Grammar (one separator — `,` — throughout):

```
voice-def  = "@" "[" voice-id ["," name ["," credit] ] ["," type-token] "]"
voice-id   = 1*(ALNUM / "-" / "_")   ; e.g. v1, v2, v1000, bg
name       = token                   ; character / pretty name (Elphaba)
credit     = token                   ; performer (Idina Menzel), optional
type-token = "type=" agent-type      ; TTML agent type, e.g. type=group
agent-type = "person" / "group" / extension
token      = quoted / 1*(%x21-7C except "," / "|" / "]") ; quote with "..." if it
             contains "," / "|" / "]" / spaces; "&quot;" escapes a literal quote
```

- Rationale: any `{…}` on the header line leaks verbatim onto legacy players. The table plus timing-line `{v2}` tags keeps headers bare while preserving full names with one declaration.
- Legacy safety: `@` leads the line, so even dumb `[`-anchored players skip it without trying a timestamp parse. The earlier `[@…]` spelling is accepted on read. Parsers must strip these lines before lyric parsing (same as `[ti:]` etc.).
- `type=` may appear in any token slot (a quoted `"type=X"` stays literal text). It records the TTML agent kind so nameless ids still get a table entry (`@[v1000,type=group]`); ids with nothing known need no declaration.
- Duplicates: last wins. Bare `@[v3]` declares the id with no names.
- Back-compat: the earlier `@[id:Display|"Credit"]` colon/pipe spelling is accepted on read (an unquoted `,` selects the comma form); producers always write commas. A legacy display containing a literal comma must be quoted.
- HTML entities in tokens are decoded on read (`&amp;`, `&lt;`, `&gt;`, `&quot;`, `&apos;`, `&#x27;`); producers encode `&`, `<`, `>` on write.

### 1.2 Section markers (added 2026-09-22)

Song structure (TTML div `songPart`, Paxsenix plain `[Intro]`/`[Verse]`/`[Chorus]` headers) is carried as bare marker lines:

```
[Intro]
[00:00.20]Elphaba
...
[Chorus]
[01:53.50]Defying gravity
```

- A marker is a line matching `[Name]` with no timestamp, where Name is a known section (case-insensitive): Intro, Verse, Chorus, Bridge, Outro, Hook, Refrain, Pre-/Post-Chorus, Interlude, Instrumental, Solo, Breakdown, Buildup, Drop, Prelude, Postlude, Coda, Vamp, Tag, Reprise, Overture, Finale, Prologue, Epilogue, Skit. Parsers fold it into `LyricLine.section` for the lines that follow; it never becomes a lyric line. A timestamped `[00:10.00][Chorus]` stays an ordinary lyric (text `[Chorus]`).
- Legacy safety: `[Chorus]` fails the timestamp parse, so legacy players skip it. Producers emit a marker when the section changes between consecutive timed lines. The renderer intentionally ignores sections.

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

**Bare-header rule (2026-09-22):** Producers MUST write headers as bare `[mm:ss.xx]Text` with NO `attr-block` — legacy players print the header verbatim, so even a short `{v1}` would leak. All line-level attrs (voice, style, effect, lang) are written on the timing line's leading block (§4.1). Consumers MUST still accept a header `attr-block` on read (files written before the move, v1 `{v2}` files); when both header and timing blocks are present, the timing block wins per field.

**Alias rule (Decision: Alias, keep {v1}):** If inner contains `:` or `|` → parse as KV `attr-block`; else treat as `voice` shorthand: `{v2}` ≡ `{voice:v2}` , `{bg}` ≡ `{voice:bg}`. Parser must support both (`src/lyrics/parser.vala:204` extension).

**Emission rule (2026-09-22, anti-leak):** Producers MUST write the short alias only (`{v2}`, `{bg}`, `{v1}`) plus optional non-voice attrs (`{v2|style:bold}`), MUST put that block on the timing line (§4.1) — never on the header — and MUST NOT write `voice:`/`display:` inline. Pretty names live only in the §1.1 table. This keeps the header line byte-clean for legacy players; they skip `<`/`{` timing lines wholesale.

**Strict isolation (Decision: Strict, enforce):** `attr-block` **MUST NOT** appear on a header whose block has no following timing line — and per the bare-header rule it SHOULD NOT appear on any written header at all. That is, plain LRC `[mm:ss.xx]Text` must have zero `{…}`. Producers must enforce; consumers: if seen on read, SHOULD strip it for legacy display but MAY treat as lint error. This guarantees legacy LRC (`LRCPLUS_SPEC.md:8`) shows clean text.

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

**Voice pretty-name:** `voice` is the stable id (`v2`, `v1000`, `bg`) used for deduplication/duet grouping and color hashing. The human label lives in the §1.1 voice table (`@[v2,"Elphaba","Idina Menzel",type=person]`): `display` is the character/pretty name, `credit` the performer, `type` the TTML agent kind. Producers MUST emit the table plus short `{v2}` timing-line tags and MUST NOT emit `{voice:…|display:…}` anywhere — inline long form (`{voice:v2|display:X}`, `{voice:v2,"X"}`, `{display:X}`, wherever it appears) is accepted on read for back-compat only, and when present the timing-line value wins over the header value over the table for that line. Badge renders `display` when present, else the agent-type label (`Group` for `group`; a nameless `person` falls through), else the `voice` id.

**Default voice (`v1`) normalization:** `{v1}`, `{voice:v1}` and untagged timed lines are one voice — the default — canonicalized to the empty role on parse (matching the TTML importer, which maps agent `v1` to default). Untagged timed lines inherit the `@[v1:…]` table entry. On write, default-voice lines that carry a display/credit use the explicit `{v1}` alias on the timing line; default lines without names have a block-less timing line.

---

## 4. Word-Timing Line — v2 Variant A Absolute (Decision, separator amended 2026-09-22)

### 4.1 Grammar

```
timing-line  = ["{" line-attrs "}"] 1*( [WS] "<" timestamp [sep timestamp] ">" [WS] [word-attr-block] word-text )
line-attrs   = attr *("|" attr)      ; line voice/style, e.g. v2 or v2|style:bold
sep          = ","                        ; canonical; "|" and legacy ":" accepted on read
word-attr-block = "{" attr *("|" attr) "}"   ; same attr grammar, per-word
timestamp    = minutes ":" seconds "." fraction ; absolute track time, same as header
word-text    = 1*(%x00-10FFFF except "<" / LF) trimmed ; up to next "<" or EOL
```

- Only the FIRST `{…}` — before the first `<` — is line-level; blocks after a `>` stay per-word. A bare `v2` token inside a mixed block (`{v2|style:bold}`) is the voice shorthand.
- Rationale for `,`: `<00:01.31:00:01.66>` has four colons and reads as one timestamp; `<00:01.31,00:01.66>` unambiguously splits start and end. Readers MUST accept `,` and SHOULD accept `|` and the legacy double-colon form during transition.
- First `timestamp` is `start`; optional second after `sep` is `end`. If `end` omitted → infer as next word's `start`, or line end + 3s fallback per `src/lyrics/parser.vala:298` philosophy.
- Absolute track time, not line-relative — avoids drift.
- Per-word `word-attr-block` optional, appears **after** its timing and **before** its word (e.g. `<00:10.00,00:10.32>{style:bold}Hello`). Unknown keys inside ignored.
- Word text consumes until next `<` or EOL, so `:` and `|` inside word need no escaping — fixes `LRCPLUS_SPEC.md:146` delimiter bug.
- Line must start with `<` (after strip) to be detected as timing line; plain LRC readers skip it.

### 4.1b Syllables vs words (added 2026-09-22)

A timing unit is not always a word: Apple Music TTML splits long notes into syllables as adjacent spans with **no** separating space (`<span>Def</span><span>y</span><span>ing</span> <span>gravity</span>`), and Paxsenix ELRC mirrors it (`An<…>y<…>m<…>ore`). Joining units with spaces would corrupt the plain-LRC line (`[01:53.50]Def y ing gravity`).

Rule (same on TTML import, ELRC import, and LRC+ timing lines): **a space separates words; adjacency glues syllables of the same word.**

- On a timing line, the boundary before each unit comes from whitespace: a trailing space at the end of the previous unit's text (or a leading space after `>`) starts a new word; otherwise the unit is a syllable continuation glued to the previous one with no space.
- Display text (`LyricLine.text`) joins continuations with `""`, words with `" "`: `Def`+`y`+`ing`+`gravity` → `Defying gravity`.
- Serialization preserves the distinction: `<01:53.50,01:53.70>Def<01:53.70,01:54.96>y<01:54.96,01:55.26>ing <01:55.27,01:56.98>gravity`.
- v1 bulk (`<word:s:e|…>`) has no syllable encoding: every entry is a word.
- Renderers highlight per unit but must not insert spaces before continuations.

**Replaces v1 bulk:** `<Hello:10.000:10.320|world:10.330:10.800>` (`src/lyrics/parser.vala:607`) is deprecated. Parsers should accept both during transition by branching: if first `<…>` inner matches `^\d+:\d+\.` → v2; else if contains `word:` and `|` → v1 fallback.

### 4.2 Examples

```
@[v1,"Glinda","Kristin Chenoweth",type=person]
@[v2,"Elphaba","Idina Menzel",type=person]
@[v1000,type=group]
[Verse]
[00:10.00]Hello world
{v1}<00:10.00,00:10.32>Hello <00:10.33,00:10.80>world

[00:12.00]Answer you
{v2}<00:12.00,00:12.40>{style:underline}Answer <00:12.41,00:12.90>you

[00:14.00]ooh ah
{bg}<00:14.00,00:14.50>ooh <00:14.51,00:15.00>ah

[01:53.50]Defying gravity
{v2}<01:53.50,01:53.70>Def<01:53.70,01:54.96>y<01:54.96,01:55.26>ing <01:55.27,01:56.98>gravity

[00:20.00]Plain line - no attrs, safe for legacy
```

A legacy player shows exactly the five header texts and skips the `@[…]`, `[Verse]` and `{…}<…>` lines. Shorthand voice: `{v1}` on the timing line ≡ `{voice:v1}`.

Per-word styling with strict degradation: renderer that doesn't know `effect:shake` shows plain "you".

### 4.3 Escaping

- Literal `<`, `>`, `{`, `}` in word text → encode as `&lt;` `&gt;` `&amp;` (already `decode_html_entities` `src/lyrics/parser.vala:625`) or backslash-escape. Parser that sees `<` not followed by valid `timestamp` treats it as text.
- Keep existing entity set plus `&apos;`.

### 4.4 Voice-per-line

One `voice` per block. Simultaneous duet = duplicate timestamp on separate blocks (`LRCPLUS_V2_BRAINSTORM.md:80`):

```
[00:10.00]Hello
{v1}<00:10.00,00:10.40>Hello
[00:10.00]World
{v2}<00:10.00,00:10.46>World
```

No `voice:v1,v2` nor mid-line voice switch.

---

## 5. Detection

`src/lyrics/parser.vala:43` `detect_lyrics_format`:

- `<` + `:` + `|` + no `mm:ss` pattern → `LRC_PLUS` v1.
- `<mm:ss.` pattern → `LRC_PLUS` v2.
Both route to `parse_lrc_plus` with v2-first branch. Timing lines may lead with a `{…}` voice/style block (`{v2}<mm:ss…>`); detection runs on the units part after it.

Extended-LRC inline timings may carry a voice prefix (`[01:07.51]v2: <01:07.51>An…`, Paxsenix `elrcMultiPerson`): detection strips an optional `id:` prefix before checking the `<mm:ss.xx>` inside `<>`. (Previously only a <4-char prefix was allowed, so `v1:`/`v2:`-prefixed lines misdetected as plain LRC.)

---

## 6. Conformance Summary (incorporating decisions + 2026-09-22 amendments)

- Headers: always bare `[mm:ss.xx]Text` on write; `{…}` only on timing lines.
- KV blocks: yes (`{k:v|k:v}`, comma-list values) — accepted on read; producers emit KV only for non-voice attrs (`style`, `effect`, `lang`).
- Voice names: `@[id,"name","credit",type=kind]` table, one `,` separator (§1.1); short `{id}` tags on timing lines; never `{voice:…|display:…}` on write.
- Voice badge fallback: pretty name → agent-type label (`Group`) → coded id.
- Sections: bare `[Chorus]` markers (§1.2), never rendered, round-trip via `LyricLine.section`.
- Word timings: Variant A absolute `mm:ss.xx`, canonical `<start,end>` comma separator (`|` and legacy `:` accepted on read).
- Syllables: space separates words, adjacency glues (§4.1b).
- Styling key is `style` (not `format`).
- Strict isolation: no `{…}` without timing line — normative.
- Voice alias: `{v1}` shorthand preserved; `v1` ≡ default voice, normalized on parse.
- Numeric hygiene: double→ms conversions round (never truncate) so serialize→parse is idempotent; producers encode `&`/`<`/`>` as entities.

---

## 7. References

- v1 spec: `LRCPLUS_SPEC.md:1`
- Brainstorm: `LRCPLUS_V2_BRAINSTORM.md:1`
- Implementation points: `src/lyrics/parser.vala:185`, `src/lyrics/parser.vala:607`, `src/lyrics/parser.vala:633`, `src/lyrics/lyrics-sheet.vala:367`, `src/lyrics/lyrics-sheet.vala:565`

