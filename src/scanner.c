/**
 * @file WXML (WeiXin Markup Language) external scanner
 * @author BlockLune <39331194+BlockLune@users.noreply.github.com>
 * @license MIT
 */

#include "tree_sitter/array.h"
#include "tree_sitter/parser.h"

#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <wctype.h>

enum TokenType {
  START_TAG_NAME,
  END_TAG_NAME,
  SELF_CLOSING_TAG_DELIMITER,
  RAW_TEXT,
  COMMENT,
  INTERPOLATION_START,
  INTERPOLATION_END,
  ERROR_SENTINEL,
};

typedef Array(char) String;

typedef struct {
  Array(String) tags;
} Scanner;

static void clear_tags(Scanner *scanner) {
  for (uint32_t i = 0; i < scanner->tags.size; i++) {
    array_delete(&scanner->tags.contents[i]);
  }
  array_clear(&scanner->tags);
}

void *tree_sitter_wxml_external_scanner_create() {
  return ts_calloc(1, sizeof(Scanner));
}

void tree_sitter_wxml_external_scanner_destroy(void *payload) {
  Scanner *scanner = payload;
  clear_tags(scanner);
  array_delete(&scanner->tags);
  ts_free(scanner);
}

void tree_sitter_wxml_external_scanner_reset(void *payload) {
  clear_tags(payload);
}

unsigned tree_sitter_wxml_external_scanner_serialize(void *payload,
                                                       char *buffer) {
  Scanner *scanner = payload;
  uint16_t tag_count = scanner->tags.size > UINT16_MAX
                           ? UINT16_MAX
                           : (uint16_t)scanner->tags.size;
  uint16_t serialized_count = 0;
  unsigned size = sizeof(serialized_count) + sizeof(tag_count);

  for (; serialized_count < tag_count; serialized_count++) {
    String *tag = &scanner->tags.contents[serialized_count];
    if (tag->size > UINT16_MAX ||
        size + sizeof(uint16_t) + tag->size >
            TREE_SITTER_SERIALIZATION_BUFFER_SIZE) {
      break;
    }

    uint16_t name_length = (uint16_t)tag->size;
    memcpy(&buffer[size], &name_length, sizeof(name_length));
    size += sizeof(name_length);
    memcpy(&buffer[size], tag->contents, name_length);
    size += name_length;
  }

  memcpy(buffer, &serialized_count, sizeof(serialized_count));
  memcpy(&buffer[sizeof(serialized_count)], &tag_count, sizeof(tag_count));
  return size;
}

void tree_sitter_wxml_external_scanner_deserialize(void *payload,
                                                     const char *buffer,
                                                     unsigned length) {
  Scanner *scanner = payload;
  clear_tags(scanner);

  if (length < 2 * sizeof(uint16_t)) {
    return;
  }

  uint16_t serialized_count;
  uint16_t tag_count;
  unsigned size = 0;
  memcpy(&serialized_count, &buffer[size], sizeof(serialized_count));
  size += sizeof(serialized_count);
  memcpy(&tag_count, &buffer[size], sizeof(tag_count));
  size += sizeof(tag_count);

  if (serialized_count > tag_count) {
    return;
  }

  array_reserve(&scanner->tags, tag_count);
  uint16_t restored_count = 0;
  for (; restored_count < serialized_count; restored_count++) {
    if (size + sizeof(uint16_t) > length) {
      break;
    }

    uint16_t name_length;
    memcpy(&name_length, &buffer[size], sizeof(name_length));
    size += sizeof(name_length);
    if (size + name_length > length) {
      break;
    }

    String tag = array_new();
    array_reserve(&tag, name_length);
    tag.size = name_length;
    memcpy(tag.contents, &buffer[size], name_length);
    size += name_length;
    array_push(&scanner->tags, tag);
  }

  // Empty placeholders cannot falsely match a real closing tag. They preserve
  // stack depth when an unusually deep document exceeds Tree-sitter's buffer.
  for (; restored_count < tag_count; restored_count++) {
    String tag = array_new();
    array_push(&scanner->tags, tag);
  }
}

static bool is_reserved_word(const String *word) {
  static const char *reserved[] = {"template", "slot",   "block",
                                   "import",   "include", "wxs"};
  const size_t count = sizeof(reserved) / sizeof(reserved[0]);
  for (size_t i = 0; i < count; i++) {
    if (strlen(reserved[i]) == word->size &&
        memcmp(reserved[i], word->contents, word->size) == 0) {
      return true;
    }
  }
  return false;
}

static String scan_tag_name(TSLexer *lexer) {
  String name = array_new();
  if (!(iswalpha(lexer->lookahead) || lexer->lookahead == '_')) {
    return name;
  }

  while (iswalnum(lexer->lookahead) || lexer->lookahead == '_' ||
         lexer->lookahead == '-' || lexer->lookahead == ':') {
    array_push(&name, (char)lexer->lookahead);
    lexer->advance(lexer, false);
  }
  return name;
}

static bool tags_equal(const String *left, const String *right) {
  return left->size == right->size &&
         memcmp(left->contents, right->contents, left->size) == 0;
}

static void pop_tag(Scanner *scanner) {
  String tag = array_pop(&scanner->tags);
  array_delete(&tag);
}

static bool scan_start_tag_name(Scanner *scanner, TSLexer *lexer) {
  String name = scan_tag_name(lexer);
  if (name.size == 0 || is_reserved_word(&name)) {
    array_delete(&name);
    return false;
  }

  array_push(&scanner->tags, name);
  lexer->result_symbol = START_TAG_NAME;
  return true;
}

static bool scan_end_tag_name(Scanner *scanner, TSLexer *lexer) {
  String name = scan_tag_name(lexer);
  if (name.size == 0 || is_reserved_word(&name)) {
    array_delete(&name);
    return false;
  }

  bool matches = scanner->tags.size > 0 &&
                 tags_equal(array_back(&scanner->tags), &name);
  array_delete(&name);
  if (!matches) {
    return false;
  }

  pop_tag(scanner);
  lexer->result_symbol = END_TAG_NAME;
  return true;
}

static bool scan_self_closing_tag_delimiter(Scanner *scanner,
                                             TSLexer *lexer) {
  lexer->advance(lexer, false);
  if (lexer->lookahead != '>' || scanner->tags.size == 0) {
    return false;
  }

  lexer->advance(lexer, false);
  pop_tag(scanner);
  lexer->result_symbol = SELF_CLOSING_TAG_DELIMITER;
  return true;
}

static bool scan_comment(TSLexer *lexer) {
  if (lexer->lookahead != '<') {
    return false;
  }
  lexer->advance(lexer, false);
  if (lexer->lookahead != '!') {
    return false;
  }
  lexer->advance(lexer, false);
  if (lexer->lookahead != '-') {
    return false;
  }
  lexer->advance(lexer, false);
  if (lexer->lookahead != '-') {
    return false;
  }
  lexer->advance(lexer, false);

  unsigned dashes = 0;
  while (lexer->lookahead) {
    if (lexer->lookahead == '-') {
      dashes++;
    } else if (lexer->lookahead == '>' && dashes >= 2) {
      lexer->advance(lexer, false);
      return true;
    } else {
      dashes = 0;
    }
    lexer->advance(lexer, false);
  }
  return false;
}

static bool scan_raw_text(TSLexer *lexer) {
  bool has_content = false;

  while (lexer->lookahead) {
    if (lexer->lookahead == '<') {
      lexer->mark_end(lexer);
      lexer->advance(lexer, false);

      if (lexer->lookahead == '/') {
        lexer->advance(lexer, false);
        if (towupper(lexer->lookahead) == 'W') {
          lexer->advance(lexer, false);
          if (towupper(lexer->lookahead) == 'X') {
            lexer->advance(lexer, false);
            if (towupper(lexer->lookahead) == 'S') {
              lexer->advance(lexer, false);
              if (lexer->lookahead == '>') {
                lexer->result_symbol = RAW_TEXT;
                return has_content;
              }
            }
          }
        }
      }
      has_content = true;
    } else {
      lexer->advance(lexer, false);
      has_content = true;
    }
  }

  lexer->result_symbol = RAW_TEXT;
  return has_content;
}

bool tree_sitter_wxml_external_scanner_scan(void *payload, TSLexer *lexer,
                                            const bool *valid_symbols) {
  Scanner *scanner = payload;
  if (valid_symbols[ERROR_SENTINEL]) {
    return false;
  }

  while (iswspace(lexer->lookahead)) {
    lexer->advance(lexer, true);
  }

  if (valid_symbols[INTERPOLATION_START] && lexer->lookahead == '{') {
    lexer->advance(lexer, false);
    if (lexer->lookahead == '{') {
      lexer->advance(lexer, false);
      lexer->result_symbol = INTERPOLATION_START;
      return true;
    }
  }

  if (valid_symbols[INTERPOLATION_END] && lexer->lookahead == '}') {
    lexer->advance(lexer, false);
    if (lexer->lookahead == '}') {
      lexer->advance(lexer, false);
      lexer->result_symbol = INTERPOLATION_END;
      return true;
    }
  }

  if (valid_symbols[RAW_TEXT]) {
    return scan_raw_text(lexer);
  }

  if (valid_symbols[COMMENT] && lexer->lookahead == '<') {
    if (scan_comment(lexer)) {
      lexer->result_symbol = COMMENT;
      return true;
    }
  }

  if (valid_symbols[START_TAG_NAME]) {
    return scan_start_tag_name(scanner, lexer);
  }

  if (valid_symbols[END_TAG_NAME]) {
    return scan_end_tag_name(scanner, lexer);
  }

  if (valid_symbols[SELF_CLOSING_TAG_DELIMITER] &&
      lexer->lookahead == '/') {
    return scan_self_closing_tag_delimiter(scanner, lexer);
  }

  return false;
}
