# LRC+ v3 — Lyric Format Specification

**Version:** 3.0  
**Status:** Normative. This document is self-contained: an implementer with no
prior knowledge of LRC+ should be able to write a conforming reader and
writer from it alone.  
**Supersedes:** LRC+ v1 (`LRCPLUS_SPEC.md`) and v2 (`LRCPLUS_SPEC_V2.md`),
which remain as historical records of the bulk-timing and header-tag eras.  
**Maintainer:** LRC+ is a standalone open format. Semitone
(`gitlab.com/Lalaggi/semitone`) ships a reference implementation
(`src/lyrics/parser.vala`) but does not own the format.  
**Encoding:** UTF-8. **Line ending:** `LF` (`\n`). Readers MUST tolerate `CRLF`.  
**Informal identifier:** `lrc+`. There is no in-file version marker; a file is
LRC+ v3 if it follows this specification (see §11 for detection guidance and
Annex B for what readers MUST additionally accept from earlier versions).

---

## 0. Conformance keywords and definitions

The key words **MUST**, **MUST NOT**, **REQUIRED**, **SHALL**, **SHALL NOT**,
**SHOULD**, **SHOULD NOT**, **RECOMMENDED**, **MAY**, and **OPTIONAL** are to be
interpreted as described in RFC 2119.

- **Legacy player**: any program that understands classic line-synced LRC
  (`[mm:ss.xx]Text` per line) and ignores lines it cannot parse. The core
  guarantee of LRC+ is that a legacy player fed a v3 file shows correct,
  clean line-synced lyrics (§9).
- **Block**: one lyric — a header line plus its optional timing line (§4).
- **Strip**: remove leading and trailing whitespace (space, horizontal tab,
  carriage return, line feed). Readers MUST strip every physical line before
  classifying it.
- **ABNF**: grammars below use RFC 5234 notation (`*`, `1*`, `[]`, `/`,
  literals in quotes, `ALPHA`/`DIGIT`). `SP` is U+0020.

---

## 1. Design goals

1. **Strict superset of LRC.** Deleting every line that is not a bare
   `[timestamp]Text` header MUST leave a valid, correctly synced LRC file.
2. **Word-level timing** with explicit per-unit start and end times.
3. **Voices** (duets, groups, background parts) without ever polluting the
   header text legacy players display.
4. **Syllable fidelity.** Long notes are often split into syllables with
   individual timings; the format MUST distinguish syllables of one word from
   separate words so plain-text rendering never shows `Def y ing`.
5. **Graceful degradation.** Unknown attributes, voices, sections, and effects
   MUST be droppable without breaking playback.
6. **Human-editable.** Plain text, one block per lyric, visible timestamps.

---

## 2. Document structure

```
document    = *(metadata-line / voice-def-line / section-line / block / blank)
block       = header-line [timing-line]
```

- A document is a sequence of physical lines in any order, though writers
  SHOULD emit file metadata first, then the voice table (§5), then blocks in
  ascending time order.
- `blank` (empty or whitespace-only) lines MUST be skipped everywhere: they
  carry no data and never become lyrics.
- The **timing line** of a block MUST be the physically adjacent next line
  after its header. A blank line (or any other line) between them means the
  header has no timing line.
- A file with zero timing lines is not an LRC+ file; it is plain LRC
  (Annex C). Writers SHOULD NOT produce v3 files without at least one
  word-timed block.
- Readers MUST preserve document order. Readers MUST NOT require ascending
  timestamps, but writers SHOULD emit blocks in ascending time order.
  Simultaneous parts (duets) are represented as separate blocks sharing a
  timestamp (§10).

---

## 3. Timestamps

```
timestamp   = minutes ":" seconds "." fraction
minutes     = 1*DIGIT          ; no upper bound; usually 00–99
seconds     = 1*DIGIT          ; usually two digits, value SHOULD be 00–59
fraction    = 1*3DIGIT         ; centisecond to millisecond precision
```

- Value in milliseconds: `minutes*60000 + seconds*1000 + scaled`,
  where `scaled` is the fraction scaled to milliseconds: 1 digit ×100,
  2 digits ×10, 3 digits ×1 (`00:01.3` = 1300 ms, `00:01.31` = 1310 ms,
  `00:01.318` = 1318 ms).
- Writers MUST emit exactly two fraction digits (centiseconds), zero-padded
  two-digit minutes and seconds: `[%02d:%02d.%02d]`. Sub-centisecond
  precision is intentionally lost on write (10 ms granularity); readers
  accept 1–3 digits so written files round-trip.
- A timestamp is **malformed** if it does not have the shape above (exactly
  one `:` separating minutes from `seconds.fraction`, exactly one `.`, 1–3
  fraction characters). Readers MUST skip lines whose timestamp is malformed.
  Segments SHOULD consist of ASCII digits; writers MUST emit digits only.
  (Reference behavior: segments are parsed with a non-validating integer
  parse, so non-digit content inside a well-formed shape yields 0 rather than
  an error. Conforming readers MAY validate strictly instead.)
- Readers MUST skip lines whose timestamp resolves to a negative time.
  Seconds values ≥ 60 are NOT an error (they fold into the total normally).

---

## 4. Blocks

### 4.1 Header line

```
header-line = "[" timestamp "]" text
text        = *(VCHAR / SP / %x80-10FFFF)   ; anything except LF; MAY be empty
```

- The header carries the line's start time and its plain-text lyric.
  **Writers MUST NOT put any `{…}` block on a header line, ever.** This is
  the load-bearing rule behind the legacy guarantee: legacy players print
  header text verbatim.
- If a header contains more than one `[...]` group
  (e.g. `[00:10.00][00:12.00]Text`), readers MUST use the **first** group's
  content as the timestamp and treat the remainder (including further
  brackets) as literal text. Writers MUST NOT emit repeated timestamps;
  repeat the whole block instead (see §10).
- After extracting the timestamp, readers MUST decode HTML entities in the
  text (§8).
- Historical files may contain a `{…}` attribute block between `]` and text
  (v1/v2 style: `[00:10.00]{v2}Text`). Readers MUST still accept this (see
  Annex B) but MUST strip the block from the display text, and the
  timing-line block (§4.2), when present, wins over it per field. Writers
  MUST NOT emit header blocks.

### 4.2 Timing line

```
timing-line = [line-block] 1*(unit)
line-block  = "{" line-attrs "}"
line-attrs  = attr *("|" attr)
unit        = "<" tspec ">" [word-block] word-text
tspec       = timestamp ["," timestamp]      ; canonical: start[,end]
word-block  = "{" word-attrs "}"
word-attrs  = attr *("|" attr)
word-text   = *(VCHAR / SP / %x80-10FFFF)    ; runs to next "<" or end of line
```

- A timing line is recognized as follows: strip the line; if it starts with
  `<`, the whole line is units. Else, if it starts with `{`, find the first
  `}`; if the remainder after it (stripped) starts with `<`, the `{…}` is
  the **line block** and the remainder is units. Otherwise the line is not a
  timing line. Only the FIRST `{…}` — before the first `<` — is line-level;
  every `{…}` after a `>` belongs to the word it precedes.
- The line block carries the block's voice and line styling
  (e.g. `{v2}`, `{v1|style:bold}`). Attribute grammar is §6; the voice rules
  are §7. A `{…}` is a word block only when it appears immediately after the
  timestamp (whitespace around it is allowed); a `{…}` anywhere else in the
  word text is literal text. Per-word blocks carry only `style`/`effect`
  (a `voice`, display name, or `lang` inside a word block MUST be parsed and
  then dropped: voice is per line only).
- `tspec` is a start timestamp with an optional end timestamp separated by
  `,`. Writers MUST use `,`; readers MUST also accept the legacy separators
  `|` and `:` (Annex B) so that `<00:01.31:00:01.66>` and
  `<00:01.31|00:01.66>` keep working. A lone `<mm:ss.xx>` (start only) is
  valid; its end is inferred (§4.4).
- Word text runs from the end of `>` (and any word block) up to the next
  `<` or end of line, then is stripped and entity-decoded. A unit whose text
  is empty after stripping, or whose start timestamp is malformed, MUST be
  skipped without affecting the word-boundary state machine (§4.3).
- Stray text that is not inside a unit (e.g. an unencoded960 `<` in lyrics)
  MUST be skipped up to the next `<`. Writers MUST encode literal `<`, `>`,
  and `&` in word text as `&lt;`, `&gt;`, `&amp;` (§8), so conforming files
  never trigger this rule.
- A timing line MUST be consumed (not treated as a later header) whenever it
  is timing-shaped, even if zero units survive parsing. A timing-shaped line
  with no preceding header (orphan) MUST be skipped. A block whose timing
  line yields zero units is treated exactly like a block with no timing line
  (line-synced only, all attributes cleared — §7.4).

### 4.3 Word vs syllable units

Each parsed unit is either a **new word** or a **syllable continuation** of
the previous unit. Display text joins continuations with no space and words
with one space, so `Def`+`y`+`ing`+`gravity` renders `Defying gravity`,
never `Def y ing gravity`. Renderers MUST NOT insert a space before a
continuation unit (highlighting is still tracked per unit).

Readers MUST compute the boundary with this state machine (whitespace
around structural tokens is skipped and never starts a word by itself):

```
new_word_expected := true
for each unit in document order:
    skip whitespace; read "<" tspec ">"
    skip whitespace; optionally read "{" word-block "}"; skip whitespace
    raw  := text up to the next "<" or end of line
    text := strip(raw), entity-decoded
    if text is empty or start timestamp is malformed:
        skip unit, leave new_word_expected unchanged
    else:
        word_start := new_word_expected
        new_word_expected := raw ends with whitespace
```

In particular: the first unit of a line always starts a word;
`…ing <…>gravity` (trailing space) starts a new word;
`…Def<…>y<…>ing` (adjacency) glues syllables. This mirrors the source
encodings (TTML sibling spans, ELRC inline tags) where a space separates
words and adjacency means same word (Annex A).

### 4.4 End-time inference

Every unit SHOULD carry an explicit end, but readers MUST repair missing or
impossible ends deterministically:

```
for each unit i in document order:
    fix := end missing
        OR end <= start
        OR (i is not last AND end is explicit AND end > start of unit i+1)
    if fix:
        end[i] := start of unit i+1, if there is a next unit
        else   := the next block's header time, if known
        else   := start[i] + 0.30 s
```

Explicit ends that lie within `(start, next start]` are kept verbatim.

### 4.5 Deprecated v1 bulk form (read-only)

Earlier files use one line per block shaped
`<text:start:end|text:start:end|…>`, where start/end are decimal seconds
(`10.320`, locale-invariant `.`). Readers MUST continue to accept it:
strip one outer `<…>` pair, split on `|`, split each entry on `:` and use
the **first three segments only** (text, start, end; further segments are
ignored); entries with fewer than three segments are skipped; text is
entity-decoded. Every surviving entry is a **word** (this form has no
syllable encoding). No end inference is applied. Writers MUST NOT emit this
form. Word text MUST NOT contain `:` or `|` in this form (an ambiguity the
v3 unit syntax was designed to remove).

---

## 5. Voice table

Voice names are declared **once per file**, never repeated inline:

```
@[v1,"Glinda","Kristin Chenoweth",type=person]
@[v2,"Elphaba","Idina Menzel",type=person]
@[v1000,type=group]
```

Grammar (exactly one field separator — `,` — plus the `type=` key):

```
voice-def  = "@" "[" voice-id ["," name ["," credit]] ["," type-token] "]"
voice-id   = 1*(ALNUM / "-" / "_")      ; e.g. v1, v2, v1000, bg; case-sensitive
name       = token                      ; pretty/character name; omit if none
credit     = token                      ; performer; omit if none
type-token = "type=" agent-type
agent-type = "person" / "group" / 1*(ALNUM / "-" / "_")   ; stored lowercased
token      = quoted / *(%x21-2B / %x2D-3B / %x3D / %x3F-5B / %x5D-10FFFF)
                                    ; any text without raw "," "|" "]"
quoted     = %x22 *(%x20-21 / %x23-10FFFF) %x22   ; "..." (or '...' on read)
```

- `@` leads the line, so even naive `[`-anchored legacy players skip it
  without attempting a timestamp parse.
- A token MUST be quoted if it contains `,`, `|`, `]`, `"`, or whitespace;
  a literal `"` inside quotes is written `&quot;` (decoded on read, §8).
- An **empty slot is preserved only when a later slot is filled**:
  `@[v1,,"Credit",type=person]` (credit, no name); `@[v1000,type=group]`
  (type only, no empty slots). `@[v3]` declares an id with nothing known.
- A `type=` token is recognized in any slot provided it is **unquoted** (a
  quoted `"type=Singer"` stays literal name text). Only the first `type=`
  token counts.
- Duplicate ids: last definition wins. Ids with nothing known need no
  declaration at all. Entries with an empty id, or an id containing
  characters outside `ALNUM`/`-`/`_`, MUST be skipped.
- Back-compat (readers MUST accept): the earlier `@[id:Name|"Credit"]`
  colon/pipe spelling and the `[@…]` line spelling. Rule: the id runs up to
  the first `:` or `,`; if the remainder contains an **unquoted** `,`, split
  fields on unquoted commas, else split on unquoted pipes. (Consequence:
  a legacy name containing a literal comma MUST be quoted to survive.)
- These lines are file metadata: readers MUST strip them before lyric
  parsing (like §3 metadata), MUST scan the whole file for them, and MUST
  never surface them as lyrics.

---

## 6. Attribute blocks (`{…}`)

```
attr-block = "{" attr *("|" attr) "}" / "{" legacy-voice "}"
attr       = key [":" value]
key        = ALPHA *(ALPHA / DIGIT / "-" / "_")   ; case-insensitive
value      = value-token *("," value-token)
legacy-voice = 1*(%x20-7C except "}" / ":" / "|")
```

Parsing a block, readers MUST:

1. If the inner text is empty → no attributes.
2. Else if it contains neither `:` nor `|` → legacy alias: the whole inner
   text (unquoted) is the voice id (`{v2}` ≡ `{voice:v2}`, `{bg}` ≡
   `{voice:bg}`).
3. Else split on `|`; split each piece on the FIRST `:` into key (stripped,
   lowercased) and value (stripped):
   - `voice`: the id; a comma suffix is an inline display name
     (`voice:v2,Glinda`), kept for back-compat only.
   - `display` (aliases `name`, `label`, `agent-name`): the display name
     (entity-decoded, unquoted). Back-compat only; writers use §5.
   - `style`: comma-separated list filtered to `bold`, `italic`,
     `underline`, `strike`; unknown tokens are dropped, not errors.
     Repeated `style` keys merge with `,`.
   - `effect`, `lang`: stored verbatim (advisory; renderers ignore unknown
     values).
   - Any other key (including `color`): the attribute MUST be ignored
     entirely.
   - A piece with no value (no `:`): if no voice has been set yet, and the
     token (unquoted) is a valid voice id, and it is NOT one of the known
     key names (`voice`, `display`, `name`, `label`, `agent-name`, `style`,
     `effect`, `lang`, `color`), it is the voice shorthand — this is what
     makes `{v2|style:bold}` work. Otherwise it is ignored.
4. A block with no closing `}` is literal text, not a block.

The literal `v1` as a voice id normalizes to the **default voice**
(empty id) wherever a voice is read (Annex B): `{v1}`, `{voice:v1}`, and an
untagged timed line are one and the same voice.

---

## 7. Voices

- A **voice id** (`v2`, `v1000`, `bg`, …) identifies who sings a block. One
  voice per block; there is no mid-line voice switch and no multi-voice
  value. Simultaneous parts are separate blocks sharing a timestamp (§10).
- `v1` is the **default voice** and is stored as the empty id. `bg`
  designates background vocals (renderers typically de-emphasize it).
- Resolution order for a timed block's voice data (first hit wins per
  field): timing-line block (§4.2) → legacy header block (Annex B) → voice
  table (§5) → default. Untagged timed lines inherit the table's `v1`
  entry — this is what lets `@[v1,…]` round-trip through tagless files.
  Blocks with no timing line carry no voice data at all (§7.4).
- Writers emit the short alias only (`{v2}`, `{bg}`, `{v1}`), plus
  non-voice attributes when present (`{v2|style:bold}`), and MUST NOT write
  `voice:`/`display:` inline. The default voice is written with the explicit
  `{v1}` alias **only** when the line carries a display name, credit, or
  type worth declaring; otherwise its timing line has no block at all.
- Recommended badge fallback (informative): display name → agent-type
  label (`Group` for `group`; a nameless `person` falls through) → uppercased
  id (`V1000`) → nothing. `bg` SHOULD badge as `Background` unless it has a
  display name.

### 7.4 Strict isolation (normative)

Attribute data MUST NOT exist on a block with no timing line. Concretely:
writers MUST NOT emit any `{…}` unless the block has a timing line, and
readers MUST clear all voice/style/effect/lang data parsed from a header
whose timing line is absent or yields zero units (the stripped text itself
is kept). This is what keeps pure line-synced files byte-clean.

---

## 8. Text and entities

- Readers MUST decode, in this single-pass order:
  `&#x27;` → `'`, `&apos;` → `'`, `&quot;` → `"`, `&amp;` → `&`,
  `&lt;` → `<`, `&gt;` → `>`. (Decoding `&amp;` after the rest avoids
  double-decoding.) At least this set MUST be supported.
- Writers MUST encode `&`, `<`, `>` as `&amp;`, `&lt;`, `&gt;` in header
  text and word text. A literal `"` inside a quoted voice-table token is
  written `&quot;`.
- Leading/trailing whitespace of header text and word text is not
  significant (strip on read).

---

## 9. Legacy guarantee (normative)

A v3 file MUST degrade as follows in players that only understand classic
LRC:

1. Metadata (`[ti:]` etc.), voice-table (`@[…]`) lines, section markers
   (`[Chorus]`), and timing lines (starting with `<` or `{`) contain no
   parseable `[timestamp]` prefix and MUST be skipped.
2. Every remaining line is a bare `[mm:ss.xx]Text` header displaying the
   correct line at the correct time.

Consequences for writers: headers MUST be bare (§4.1); voice/style data
MUST live only on timing lines; the voice table MUST lead with `@`;
sections MUST be bare `[Name]` markers. A legacy player that additionally
strips `\{[^}]*\}` from displayed lines is robust against pre-v3 files, but
v3 files MUST NOT rely on that.

---

## 10. Duets, groups, overlaps

- Two voices singing at once are two blocks with equal (or near-equal)
  timestamps, one leading `{…}` timing-line block each, e.g.:
  ```
  [00:10.00]Hello
  {v1}<00:10.00,00:10.40>Hello
  [00:10.00]World
  {v2}<00:10.00,00:10.46>World
  ```
- Group/choir parts use a normal id (conventionally `v1000`) with
  `type=group` in the table so badges can label them (`Group`) instead of
  showing a bare id.
- Overlapping (non-identical) timestamps are allowed; readers MUST NOT
  require unique or sorted times.

---

## 11. File metadata

The following header lines are file metadata and MUST be ignored for lyric
purposes (stripped before parsing):

```
[offset: ±milliseconds] [ti: title] [ar: artist] [al: album]
[by: author] [length: mm:ss] [re: player/editor] [ve: version]
```

Matching is a case-sensitive prefix check on the stripped line. Notes:

- `[offset:]` is accepted but MUST NOT be applied by readers (offsets belong
  to players, not files); writers SHOULD NOT emit it.
- Unknown `[key: value]` lines that are not valid timestamps, markers (§12),
  or table lines MUST be skipped, never surfaced as lyrics.
- Writers MAY emit `[ti:]`/`[ar:]`/`[al:]` (title/artist/album). The
  reference writer emits only the voice table (§5) plus lyric blocks;
  track metadata, when present, precedes the table.

---

## 12. Sections

Song structure travels as bare marker lines:

```
[Intro]
[00:00.20]Elphaba
…
[Chorus]
[01:53.50]Defying gravity
```

- A marker is a line of the form `[Name]` (stripped, no timestamp) where
  Name, lowercased with spaces/hyphens/underscores removed, is one of:
  `intro verse chorus bridge outro hook refrain prechorus postchorus
  interlude instrumental solo breakdown buildup drop prelude postlude coda
  vamp tag reprise overture finale prologue epilogue skit`.
  Canonical emitted forms: `Intro Verse Chorus Bridge Outro Hook Refrain
  Pre-Chorus Post-Chorus Interlude Instrumental Solo Breakdown Buildup Drop
  Prelude Postlude Coda Vamp Tag Reprise Overture Finale Prologue Epilogue
  Skit`. Anything else in brackets is skipped (never a lyric).
- Markers set context for following blocks until the next marker; they never
  become lyric lines and renderers MUST ignore them. A timestamped
  `[00:10.00][Chorus]` is an ordinary lyric whose text is `[Chorus]`.
- Markers MUST appear between blocks, never between a header and its timing
  line.
- Writers emit a marker immediately before the first timed line whose
  section is non-empty and differs from the last emitted section, and reset
  their tracker on timed lines with empty section.

---

## 13. Data model (for implementers)

A parsed document is an ordered list of lines; each line:

| Field | Type | Meaning |
|---|---|---|
| `time_ms` | integer ms, or "unsynced" | header start time |
| `text` | string | display text (words joined per §4.3) |
| `words` | list, possibly empty | timed units |
| `voice` | string id, `""` = default | singer/part |
| `display` | string, possibly empty | pretty/character name |
| `credit` | string, possibly empty | performer |
| `vtype` | string, possibly empty | agent kind (`person`/`group`/extension) |
| `style` | comma list, possibly empty | subset of `bold,italic,underline,strike` |
| `effect` | string, possibly empty | advisory animation |
| `lang` | string, possibly empty | language tag |
| `section` | string, possibly empty | canonical section name |

Each word: `text`, `start`/`end` (seconds or ms — convert v1-bulk decimal
seconds to ms rounding to nearest), `word_start` (boolean, §4.3),
word-level `style`/`effect`.

---

## 14. Serialization (writer requirements)

1. Skip lines with unsynced/negative times.
2. Emit the voice table first: one entry per distinct **effective** voice id
   (explicit id, else `v1` iff a timed default-voice line carries a display
   name, credit, or type), in order of first appearance, using the first
   line for that id that carries display/credit/type; skip ids with none.
   Entry shape: `@[id]`, `@[id,"name"]`, `@[id,"name","credit"]`,
   `@[id,type=kind]`, freely combined (`@[v2,"Elphaba","Idina Menzel",type=person]`;
   credit without name keeps its slot: `@[v1,,"Credit",type=person]`).
3. In document order per timed line: emit a `[Section]` marker per §12,
   then the bare header (`[mm:ss.cs]` + encoded text), then — iff the line
   has words — the timing line: optional `{id[|style:…][|effect:…][|lang:…]}`
   block (omitted when empty), then `<start,end>` (+ optional per-word
   `{style|effect}`) + encoded word text per unit, joined with a space
   **iff the next unit starts a new word** (§4.3).
4. Encode text per §8. Truncation to centiseconds loses ≤9 ms; because
   readers accept 1–3 fraction digits, a written file MUST re-parse to
   identical timestamps (convert floating-point seconds to integer
   milliseconds by rounding to nearest, never truncating, or the well-known
   `128.45 → 128449` drift breaks idempotence).

---

## 15. Reader requirements (checklist)

- [ ] Strip lines; skip blanks.
- [ ] Strip §11 metadata and §5 table lines (whole-file scan for the table).
- [ ] Fold §12 markers into section context.
- [ ] Parse header timestamp (§3) or skip the line.
- [ ] If the next physical line is timing-shaped, parse leading block +
      units (§4.2–§4.4, Annex B forms); consume it either way.
- [ ] Merge voice attrs timing-over-header; resolve display/credit/type via
      §5 with v1-inherit for untagged *timed* lines; normalize `v1` → default.
- [ ] Enforce strict isolation (§7.4).
- [ ] Decode entities (§8); join words per §4.3.
- [ ] Ignore unknown keys/tokens/voices gracefully (§5, §6).

---

## 16. Worked example

Excerpt (`Wicked`, "Defying Gravity"; performer names double as display
names here as in the Apple Music source):

```
[ti:Defying Gravity]
[ar:Kristin Chenoweth, Idina Menzel]
[al:Wicked (Original Broadway Cast Recording)]
@[v1,"Kristin Chenoweth",type=person]
@[v2,"Idina Menzel",type=person]
@[v1000,type=group]
@[v3,type=person]
[Intro]
[00:00.20]Elphaba
{v1}<00:00.20,00:00.97>Elphaba
[00:01.31]Why couldn't you have stayed calm for once
{v1}<00:01.31,00:01.66>Why <00:01.66,00:01.85>couldn't <00:01.85,00:01.95>you <00:01.95,00:02.05>have <00:02.05,00:02.37>stayed <00:02.37,00:02.69>calm <00:02.69,00:02.80>for <00:02.80,00:03.39>once
[Chorus]
[01:53.50]Defying gravity
{v2}<01:53.50,01:53.70>Def<01:53.70,01:54.96>y<01:54.96,01:55.26>ing <01:55.27,01:56.98>gravity
```

A legacy player displays exactly: `Elphaba`,
`Why couldn't you have stayed calm for once`, `Defying gravity` — at the
right times, with no stray markup. A v3 reader additionally knows who sings
each line (`v1` + performer table, `v2`, group `v1000`), each word/syllable
boundary (`Def|y|ing` glued, `gravity` separate), and the section of every
line (`Intro`, `Chorus`).

---

## Annex A — TTML import mapping (informative)

Most word-timed LRC+ in the wild is converted from Apple Music TTML. To
produce equivalent output, map TTML as follows (element/attribute names are
matched by local name, ignoring the `ttm:`/`itunes:` prefixes):

- **Agents:** each `head/metadata/agent` with `xml:id` (fallback `id`)
  yields a voice id. Record its `type` attribute (lowercased) **always**,
  and its display name when present: `displayName`/`name` attribute first,
  else the first `name` descendant (including one nesting level), stripped.
  Agents without names still yield table entries via `type`
  (`@[v1000,type=group]`).
- **Roles:** a `p` element's `agent` gives the line's voice, except `v1`
  which maps to the default voice (empty id). A non-background `span`
  `agent` overrides the line voice (including back to `v1`/default); the
  last such agent also feeds display/type lookup when the final role has no
  entry. Spans with `role="x-bg"` (including timed spans nested inside an
  `x-bg` wrapper) form a **separate background line** sharing the timestamp,
  with voice `bg` and no type.
- **Sections:** the enclosing `div`'s `songPart` (stripped, verbatim) is the
  line's section.
- **Syllables:** timed sibling `span`s separated by whitespace text nodes
  are separate **words**; directly adjacent spans (`</span><span>`, no
  intervening whitespace) are **syllable continuations** of one word (§4.3).
  The line's display text is the whitespace-aware join, not a naive
  space-join (which would corrupt `Defying` into `Def y ing`).
- **Times:** `begin`/`end` accept `h:mm:ss.mmm`, `mm:ss.mmm`, or bare
  seconds; convert to integer milliseconds, rounding to nearest. A line's
  time is its `p/@begin`; `p` elements without `begin` are skipped in synced
  documents (their text is kept only in fully unsynced documents, with time
  unset). `itunes:key` (`L1`…) and other `itunes:*` attributes are ignored.
- **Parenthesized background splitting** (`(…)` → extra `bg` line) is a
  vendor repair heuristic, NOT part of this format; converters MAY apply
  their own, but MUST NOT require readers to understand it.

---

## Annex B — What readers MUST still accept (legacy read list)

v3 writers never emit these, but the installed base contains them, so
conforming readers MUST parse:

1. **v1 bulk timing lines** (§4.5): `<text:start:end|…>` with decimal-second
   floats; first three `:`-segments only; no syllable encoding; no end
   inference.
2. **Legacy timestamp pairs** inside `<…>`: `start:end` (three colons,
   e.g. `<00:01.31:00:01.66>`) and `start|end` (both sides valid
   timestamps), in addition to canonical `start,end`.
3. **Header attribute blocks** (`[00:10.00]{v2}Text`,
   `[00:10.00]{voice:v2|display:X}Text`): strip from display text; merge
   under timing-line block per §7 (timing wins per field).
4. **Legacy voice-table spellings**: `[@…]` lines and `@[id:Name|"Credit"]`
   colon/pipe bodies (§5 back-compat rule).
5. **Inline shorthands**: `{voice:id,Name}` comma display;
   `display`/`name`/`label`/`agent-name` keys (all mean display name);
   bare `{v2|style:bold}` mixed voice+KV form (bare token = voice unless it
   is a known key name).
6. **ELRC-style voice prefixes on detection only**: `[01:07.51]v2: <…>…`
   lines belong to Extended LRC (inline `<ts>` after the header), a
   different format — but detectors MUST NOT misread them as plain LRC
   (see Annex C).

---

## Annex C — Format detection (informative guidance)

Scan stripped lines (ignoring metadata/table/marker lines):

1. If any line is **timing-shaped** (starts with `<`, or `{…}` followed by
   `<`): examine the units part. If its first `<…>` holds a timestamp or
   timestamp pair starting with a digit → **LRC+**. Else, if it holds
   `word:`-with-pipes shapes (first inner char non-digit) → **LRC+**
   (v1 bulk). Route both to the LRC+ parser, trying v3 units first.
2. Else, if any header is followed (after an optional `id:` voice prefix)
   by inline `<mm:ss.xx>` word tags → **Extended LRC**.
3. Else, if any `[...]` holds a valid timestamp → **LRC**.
4. Else → **plain text** (where `[Chorus]`-style lines are content, not
   markers — markers are only special inside LRC/LRC+ parsing).

---

## Changes from v2 (informative)

- Headers are unconditionally bare; all `{…}` moved to the timing line's
  leading block (v2 allowed header blocks).
- Canonical pair separator `,` (v2 used `:`); `|`/`:` retained as read-only.
- Voice table canonical form `@[id,"name","credit",type=x]` with one `,`
  separator (v2 used `@[id:…|…]`); old spelling still reads.
- Agent `type` recorded and emitted (`@[v1000,type=group]`); badge fallback
  gains the type level.
- `[Section]` markers added; folded into per-line section data.
- `v1` explicitly normalized to the default voice on read.
- End-inference (`next start`, else next header time, else `+0.30 s`) and the
  whitespace word-boundary machine are now specified normatively.

*End of LRC+ v3 specification.*
