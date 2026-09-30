# Laravel → Pearfy: implemented route analyzer

The analyzer recognizes Laravel in `composer.json` and extracts literal
`Route::get/post/put/patch/delete/options/any` paths from PHP route files.
Path placeholders are normalized to the canonical `{name}` form.

Route groups/prefixes, middleware authorization, validation, model binding,
Eloquent behavior, jobs, queues, events, cache and transaction semantics are
not translated. Import OpenAPI/Postman evidence where available and review the
canonical contract before implementing Pearfy endpoints.
