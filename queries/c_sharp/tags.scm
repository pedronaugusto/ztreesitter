; C# tags, ztreesitter's own (MIT), for tree-sitter-c-sharp.
;
; tree-sitter's tags convention: one tag per name, and where two patterns
; tag one name the earlier wins, so definitions come first, then calls,
; then member access, then types in every position.

; Types, with the doc comments directly above them.

((comment)* @doc
  .
  (class_declaration name: (identifier) @name) @definition.class
  (#strip! @doc "^//+\\s*")
  (#select-adjacent! @doc @definition.class))

((comment)* @doc
  .
  (struct_declaration name: (identifier) @name) @definition.struct
  (#strip! @doc "^//+\\s*")
  (#select-adjacent! @doc @definition.struct))

((comment)* @doc
  .
  (record_declaration name: (identifier) @name) @definition.record
  (#strip! @doc "^//+\\s*")
  (#select-adjacent! @doc @definition.record))

((comment)* @doc
  .
  (interface_declaration name: (identifier) @name) @definition.interface
  (#strip! @doc "^//+\\s*")
  (#select-adjacent! @doc @definition.interface))

((comment)* @doc
  .
  (enum_declaration name: (identifier) @name) @definition.enum
  (#strip! @doc "^//+\\s*")
  (#select-adjacent! @doc @definition.enum))

((comment)* @doc
  .
  (delegate_declaration name: (identifier) @name) @definition.delegate
  (#strip! @doc "^//+\\s*")
  (#select-adjacent! @doc @definition.delegate))

(namespace_declaration
  name: [
    (identifier) @name
    (qualified_name) @name
  ]) @definition.module

(file_scoped_namespace_declaration
  name: [
    (identifier) @name
    (qualified_name) @name
  ]) @definition.module

; Members.

((comment)* @doc
  .
  (method_declaration name: (identifier) @name) @definition.method
  (#strip! @doc "^//+\\s*")
  (#select-adjacent! @doc @definition.method))

((comment)* @doc
  .
  (constructor_declaration name: (identifier) @name) @definition.constructor
  (#strip! @doc "^//+\\s*")
  (#select-adjacent! @doc @definition.constructor))

((comment)* @doc
  .
  (property_declaration name: (identifier) @name) @definition.property
  (#strip! @doc "^//+\\s*")
  (#select-adjacent! @doc @definition.property))

(field_declaration
  (variable_declaration
    (variable_declarator name: (identifier) @name))) @definition.field

(event_declaration name: (identifier) @name) @definition.event

(event_field_declaration
  (variable_declaration
    (variable_declarator name: (identifier) @name))) @definition.event

(enum_member_declaration name: (identifier) @name) @definition.constant

(local_function_statement name: (identifier) @name) @definition.function

; Imports.

(using_directive
  [
    (identifier) @name
    (qualified_name) @name
  ]) @reference.module

; Calls: `F()`, `F<T>()`, `x.F()`, `x.F<T>()`.

(invocation_expression function: (identifier) @name) @reference.call

(invocation_expression function: (generic_name (identifier) @name)) @reference.call

(invocation_expression
  function: (member_access_expression
    name: [
      (identifier) @name
      (generic_name (identifier) @name)
    ])) @reference.call

; Member access: the member, and a receiver named outright (a type, a
; namespace or a variable: names do not say which).

(member_access_expression name: (identifier) @name) @reference.member

(member_access_expression expression: (identifier) @name) @reference.member

; Types: inheritance lists, attributes, generic arguments, and every `type`
; and `returns` field (parameters, fields, properties, locals, `new`, casts,
; `typeof`, constraints, array and nullable element types).

(base_list (identifier) @name) @reference.type

(primary_constructor_base_type type: (identifier) @name) @reference.type

(attribute name: (identifier) @name) @reference.type

(type_argument_list (identifier) @name) @reference.type

(_ type: (identifier) @name) @reference.type

(method_declaration returns: (identifier) @name) @reference.type

; Qualified types in those positions, by their last name.

(base_list (qualified_name name: (identifier) @name)) @reference.type

(attribute name: (qualified_name name: (identifier) @name)) @reference.type

(type_argument_list (qualified_name name: (identifier) @name)) @reference.type

(_ type: (qualified_name name: (identifier) @name)) @reference.type

; Generic types, wherever they are (a generic call is tagged above).

(generic_name (identifier) @name) @reference.type
