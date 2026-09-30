# Frameworkless PHP → Pearfy: implemented analyzer boundary

The generic PHP adapter does not require Laravel or Symfony. It recognizes
simple paired comparisons of `$_SERVER['REQUEST_METHOD']` and
`$_SERVER['REQUEST_URI']` in a PHP source file. Results have low confidence and
retain the relative file path as evidence.

Dynamic routing tables, includes/autoloaders, PDO behavior, sessions, auth,
validation and database side effects are not inferred by this first analyzer.
OpenAPI/Swagger and tests can enrich the Legacy Contract; ambiguous behavior
must be reviewed instead of silently translated.
