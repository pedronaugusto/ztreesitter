;; Text objects (nvim-treesitter-textobjects capture names: `.outer` is the
;; whole construct, `.inner` its body). Helix and Zed use `.around`/`.inside`
;; for the same thing; MangelMaxime/tree-sitter-fsharp ships those spellings.

;; ----------------------------------------------------------------------------
;; Functions and members

(function_or_value_defn
  body: (_) @function.inner) @function.outer

;; Every member form is a function object: methods, properties with
;; accessors, `member val`, `abstract member` (no body), interface members.
(member_defn) @function.outer

;; `member this.M x = body`: the body follows the `=`; a property with
;; `with get, set` accessors has its bodies in the accessors instead.
(member_defn
  (method_or_prop_defn
    "=" . (_) @function.inner))

(additional_constr_defn
  "=" . (_) @function.inner) @function.outer

(property_accessor
  "=" . (_) @function.inner) @function.outer

(fun_expression
  (argument_patterns) . (_) @function.inner) @function.outer

(function_expression) @function.outer

;; ----------------------------------------------------------------------------
;; Types and modules

(type_definition) @class.outer
(exception_definition) @class.outer
(module_defn) @class.outer

;; The part after `=`: fields, cases or members.
(record_type_defn (record_fields) @class.inner)
(union_type_defn (union_type_cases) @class.inner)
(enum_type_defn (enum_type_cases) @class.inner)
(type_extension (type_extension_elements) @class.inner)
;; A class body (`type A() = let ... member ...`) is a flat run of siblings
;; with no wrapping node, so it has no `.inner`; `.outer` still applies.
(delegate_type_defn (delegate_signature) @class.inner)
(type_abbrev_defn block: (_) @class.inner)

;; ----------------------------------------------------------------------------
;; Parameters and arguments

(argument_patterns (_) @parameter.inner @parameter.outer)
(primary_constr_args (_) @parameter.inner @parameter.outer)
(member_defn
  (method_or_prop_defn
    args: (_) @parameter.inner @parameter.outer))
(arguments_spec (argument_spec) @parameter.inner @parameter.outer)
(tuple_expression (_) @parameter.inner @parameter.outer)

;; ----------------------------------------------------------------------------
;; Calls, blocks, control flow

(application_expression) @call.outer

(ce_expression
  block: (_) @block.inner) @block.outer
(brace_expression) @block.outer
(begin_end_expression) @block.outer
(paren_expression) @block.outer

(if_expression) @conditional.outer
(if_expression then: (_) @conditional.inner)
(if_expression else: (_) @conditional.inner)
(elif_expression then: (_) @conditional.inner)
(match_expression) @conditional.outer
(rule block: (_) @conditional.inner)
(try_expression) @conditional.outer

(for_expression) @loop.outer
(for_expression "do" . (_) @loop.inner)
(while_expression) @loop.outer
(while_expression "do" . (_) @loop.inner)

((prefixed_expression . _ @_keyword . (_) @return.inner) @return.outer
 (#any-of? @_keyword "return" "return!" "yield" "yield!"))

;; ----------------------------------------------------------------------------
;; Bindings, attributes, comments, numbers

(function_or_value_defn
  [(value_declaration_left) (function_declaration_left)] @assignment.lhs
  body: (_) @assignment.rhs) @assignment.outer @assignment.inner

(attributes) @attribute.outer
(attribute) @attribute.inner

[
  (line_comment)
  (block_comment)
  (xml_doc)
] @comment.outer
(block_comment (block_comment_content) @comment.inner)

(const) @number.inner
