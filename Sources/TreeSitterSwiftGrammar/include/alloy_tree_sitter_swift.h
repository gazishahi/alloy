#ifndef ALLOY_TREE_SITTER_SWIFT_H_
#define ALLOY_TREE_SITTER_SWIFT_H_

// tree-sitter-swift's generated parser (alex-pinkus/tree-sitter-swift 0.7.3, MIT; see LICENSE
// beside it), vendored because the grammar publishes its generated parser only on tags a package
// can't depend on by version. Its symbols are renamed (Package.swift) so an app that also links
// tree-sitter-swift doesn't collide.
typedef struct TSLanguage TSLanguage;

#ifdef __cplusplus
extern "C" {
#endif

const TSLanguage *alloy_tree_sitter_swift(void);

#ifdef __cplusplus
}
#endif

#endif
