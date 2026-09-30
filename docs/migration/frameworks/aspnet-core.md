# ASP.NET Core → Pearfy: implemented route analyzer

The analyzer recognizes `.csproj` references to ASP.NET Core, `[Route]` class
prefixes with `[controller]` substitution, and `[HttpGet]`/`[HttpPost]`/
`[HttpPut]`/`[HttpPatch]`/`[HttpDelete]`-style method attributes. It records
controller/action names and basic `[Authorize]`/`[AllowAnonymous]` metadata.

Authorization policies, filters, model binding, validation, EF Core schema,
transactions and middleware behavior are not converted. OpenAPI and tests
remain important evidence sources; ambiguous policy must stay a conflict or
review item.
