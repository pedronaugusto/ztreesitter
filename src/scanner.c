#include "tree_sitter/parser.h"

#include <stdbool.h>
#include <string.h>
#include <wctype.h>

enum TokenType { CHANGE_ID, DIFF_SUMMARY, SUBJECT, ERROR_SENTINEL };

void *tree_sitter_jjdescription_external_scanner_create() {
    return NULL;
}

void tree_sitter_jjdescription_external_scanner_destroy(void *p) {}

void tree_sitter_jjdescription_external_scanner_reset(void *p) {}

unsigned tree_sitter_jjdescription_external_scanner_serialize(void *p,
                                                              char *buffer) {
    return 0;
}

void tree_sitter_jjdescription_external_scanner_deserialize(void *p,
                                                            const char *b,
                                                            unsigned n) {}

bool tree_sitter_jjdescription_external_scanner_scan(
    void *payload, TSLexer *lexer, const bool *valid_symbols) {
    if (valid_symbols[ERROR_SENTINEL] || lexer->get_column(lexer) != 0) {
        return false;
    }

    bool advanced = false;
    if (valid_symbols[CHANGE_ID] || valid_symbols[DIFF_SUMMARY]) {
        const char *comment_prefix = "JJ: ";
        int prefix_len = strlen(comment_prefix);
        int idx = 0;

        while (idx < prefix_len && lexer->lookahead == comment_prefix[idx] &&
               !lexer->eof(lexer)) {
            lexer->advance(lexer, false);
            idx++;
        }

        if (idx != prefix_len) {
            if (idx == strlen("JJ:")) {
                return false;
            }
            if (idx > 0) {
                advanced = true;
                goto subject_continued;
            }
            goto subject;
        }
    }

    if (valid_symbols[CHANGE_ID]) {
        const char *generated_string = "Change ID: ";
        int gen_str_len = strlen(generated_string);
        int idx = 0;

        while (idx < gen_str_len && lexer->lookahead == generated_string[idx] &&
               !lexer->eof(lexer)) {
            lexer->advance(lexer, false);
            idx++;
        }

        if (idx == gen_str_len) {
            if (lexer->lookahead < 'k' || lexer->lookahead > 'z') {
                return false;
            }

            lexer->mark_end(lexer);
            while (lexer->lookahead >= 'k' && lexer->lookahead <= 'z') {
                lexer->advance(lexer, false);
            }

            lexer->result_symbol = CHANGE_ID;
            return lexer->lookahead == '\r' || lexer->lookahead == '\n' ||
                   lexer->eof(lexer);
        } else if (idx > 0) {
            return false;
        }
    }

    if (valid_symbols[DIFF_SUMMARY]) {
        const char *generated_prefix = "    ";
        int gen_str_len = strlen(generated_prefix);
        int idx = 0;

        while (idx < gen_str_len && lexer->lookahead == generated_prefix[idx] &&
               !lexer->eof(lexer)) {
            lexer->advance(lexer, false);
            idx++;
        }

        lexer->mark_end(lexer);

        if (idx == gen_str_len &&
            (lexer->lookahead == 'A' || lexer->lookahead == 'M' ||
             lexer->lookahead == 'D' || lexer->lookahead == 'C' ||
             lexer->lookahead == 'R')) {
            lexer->advance(lexer, false);
        } else {
            return false;
        }

        if (lexer->lookahead == ' ') {
            lexer->advance(lexer, false);
            if (lexer->lookahead != '\r' && lexer->lookahead != '\n' &&
                !lexer->eof(lexer)) {
                lexer->result_symbol = DIFF_SUMMARY;
                return true;
            }
        }

        return false;
    }

subject:
    if (valid_symbols[SUBJECT]) {
        while (iswspace(lexer->lookahead) && lexer->lookahead != '\r' &&
               lexer->lookahead != '\n' && !lexer->eof(lexer)) {
            lexer->advance(lexer, false);
            advanced = true;
        }

        if (!iswalnum(lexer->lookahead) && lexer->lookahead != '_') {
            goto subject_end;
        }

    subject_continued:
        while (iswalnum(lexer->lookahead) || lexer->lookahead == '_') {
            lexer->advance(lexer, false);
            advanced = true;
        }
        if (lexer->lookahead == '(') {
            lexer->advance(lexer, false);
            advanced = true;

            if (lexer->lookahead == '\r' || lexer->lookahead == '\n' ||
                lexer->lookahead == ')' || lexer->eof(lexer)) {
                goto subject_end;
            }

            while (lexer->lookahead != '\r' && lexer->lookahead != '\n' &&
                   lexer->lookahead != ')' && !lexer->eof(lexer)) {
                advanced = true;
                lexer->advance(lexer, false);
            }

            if (lexer->lookahead != ')') {
                goto subject_end;
            } else {
                advanced = true;
                lexer->advance(lexer, false);
            }
        }

        if (lexer->lookahead == '!') {
            advanced = true;
            lexer->advance(lexer, false);
        }

        if (lexer->lookahead == ':' || lexer->lookahead == 0xFF1A) {
            return false;
        };

    subject_end:
        while (lexer->lookahead != '\r' && lexer->lookahead != '\n' &&
               !lexer->eof(lexer)) {
            advanced = true;
            lexer->advance(lexer, false);
        }

        lexer->result_symbol = SUBJECT;
        return advanced;
    }

    return false;
}
