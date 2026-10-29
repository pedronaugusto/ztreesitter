; Swift tags, ztreesitter's own (MIT), for alex-pinkus/tree-sitter-swift.
;
; tree-sitter's tags convention: one tag per name, and where two patterns
; tag one name the earlier wins, so definitions come first, then calls,
; then member access, then types. An `extension` is a reference to the type
; it extends: a second definition would make its name ambiguous.

; Types, with the doc comments directly above them.

([(comment) (multiline_comment)]* @doc
  .
  (class_declaration
    declaration_kind: "class"
    name: (type_identifier) @name) @definition.class
  (#strip! @doc "^(//+|/\\*+)\\s*|\\s*\\*+/$")
  (#select-adjacent! @doc @definition.class))

([(comment) (multiline_comment)]* @doc
  .
  (class_declaration
    declaration_kind: "struct"
    name: (type_identifier) @name) @definition.struct
  (#strip! @doc "^(//+|/\\*+)\\s*|\\s*\\*+/$")
  (#select-adjacent! @doc @definition.struct))

([(comment) (multiline_comment)]* @doc
  .
  (class_declaration
    declaration_kind: "enum"
    name: (type_identifier) @name) @definition.enum
  (#strip! @doc "^(//+|/\\*+)\\s*|\\s*\\*+/$")
  (#select-adjacent! @doc @definition.enum))

([(comment) (multiline_comment)]* @doc
  .
  (class_declaration
    declaration_kind: "actor"
    name: (type_identifier) @name) @definition.class
  (#strip! @doc "^(//+|/\\*+)\\s*|\\s*\\*+/$")
  (#select-adjacent! @doc @definition.class))

([(comment) (multiline_comment)]* @doc
  .
  (protocol_declaration name: (type_identifier) @name) @definition.interface
  (#strip! @doc "^(//+|/\\*+)\\s*|\\s*\\*+/$")
  (#select-adjacent! @doc @definition.interface))

(typealias_declaration name: (type_identifier) @name) @definition.typealias

(associatedtype_declaration name: (type_identifier) @name) @definition.type

; Members: functions in a type body are methods.

(class_body
  [(comment) (multiline_comment)]* @doc
  .
  (function_declaration name: (simple_identifier) @name) @definition.method
  (#strip! @doc "^(//+|/\\*+)\\s*|\\s*\\*+/$")
  (#select-adjacent! @doc @definition.method))

(enum_class_body
  [(comment) (multiline_comment)]* @doc
  .
  (function_declaration name: (simple_identifier) @name) @definition.method
  (#strip! @doc "^(//+|/\\*+)\\s*|\\s*\\*+/$")
  (#select-adjacent! @doc @definition.method))

; With no comment before it, a member is matched above only as its body's
; first child (the anchor follows nothing): the rest are matched here.

(class_body (function_declaration name: (simple_identifier) @name) @definition.method)

(enum_class_body (function_declaration name: (simple_identifier) @name) @definition.method)

(protocol_function_declaration name: (simple_identifier) @name) @definition.method

(init_declaration "init" @name) @definition.constructor

([(comment) (multiline_comment)]* @doc
  .
  (function_declaration name: (simple_identifier) @name) @definition.function
  (#strip! @doc "^(//+|/\\*+)\\s*|\\s*\\*+/$")
  (#select-adjacent! @doc @definition.function))

; Properties of a type, and globals; a `let` in a function body is local.

(class_body
  (property_declaration
    name: (pattern bound_identifier: (simple_identifier) @name)) @definition.property)

(enum_class_body
  (property_declaration
    name: (pattern bound_identifier: (simple_identifier) @name)) @definition.property)

(source_file
  (property_declaration
    name: (pattern bound_identifier: (simple_identifier) @name)) @definition.property)

(protocol_property_declaration
  name: (pattern bound_identifier: (simple_identifier) @name)) @definition.property

(enum_entry name: (simple_identifier) @name) @definition.constant

; Imports.

(import_declaration (identifier) @name) @reference.module

; Calls: `f()` (or `Type()`, a construction) and `x.f()`.

(call_expression (simple_identifier) @name) @reference.call

(call_expression
  (navigation_expression
    suffix: (navigation_suffix suffix: (simple_identifier) @name))) @reference.call

; Member access: the member, and a receiver named outright.

(navigation_expression
  suffix: (navigation_suffix suffix: (simple_identifier) @name)) @reference.member

(navigation_expression target: (simple_identifier) @name) @reference.member

; Types in every position: inheritance and conformance lists, annotations,
; generic arguments, constraints, attributes, extensions.

(user_type (type_identifier) @name) @reference.type
