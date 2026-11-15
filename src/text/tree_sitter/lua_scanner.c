#define tree_sitter_lua_external_scanner_create substrate_lua_scanner_create
#define tree_sitter_lua_external_scanner_scan upstream_lua_scanner_scan
#include "lua_scanner_source.c"
#undef tree_sitter_lua_external_scanner_create
#undef tree_sitter_lua_external_scanner_scan

void *tree_sitter_lua_external_scanner_create(void) {
    return substrate_lua_scanner_create();
}

// During error recovery Tree-sitter marks every external token valid. The upstream
// scanner then scans for block content, which reads to the end of the file when no
// closing bracket follows, so each token lexed while recovering costs the rest of the
// document. No parse state expects both a block comment's end and a block string's end,
// so that combination identifies recovery; only block starts are recognized then.
bool tree_sitter_lua_external_scanner_scan(void *payload, TSLexer *lexer, const bool *valid_symbols) {
    if (valid_symbols[BLOCK_COMMENT_END] && valid_symbols[BLOCK_STRING_END]) {
        const bool starts_only[] = {
            [BLOCK_COMMENT_START] = true,
            [BLOCK_COMMENT_CONTENT] = false,
            [BLOCK_COMMENT_END] = false,
            [BLOCK_STRING_START] = true,
            [BLOCK_STRING_CONTENT] = false,
            [BLOCK_STRING_END] = false,
        };
        return upstream_lua_scanner_scan(payload, lexer, starts_only);
    }
    return upstream_lua_scanner_scan(payload, lexer, valid_symbols);
}
