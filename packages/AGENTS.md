# Shared Swift component rules

- Packages hold reusable components/value contracts. They must not import the App module, own authentication, call model/backend APIs or authorize effects.
- Keep platform availability explicit and host integration visible. Package tests supplement, but do not replace, the native host's acceptance.
- Add a new package only when an actual shared boundary is being implemented. Do not create empty Domain/Core/UI package trees in advance.
- Preserve component input identity, user edits and cancellation. Keep localization/accessibility and narrow-width behavior with the component change.
