#ifndef ALLOY_TREE_SITTER_CSS_H_
#define ALLOY_TREE_SITTER_CSS_H_

// tree-sitter-css's generated parser (tree-sitter/tree-sitter-css 0.25.0; see LICENSE beside it), vendored, as
// Alloy's other added grammars are, so it builds the same as a dependency and in an app. Its
// symbols are renamed (Package.swift) so an app linking the grammar too doesn't collide.
typedef struct TSLanguage TSLanguage;

#ifdef __cplusplus
extern "C" {
#endif

const TSLanguage *alloy_tree_sitter_css(void);

#ifdef __cplusplus
}
#endif

#endif
