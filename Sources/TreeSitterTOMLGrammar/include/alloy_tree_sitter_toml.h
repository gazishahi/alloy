#ifndef ALLOY_TREE_SITTER_TOML_H_
#define ALLOY_TREE_SITTER_TOML_H_

// tree-sitter-toml's generated parser (tree-sitter-grammars/tree-sitter-toml 0.7.0; see LICENSE beside it), vendored, as
// Alloy's other added grammars are, so it builds the same as a dependency and in an app. Its
// symbols are renamed (Package.swift) so an app linking the grammar too doesn't collide.
typedef struct TSLanguage TSLanguage;

#ifdef __cplusplus
extern "C" {
#endif

const TSLanguage *alloy_tree_sitter_toml(void);

#ifdef __cplusplus
}
#endif

#endif
