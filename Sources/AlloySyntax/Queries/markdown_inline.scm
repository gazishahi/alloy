;From tree-sitter-markdown's inline queries (nvim-treesitter's)
(emphasis) @text.emphasis

(strong_emphasis) @text.strong

[
  (code_span)
  (link_title)
] @text.literal

[
  (emphasis_delimiter)
  (code_span_delimiter)
] @punctuation.delimiter

[
  (link_destination)
  (uri_autolink)
] @text.uri

[
  (link_label)
  (link_text)
  (image_description)
] @text.reference

[
  (backslash_escape)
  (hard_line_break)
] @string.escape

(image
  [
    "!"
    "["
    "]"
    "("
    ")"
  ] @punctuation.delimiter)

(inline_link
  [
    "["
    "]"
    "("
    ")"
  ] @punctuation.delimiter)

(shortcut_link
  [
    "["
    "]"
  ] @punctuation.delimiter)

; Markup prose hides away from the caret (live Markdown): emphasis and code delimiters, and a
; link's brackets, URL and title (its text stays).
[
  (emphasis_delimiter)
  (code_span_delimiter)
] @conceal

(inline_link
  [
    "["
    "]"
    "("
    ")"
  ] @conceal)

(inline_link (link_destination) @conceal)
(inline_link (link_title) @conceal)

; TeX math, `$…$` and `$$…$$`: a client can typeset it and draw it in its place.
(latex_block) @markup.math
