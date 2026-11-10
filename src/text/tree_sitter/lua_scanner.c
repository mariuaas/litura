#define tree_sitter_lua_external_scanner_create substrate_lua_scanner_create
#include "lua_scanner_source.c"
#undef tree_sitter_lua_external_scanner_create

void *tree_sitter_lua_external_scanner_create(void) {
    return substrate_lua_scanner_create();
}
