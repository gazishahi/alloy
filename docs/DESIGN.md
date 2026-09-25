# Alloy's design

Alloy was designed in Side's editor RFC; this is the public part of it: what Alloy is for, the
decisions, and what measuring it taught.

## Why a new engine

Side's Make stage was built on `NSTextView` (TextKit 1). It worked, but the ceiling showed: big
files (layout is AppKit's to decide, on the main thread), highlighting by regex over the whole
file, and agents that write alongside the person, whose streaming edits, proposals and live
diffs are all a fight with `NSTextStorage` attributes and layout invalidation.

## Decisions

- **Rendering: Metal, with CoreText shaping and a glyph atlas.** Alloy doesn't shape text.
  CoreText does shaping, fallback fonts, emoji, ligatures and bidirectional text correctly;
  Alloy caches its output per line and draws glyphs from an atlas as instanced quads.
- **Storage: a rope.** A persistent balanced tree of ≤ 1 KB chunks; every node caches UTF-8,
  UTF-16 and line counts, so a line or an AppKit range resolves in O(log n) and a copy (an undo
  snapshot, a background parse) is free.
- **Syntax: tree-sitter**, incremental, through SwiftTreeSitter. Big files parse in the
  background; the old tree keeps answering (with positions shifted by `tree.edit`) until the new
  one lands. Lines are colored on demand, querying from the node that holds the line; patterns
  rooted at huge containers (a 40,000-member class body) are rewritten to run from the container's
  children, keeping their precedence (`ContainerPatterns`).
- **Input and accessibility are the system's.** `NSTextInputClient` for IME, dictation, marked
  text and the character palette; the NSAccessibility text-area protocol (value, selection,
  lines, ranges, bounds, character at a point, change notifications) so VoiceOver reads and edits
  it as it does `NSTextView`.
- **Layers.** AlloyCore has no AppKit (testable with `swift test` alone), AlloyRender no views.

## What measuring taught

- **The owner's code decides latency as much as the engine.** Code written for `NSTextView`
  treats `string` as free; on a rope it's a copy of the file. `RopeString` gives such code an
  `NSString` that reads the rope in place. Side's per-key cost halved from that alone.
- **Replacing the whole text shouldn't start over.** `TextBuffer.replaceAll(with:)` diffs the
  UTF-8 bytes chunk by chunk and applies one edit over what differs, snapped to character
  boundaries; layout, colors and selections then update incrementally. An agent's change to one
  function re-lays and re-colors that function (10 ms for a 100,000-line file, ~1 ms for 2,000).
- **An idle ProMotion display slows its display link.** Waiting for the next tick put the first
  frame after a pause 30–100 ms late; from idle, Alloy draws at the end of the run-loop turn and
  leaves pacing to the display link only while things move.
- **Build what's expensive off the main thread, and don't wait for it.** A grammar's queries take
  ~100 ms to build the first time; the text paints first and its colors follow.
- **Draw strings once.** Line numbers measured and drawn as strings every frame cost more than the
  text; shaping each number once (`CTLine`) removed it.
- **Count dropped frames against a control.** A frame that's drawn can still miss its vsync for
  reasons that aren't the app's; Alloy's scroll measurements run beside a control that draws only
  the background, and are judged against it.
