# Social with Identity

**Status: planned; not implementable as a Pearfy module integration in this checkout.** The `social` graph/content contracts exist, but `identity` and `social-login` are not installable Registry entries. No OAuth/OIDC, account linking, issuer/subject store or login callbacks are provided.

For work today, keep the application's existing actor/owner IDs and authentication boundary. Do not create or merge accounts by email. Revisit this recipe only after Identity and SocialLogin are registered, versioned, implemented, and covered by security/integration tests.
