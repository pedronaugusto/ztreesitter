(comment) @comment

[
  "."
  ":"
  "*"
  "request"
  "response"
] @keyword

(type_definition
  name: (identifier) @type)

(field_definition
  type: (identifier) @type.builtin
  (#any-of? @type.builtin "integer" "boolean" "string" "binary" "double"))

(protocol_definition
  name: (identifier) @function)

(field_definition
  name: (identifier) @property)

(field_definition
  tag: (integer) @number)
(protocol_definition
  tag: (integer) @number)

[
  "("
  ")"
  "{"
  "}"
] @punctuation.bracket

