# Security policy

Open Desktop Tutor is pre-release software and must not yet be used to control sensitive or production applications.

## Non-negotiable design rules

- No model-facing raw coordinate, CGEvent, shell, or arbitrary code tool.
- Screen pixels, OCR text, application documents, App Packs, and model output are untrusted.
- The Mac host makes the final authorization decision and fails closed on stale, ambiguous, or unknown state.
- Consequential input requires exact window identity, a fresh semantic target receipt, an authored expected state, and local approval.
- Secure input, authentication, purchases, destructive operations, external submissions, and terminal/code execution prohibit mutations.
- Screenshots are in-memory and allowlisted by default; persistence requires an explicit user feature and separate review.

## Reporting

Do not open a public issue containing screenshots, tokens, private application data, or exploit details. Until a dedicated security address is published, open a minimal issue requesting a private reporting channel without including the sensitive details.
