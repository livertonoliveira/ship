---
name: security
description: "Ship Phase 5: OWASP security scan of the diff with 3 parallel agents by attack category."
argument-hint: "<feature-name>"
allowed-tools: Read, Glob, Grep, Bash, Agent
model: "sonnet"
context: fork
agent: general-purpose
---

# Ship Security — Security Analysis

You are the Ship security agent. Your mission is to analyze the new/modified code in the feature looking for security vulnerabilities, using the OWASP methodology and launching 3 parallel agents specialized by attack category.

**Input received:** $ARGUMENTS

---

## Determine storage mode

See @ship/patterns/storage-mode.md.

---

## Execution mode

Use `$ARGUMENTS` to identify the feature or task ID. If a scratch dir exists at `.context/ship-run/<task-id>/`, use the pre-populated `diff.md` and `stack.md`; otherwise fall back to `git diff` and `ship/config.md` for stack info.

---

## Process

### 1. Load context

See @ship/patterns/load-artifacts.md (pipeline phase context).

**Stack and diff are read from `@ship/patterns/run-context.md` when available, with fallback to local detection.**

Resolve stack and diff using the following priority:

**Stack:**
- If `.context/ship-run/<task-id>/stack.md` exists → read stack from it (preferred)
- Otherwise → fallback: read `ship/config.md` for stack information (current behavior)

**Diff:**
- If `.context/ship-run/<task-id>/diff.md` exists and is non-empty → read diff from it (preferred)
- Otherwise → fallback: run `git diff` to obtain the diff (current behavior)

Read `ship/config.md` for **Stack**, **Framework**, and **Project Type**.

### 1.5. Determine Security Focus

Read `Security Focus → categories` from `ship/config.md`:

- If the field is **absent or blank** → default to `all`
- If the value is `none` → log `Security focus: none — fase pulada.` and **STOP** immediately (do not write a findings file, do not spawn agents)
- If the value is **not one of** `all`, `web-api`, `mobile`, `infrastructure`, `none` → **STOP** with error:
  `Categoria inválida: "<value>". Opções válidas: all | web-api | mobile | infrastructure | none`

See @ship/patterns/security-categories.md for the full category → OWASP ID mapping.

Look up the active OWASP IDs for the configured category and log to the user:

```
Security focus: <category> (<n>/10 OWASP categorias ativas)
```

Store the active OWASP IDs in a local variable to pass as context to each agent in step 2.

### 1.6. Slice diff by category

Before launching agents, partition the diff (loaded in step 1) into three category-scoped slices. Always include the `diff --git a/...` file header and the full `@@ ... @@` hunk header for each hunk, plus ±3 surrounding context lines, so each agent has enough scope to understand the change.

| Agent | Include hunks from files matching (case-insensitive) |
|-------|------------------------------------------------------|
| **A — Injection** | `*controller*`, `*route*`, `*resolver*`, `*handler*`, `*parser*`, `*validator*`, `*dto*`, `*schema*`, `*query*`, `*repository*`, `*repo*` |
| **B — Auth** | `*guard*`, `*middleware*`, `*auth*`, `*session*`, `*jwt*`, `*permission*`, `*role*`, `*policy*`, `*cors*`, `*interceptor*` |
| **C — Data/Config** | `*encrypt*`, `*crypto*`, `*log*`, `*config*`, `*setting*`, `*.env*`, `*cookie*`, `*header*`, `*secret*`, `*hash*`, `*password*` |

If a hunk does not match any category, include it in **all three** slices. Pass each slice as an inline block in the respective agent's prompt — do NOT instruct agents to read `diff.md` or run `git diff` themselves.

### 2. Launch 3 agents in parallel

Use the **Agent** tool to launch **3 agents in parallel in a SINGLE call**. Pass the active OWASP IDs (from step 1.5) as context so each agent focuses only on vulnerabilities mapped to those categories. Each agent receives only its category-scoped diff slice inline (prepared in step 1.6) — do not include instructions to read `diff.md`.

---

### Agent A — Injection + Input Validation

> **Inline context**: the injection-category diff slice is provided inline in your prompt. Do not read `diff.md` or run `git diff`.

Analyze ONLY the new/modified code looking for:

| Vulnerability | What to look for |
|--------------|-----------------|
| **NoSQL Injection** | User input passed directly to MongoDB queries without sanitization (e.g., `{ email: req.body.email }` where body could contain `{ "$gt": "" }`) |
| **SQL Injection** | String concatenation in SQL queries, missing parameterized queries, template literals in raw SQL |
| **Command Injection** | `exec()`, `spawn()`, `eval()`, `Function()` with user input, `child_process` with unsanitized args |
| **XSS (Cross-Site Scripting)** | User input rendered without escaping, `dangerouslySetInnerHTML`, `innerHTML`, unescaped template interpolation |
| **Server-Side Template Injection** | User data injected into server-side templates without escaping |
| **Path Traversal** | File paths constructed with user input without validation (`../../etc/passwd`) |
| **ReDoS** | Complex regex patterns applied to user input that could cause catastrophic backtracking |
| **Header Injection** | HTTP headers constructed with unsanitized user input |
| **Log Injection** | User data written directly to logs, allowing log forging |
| **Incomplete Input Validation** | DTOs/schemas missing validation rules, query params without validation, path params not validated as expected type, file upload without type/size checks |

**Stack-specific:**
- **Node.js/Express/NestJS**: class-validator completeness, Zod schemas, Express middleware ordering
- **Python/Django/Flask**: form validation, SQL ORM injection, template auto-escaping
- **Go**: sql.Prepare usage, template escaping, os/exec usage
- **Any ORM**: raw query usage, query builder injection points

---

### Agent B — Auth + Access Control

> **Inline context**: the auth-category diff slice is provided inline in your prompt. Do not read `diff.md` or run `git diff`.

Analyze ONLY the new/modified code looking for:

| Vulnerability | What to look for |
|--------------|-----------------|
| **Missing Authentication** | New endpoints without auth guard/middleware, public routes that should be protected |
| **Missing Authorization** | Endpoints accessible to any authenticated user that should check roles/permissions |
| **IDOR** | Accessing resources by ID without verifying ownership (e.g., `GET /appointments/:id` without checking if it belongs to the user) |
| **Mass Assignment** | Fields like `role`, `isAdmin`, `companyId`, `userId` accepted in DTOs/request bodies without protection |
| **Privilege Escalation (Vertical)** | Regular user accessing admin functionality |
| **Privilege Escalation (Horizontal)** | User accessing another user's data at the same permission level |
| **Multi-tenant Leak** | Data from one tenant/company visible to another, missing tenant filtering in queries |
| **Broken Session Management** | Session ID not regenerated after login, missing session expiration, insecure session storage |
| **JWT Issues** | Missing `exp`/`iss`/`aud` validation, accepting `alg: none`, weak secret, excessive token TTL |
| **CORS Misconfiguration** | `Access-Control-Allow-Origin: *` with credentials, overly permissive origins |
| **Method Tampering** | Endpoint accepting unintended HTTP methods (e.g., DELETE where only GET was intended) |

**Stack-specific:**
- **NestJS**: Guards, decorators (@Roles, @Public), AuthGuard coverage
- **Express**: Middleware ordering, passport configuration
- **Django**: @login_required, permissions_classes, viewset permissions
- **Any framework**: Route protection completeness, middleware chain

---

### Agent C — Data Exposure + Configuration

> **Inline context**: the data/config-category diff slice is provided inline in your prompt. Do not read `diff.md` or run `git diff`.

Analyze ONLY the new/modified code looking for:

| Vulnerability | What to look for |
|--------------|-----------------|
| **Hardcoded Secrets** | API keys, passwords, tokens, connection strings in source code |
| **PII in Logs** | Personal data (email, phone, CPF, SSN, address) logged in plain text |
| **Sensitive Data in Responses** | Passwords, internal IDs, tokens, debug info returned in API responses |
| **Stack Traces in Production** | Error responses exposing internal details (file paths, query structure, stack traces) |
| **Missing Security Headers** | No Helmet/equivalent, missing CSP, HSTS, X-Frame-Options, X-Content-Type-Options |
| **Missing Rate Limiting** | Auth endpoints, public APIs, or expensive operations without throttling |
| **Sensitive Data in URL** | Tokens or PII in query strings (logged by servers/proxies) |
| **Insecure Password Handling** | Weak hashing (MD5, SHA1, SHA256 without salt), bcrypt with rounds < 10, plaintext storage |
| **Missing Encryption** | Sensitive data stored/transmitted without encryption |
| **Dependency Vulnerabilities** | New dependencies added that have known CVEs (check package.json changes) |
| **Debug Endpoints Exposed** | `/debug`, `/metrics`, `/swagger` accessible in production without auth |
| **Insecure Cookie Configuration** | Missing `httpOnly`, `secure`, `sameSite` flags |
| **Environment Variables** | `.env` files not in `.gitignore`, `.env.example` with real values |

**Stack-specific:**
- **Node.js**: Helmet configuration, Express error handler, environment-based debug mode
- **Python**: Django DEBUG setting, Flask debug mode, logging configuration
- **Any framework**: Error handling middleware, response serialization, logging configuration

---

### 3. Consolidate findings

See @ship/report-templates.md#finding-entry (Security pipeline). Categories: `INJ | AUTH | AUTHZ | DATA | CFG | LOGIC`.

See @ship/report-templates.md#finding-schema for the JSON block (includes `owasp` and `cwe` extra fields).

**Severity classification (Security):**
- **critical**: Remote exploitation without authentication, unrestricted access to sensitive data. Requires immediate fix.
- **high**: Exploitation possible with authentication or specific conditions. Significant impact risk.
- **medium**: Hard to exploit but relevant impact, or easy to exploit with limited impact.
- **low**: Theoretical risk, defense-in-depth, or best practice not followed.

### 4. Write report

Write the findings to the file `ship/changes/<feature>/security-findings.md` (when a scratch dir is present) or directly in the Security section of `report.md` (when invoked without a scratch dir).

**Note:** In both Linear mode and Local mode, the findings file is written locally. In Linear mode this is a temporary file — the orchestrator handles posting it to Linear and cleaning up.

Format:

```markdown
# Security Findings

## Summary
- Critical: X
- High: X
- Medium: X
- Low: X
- **Gate: PASS | WARN | FAIL**

## Findings

[findings here, ordered by severity]
```

**Gate rules (inline):** `critical` or `high` → **FAIL** | `medium` → **WARN** | only `low` or none → **PASS**

When invoked with a scratch dir (by `ship:run`): compute the gate and include it in the summary; the orchestrator applies severity overrides independently before its own gate evaluation.
When invoked without a scratch dir: apply severity overrides from `ship/config.md → Severity Overrides` before computing the gate.

---

## Rules

- **Analyze ONLY the diff**: do not audit the entire codebase. For project-wide security audit, run `/ship:audit:security`.
- **No false positives**: only report with concrete evidence. "There might be a vulnerability" is not a finding.
- **Proof of Concept required for critical/high**: show how the attack would work
- **Fixes with code**: every fix must include a code example using the project's patterns
- **Consider the context**: an internal API has a different threat model than a public API
- **Do not recommend security theater**: avoid suggestions that add complexity without real benefit
- **ALWAYS launch 3 agents in parallel**: each one focuses on its attack category
- **Language**: Use the `artifact_language` injected in this prompt if available; otherwise read `Artifact language` from `ship/config.md → Conventions` per @ship/patterns/language.md.
- **Linear mode**: read design context from Linear document instead of local file; findings are still written to a local temporary file
- **Local mode**: read design context from local `design.md`; findings are written to local file
