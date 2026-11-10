#define tree_sitter_fennel_external_scanner_scan substrate_fennel_scan
#include "fennel_scanner_source.c"
#undef tree_sitter_fennel_external_scanner_scan

bool tree_sitter_fennel_external_scanner_scan(void *payload, TSLexer *lexer, const bool *valid_symbols) {
    return substrate_fennel_scan(payload, lexer, valid_symbols) == SCAN_SUCCESS;
}
