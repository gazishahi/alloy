; Svelte's embedded languages: <script> as JavaScript (TypeScript with lang="ts"), <style> as
; CSS (SCSS with lang="scss"), and the {expressions} in markup as JavaScript. After
; tree-sitter-svelte's own injections (MIT). The first pattern that claims a region wins.

((script_element
  (start_tag
    (attribute
      (attribute_name) @_attr
      (quoted_attribute_value (attribute_value) @_lang)))
  (raw_text) @injection.content)
  (#eq? @_attr "lang")
  (#any-of? @_lang "ts" "typescript")
  (#set! injection.language "typescript"))

((script_element (raw_text) @injection.content)
  (#set! injection.language "javascript"))

((style_element
  (start_tag
    (attribute
      (attribute_name) @_attr
      (quoted_attribute_value (attribute_value) @_lang)))
  (raw_text) @injection.content)
  (#eq? @_attr "lang")
  (#any-of? @_lang "scss" "postcss")
  (#set! injection.language "scss"))

((style_element (raw_text) @injection.content)
  (#set! injection.language "css"))

; Expressions in markup ({count + 1}) and block conditions ({#if count > 0}).
((svelte_raw_text) @injection.content
  (#set! injection.language "javascript"))
