# FastAPI → Pearfy: implemented route analyzer

The analyzer detects FastAPI in `requirements.txt`/`pyproject.toml` and extracts
`@app.get/post/put/patch/delete/head/options` and matching `@router` literal
paths from Python files. The extracted route is medium-confidence source
evidence; OpenAPI supplies schemas, parameter examples and response metadata.

Dependency injection through `Depends`, Pydantic coercion/validation,
authorization dependencies, exception handlers, transactions and background
tasks are not translated by this route extractor.
