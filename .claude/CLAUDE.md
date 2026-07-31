# Personal Core Coding Principles

Apply these guidelines when considering code modifications:

- **Minimal Comments**: Keep code comments to a minimum. Code should be self-documenting whenever possible.
- **Rule of Three**: Refactor for abstractions only after seeing a pattern three times—avoid premature generalization.
- **No Magic Values**: Avoid magic numbers or hardcoded strings. Define clear constants or ENUMs.
- **Stateful Defect Prevention**: Actively identify and prevent stateful software defects (e.g., race conditions, unhandled stale states, side effects in pure functions).