import Foundation

// Portable check for the first-launch intro gate (key + initial state + gate semantics).
@main enum OnboardingGateRunner {
    static func expect(_ ok: Bool, _ message: String) { if !ok { FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8)); exit(1) } }
    static func main() {
        let suite = "catpaw.onboarding.portable." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { expect(false, "suite"); return }
        defer { defaults.removePersistentDomain(forName: suite) }
        expect(catOnboarding.completedKey == "catpaw.onboarding.completed.v1", "stable key")
        expect(catOnboarding.initialState(defaults: defaults, arguments: []) == .needsOnboarding, "fresh install shows intro")
        expect(catOnboarding.initialState(defaults: defaults, arguments: [], fixture: true) == .completed, "auth fixtures skip intro")
        expect(catOnboarding.initialState(defaults: defaults, arguments: [catOnboarding.skipArgument]) == .completed, "launch argument skips intro")
        catOnboarding.markCompleted(defaults)
        expect(defaults.bool(forKey: "catpaw.onboarding.completed.v1"), "flag persisted under key")
        expect(catOnboarding.initialState(defaults: defaults, arguments: []) == .completed, "flag skips intro on next launch")
        expect(OnboardingGateState.needsOnboarding.needsOnboarding, "intro visible")
        expect(OnboardingGateState.entering.needsOnboarding, "entering keeps intro")
        expect(OnboardingGateState.failed("x").needsOnboarding, "failure keeps intro with error")
        expect(!OnboardingGateState.completed.needsOnboarding, "completed enters conversation")
        print("onboarding gate portable: ok")
    }
}
