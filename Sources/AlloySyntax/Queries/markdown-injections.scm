; Markdown's fenced code, colored as the language its fence names (```ts, ```python…).
(fenced_code_block
  (info_string (language) @injection.language)
  (code_fence_content) @injection.content)

; Each block's inline text, read by Markdown's inline grammar: emphasis, code spans, links.
((inline) @injection.content
  (#set! injection.language "markdown_inline"))
