# Gherkin Scenario Example

Illustrates the mechanics described in `ship:spec` (Scenarios): stable spec-global `@SC-XX` numbering, `@AC-YY` tag linking to the acceptance criterion it verifies, layer tag, shared `Background`, and `Scenario Outline` + `Examples` collapsing combinatorics instead of near-duplicate `Scenario` blocks.

```gherkin
Feature: Rate limiting on the login endpoint

  Background:
    Given the login endpoint is configured with a limit of 5 attempts per 15 minutes

  @SC-04 @AC-02 @unit
  Scenario: Request under the limit succeeds
    Given the client has made 4 failed login attempts in the last 15 minutes
    When the client submits a 5th login attempt
    Then the request is processed normally

  @SC-05 @AC-02 @integration
  Scenario Outline: Requests over the limit are rejected with the correct status
    Given the client has made <attempts> failed login attempts in the last 15 minutes
    When the client submits another login attempt
    Then the response status is <status>

    Examples:
      | attempts | status |
      | 5        | 429    |
      | 10       | 429    |
```

Notes:
- `@SC-XX` numbers are assigned once, spec-globally, and never renumbered — even if scenarios are reordered or a later revision removes an earlier one.
- `@AC-YY` links the scenario back to the specific acceptance criterion it verifies; sibling scenarios can share an AC while each testing a different angle of it.
- The layer tag (`@unit`/`@integration`/`@e2e`) determines which `ship:test` worker picks up the scenario.
- `Scenario Outline` + `Examples` replaces near-duplicate `Scenario` blocks whenever only the input/expected-output values differ — this is what "collapse combinatorics" means.
- `Background` holds setup shared by every scenario in the `Feature`, stated once instead of repeated per scenario.
