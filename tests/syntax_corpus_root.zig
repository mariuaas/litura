//! The grammar-diversity suite's test executable (`-Dsyntax-corpus=true`). The build runs
//! it once per grammar, naming the grammar in `LITURA_SYNTAX_CORPUS_GRAMMAR`.
test {
    _ = @import("syntax_corpus_test.zig");
}
