; HTML's embedded languages: <script> as JavaScript (TypeScript with lang="ts"), <style> as CSS.
; The first pattern that claims a region wins.

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

((style_element (raw_text) @injection.content)
  (#set! injection.language "css"))
