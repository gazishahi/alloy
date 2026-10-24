#ifndef ALLOY_TREE_SITTER_LATEX_H_
#define ALLOY_TREE_SITTER_LATEX_H_

// A lean build of tree-sitter-latex (latex-lsp/tree-sitter-latex 0.6.0, 7e0ecdc; see LICENSE
// beside it). The full grammar models hundreds of commands (sections as a hierarchy, citations,
// glossaries, counters, colors, TikZ, Sage and Lua blocks) as rules of their own, and its parser
// is 44 MB of C. This one keeps environments (math, verbatim, listings, comments), inline math
// and comments, and reads every other command as a command with its `{arguments}` and
// `[options]`: 0.9 MB. The highlight query tells sections, labels and packages apart by name;
// texlab understands the rest. grammar/grammar.js is the grammar it was generated from, with
// tree-sitter 0.24.7 (the project ships only its grammar). Vendored, as Alloy's other added
// grammars are, so it builds the same as a dependency and in an app. Its symbols are renamed
// (Package.swift) so an app linking the grammar too doesn't collide.
typedef struct TSLanguage TSLanguage;

#ifdef __cplusplus
extern "C" {
#endif

const TSLanguage *alloy_tree_sitter_latex(void);

#ifdef __cplusplus
}
#endif

#endif
