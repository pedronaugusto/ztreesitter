;; Fold regions (nvim-treesitter `@fold`): every node whose body usually spans
;; lines. Editors that fold by indentation ignore this file.

[
  (module_defn)
  (function_or_value_defn)
  (member_defn)
  (type_definition)
  (exception_definition)
  (interface_implementation)
  (match_expression)
  (function_expression)
  (rule)
  (if_expression)
  (elif_expression)
  (for_expression)
  (while_expression)
  (try_expression)
  (fun_expression)
  (ce_expression)
  (brace_expression)
  (anon_record_expression)
  (list_expression)
  (array_expression)
  (paren_expression)
  (begin_end_expression)
  (object_expression)
  (literal_expression)
  (block_comment)
  (preproc_if)
] @fold

;; Consecutive line comments and `///` doc blocks fold as one region.
(line_comment)+ @fold
(xml_doc)+ @fold
