(comment) @comment @spell

(generated_comment) @comment

(subject) @markup.heading

(type) @keyword

(scope) @variable.parameter

(change_id) @constant

(filepath) @string.special.path

((rest) @comment
  (#not-match? @comment "^diff"))

"JJ: ignore-rest" @keyword.directive

[
  "("
  ")"
] @punctuation.bracket

":" @punctuation.delimiter

"!" @punctuation.special

[
  "A"
  "C"
] @diff.plus

"D" @diff.minus

[
  "M"
  "R"
] @diff.delta
