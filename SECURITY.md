# Security policy

Open Desktop Tutor is pre-release software and must not yet be used to control sensitive or production applications.

## Non-negotiable design rules

- No model-facing raw coordinate, CGEvent, shell, or arbitrary code tool.
- Screen pixels, OCR text, application documents, App Packs, and model output are untrusted.
- The Mac host makes the final authorization decision and fails closed on stale, ambiguous, or unknown state.
- Consequential input requires exact window identity, a fresh semantic target receipt, an authored expected state, and local approval.
- Secure input, authentication, purchases, destructive operations, external submissions, and terminal/code execution prohibit mutations.
- Screenshots are in-memory and allowlisted by default; persistence requires an explicit user feature and separate review.
- Window capture is opt-in per request, covers exactly one allowlisted window, and never a display. Nothing is written to disk.
- A vision model may return a normalised search hint (`0..1`, relative to the captured window) and never a pixel or screen coordinate. Hints are accepted by `tutor_point` only; `tutor_propose_action` rejects them, so a hint can never authorise a mutation. Pointing is non-consequential, so a hint alone may place the AI cursor, capped below any action threshold and recorded as `model_hint` evidence.
- App Packs are untrusted, so pack-authored matchers are bounded: pattern length, subject length, and rejection of nested-quantifier patterns that permit catastrophic backtracking.

## Reporting

Do not open a public issue containing screenshots, tokens, private application data, or exploit details. Until a dedicated security address is published, open a minimal issue requesting a private reporting channel without including the sensitive details.
