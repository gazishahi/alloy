;From nvim-treesitter/nvim-treesitter
(atx_heading
  (inline) @text.title)

(setext_heading
  (paragraph) @text.title)

[
  (atx_h1_marker)
  (atx_h2_marker)
  (atx_h3_marker)
  (atx_h4_marker)
  (atx_h5_marker)
  (atx_h6_marker)
  (setext_h1_underline)
  (setext_h2_underline)
] @punctuation.special

[
  (link_title)
  (indented_code_block)
  (fenced_code_block)
] @text.literal

(fenced_code_block_delimiter) @punctuation.delimiter

(code_fence_content) @none

(link_destination) @text.uri

(link_label) @text.reference

[
  (list_marker_plus)
  (list_marker_minus)
  (list_marker_star)
  (list_marker_dot)
  (list_marker_parenthesis)
  (thematic_break)
] @punctuation.special

[
  (block_continuation)
  (block_quote_marker)
] @punctuation.special

(backslash_escape) @string.escape

; A heading whole (its marker too), by level: prose sets each level at its own size.
(atx_heading (atx_h1_marker)) @text.title.1
(atx_heading (atx_h2_marker)) @text.title.2
(atx_heading (atx_h3_marker)) @text.title.3
(atx_heading (atx_h4_marker)) @text.title.4
(atx_heading (atx_h5_marker)) @text.title.5
(atx_heading (atx_h6_marker)) @text.title.6
(setext_heading (setext_h1_underline)) @text.title.1
(setext_heading (setext_h2_underline)) @text.title.2

; A heading's marker hides away from the caret (live Markdown; the space after it too).
(atx_heading
  [
    (atx_h1_marker)
    (atx_h2_marker)
    (atx_h3_marker)
    (atx_h4_marker)
    (atx_h5_marker)
    (atx_h6_marker)
  ] @conceal)
