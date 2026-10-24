; LaTeX, for Alloy's lean tree-sitter-latex (see alloy_tree_sitter_latex.h): every command but
; an environment's \begin and \end is a generic_command, told apart here by its name. Later
; patterns win, so the broad ones (math, a section's title) come first.

[
  (inline_formula)
  (displayed_equation)
  (math_environment)
] @string

[
  (verbatim_environment verbatim: (_) @text.literal)
  (minted_environment code: (_) @text.literal)
  (listing_environment code: (_) @text.literal)
]

; Sections and titles.
((generic_command
  command: (command_name) @_name
  arg: (curly_group) @text.title)
  (#match? @_name "^\\\\(part|chapter|addchap|section|addsec|subsection|subsubsection|paragraph|subparagraph|title|frametitle)\\*?$"))

; Packages, classes and the files a document takes in.
((generic_command
  command: (command_name) @_name
  arg: (curly_group) @string)
  (#match? @_name "^\\\\(usepackage|RequirePackage|documentclass|LoadClass|input|include|includeonly|includegraphics|includesvg|bibliography|bibliographystyle|addbibresource|import|subimport|inputminted|lstinputlisting|usetikzlibrary)$"))

; Labels, references and citations.
((generic_command
  command: (command_name) @_name
  arg: (curly_group) @text.reference)
  (#match? @_name "^\\\\(label|ref|eqref|pageref|autoref|nameref|vref|[cC]ref|[cC]pageref|[cC]refrange|[a-zA-Z]*cite[a-zA-Z]*|nocite|gls[a-zA-Z]*|[aA]c[a-z]*)\\*?$"))

((generic_command
  command: (command_name) @_name
  arg: (curly_group) @text.uri)
  (#match? @_name "^\\\\(url|href)$"))

(command_name) @function

; Definitions: the name being defined.
((generic_command
  command: (command_name) @_name
  arg: (curly_group (generic_command command: (command_name) @function.macro)))
  (#match? @_name "^\\\\(newcommand|renewcommand|providecommand|DeclareMathOperator|DeclareRobustCommand|NewDocumentCommand|RenewDocumentCommand)\\*?$"))

; Structure words.
((command_name) @keyword
  (#match? @keyword "^\\\\(part|chapter|addchap|section|addsec|subsection|subsubsection|paragraph|subparagraph|title|author|date|maketitle|frametitle|item|label|ref|eqref|pageref|autoref|nameref|vref|[cC]ref|[cC]pageref|[a-zA-Z]*cite[a-zA-Z]*|nocite|newcommand|renewcommand|providecommand|newenvironment|renewenvironment|DeclareMathOperator|DeclareRobustCommand|NewDocumentCommand|RenewDocumentCommand|tableofcontents|appendix|caption|centering)\\*?$"))

((command_name) @include
  (#match? @include "^\\\\(usepackage|RequirePackage|documentclass|LoadClass|input|include|includeonly|includegraphics|includesvg|bibliography|bibliographystyle|addbibresource|import|subimport|inputminted|lstinputlisting|usetikzlibrary)$"))

(begin command: _ @keyword name: (curly_group_text (text) @type))
(end command: _ @keyword name: (curly_group_text (text) @type))

(key_value_pair key: (text) @property)

[
  (line_comment)
  (block_comment)
  (comment_environment)
] @comment
