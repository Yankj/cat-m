# Native App rules

- This is the only active iPhone host. Preserve bundle, Keychain, container and signing identity; packaging/install authorization is in the root instructions.
- App owns composition and account lifecycle; Features owns SwiftUI presentation; Domain owns typed contracts; Providers owns HTTP/Auth adapters; Persistence owns local storage. Views call services, never providers or a second task state machine.
- Keep ordinary answers lightweight. New cards use a compiled registry with validated payload, stable object/revision, explicit actions and readable fallback. Streaming, accepted decision and actual effect are separate facts.
- Keep fixtures explicitly offline and DEBUG-gated. Never substitute fixture success for real model, phone, database or system-effect acceptance.
- Feature extraction must update the Xcode project and run affected host checks in the same slice. Do not rename the whole App or add another shell while model/execution acceptance is incomplete.
- Unsent attachment retention currently lasts one App session; cold-start persistence is a separate change. Unknown requests are reconciled by original identity, never silently resent.
