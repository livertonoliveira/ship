# Security Categories

Mapping of Security Focus categories to active OWASP Top 10 IDs for `/ship:security` and `/ship:audit:security`.

## Category → OWASP mapping

| Category           | OWASP IDs activated                              | Count |
|--------------------|--------------------------------------------------|-------|
| `all` (default)    | A01, A02, A03, A04, A05, A06, A07, A08, A09, A10 | 10/10 |
| `web-api`          | A01, A02, A03, A05, A07, A08                     | 6/10  |
| `mobile`           | A01, A02, A03, A07                               | 4/10  |
| `infrastructure`   | A05, A06, A09, A10                               | 4/10  |
| `none`             | (skip security phase entirely)                   | 0/10  |

## OWASP Top 10 reference

| ID  | Name                                        |
|-----|---------------------------------------------|
| A01 | Broken Access Control                       |
| A02 | Cryptographic Failures                      |
| A03 | Injection                                   |
| A04 | Insecure Design                             |
| A05 | Security Misconfiguration                   |
| A06 | Vulnerable and Outdated Components          |
| A07 | Identification and Authentication Failures  |
| A08 | Software and Data Integrity Failures        |
| A09 | Security Logging and Monitoring Failures    |
| A10 | Server-Side Request Forgery (SSRF)          |

## Category rationale

- **web-api**: APIs and web backends — focuses on injection, auth, access control, data exposure, and integrity.
  Excludes A04 (insecure design), A06 (dependency CVEs), A09 (logging), A10 (SSRF) — addressed at architecture level.
- **mobile**: Mobile clients and their backends — focuses on injection, cryptographic failures, auth failures.
  Excludes SSRF/server-side checks (A05, A06, A09, A10) that are not applicable to mobile clients.
- **infrastructure**: Infrastructure and DevOps pipelines — focuses on misconfiguration, outdated components,
  logging gaps, and SSRF. Excludes A01–A04 (application-layer concerns) and A07–A08.
- **none**: Equivalent to setting `security: disabled` in Pipeline Phases. Use when the diff has no security surface.

## Usage in commands

When a command reads `Security Focus → categories` from `ship/config.md`:

1. If the field is absent or blank → default to `all`
2. If the value is `none` → skip the entire security phase
3. If the value is not one of the valid categories above → emit error to the user (in pt-BR per Artifact language):
   `Categoria inválida: "<value>". Opções válidas: all | web-api | mobile | infrastructure | none`
4. Otherwise → look up the active OWASP IDs from the table above and log to the user (in pt-BR):
   `Security focus: <category> (<n>/10 OWASP categorias ativas)`

Pass the active OWASP IDs as context to each security sub-agent so they focus only on vulnerabilities
mapped to those IDs.
