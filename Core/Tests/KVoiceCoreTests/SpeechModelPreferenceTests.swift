import Foundation
import Testing

@testable import KVoiceCore

@Suite("Speech model preference")
struct SpeechModelPreferenceTests {

    @Test("each choice maps to the priority-ordered array the API expects")
    func speechModelsPerChoice() {
        #expect(SpeechModelPreference.universal3Pro.speechModels == ["universal-3-5-pro"])
        #expect(
            SpeechModelPreference.universal3ProWithFallback.speechModels
                == ["universal-3-5-pro", "universal-2"]
        )
        #expect(SpeechModelPreference.universal2.speechModels == ["universal-2"])
    }

    @Test("every model named is one the API accepts")
    func onlyAllowedModels() {
        for preference in SpeechModelPreference.allCases {
            for model in preference.speechModels {
                #expect(AssemblyAIConstants.allowedSpeechModels.contains(model))
            }
        }
    }

    /// The reason the default has no fallback: naming `universal-2` behind
    /// `universal-3-5-pro` costs four fifths of the keyterm budget on *every*
    /// request, because either model might serve it.
    @Test("naming a fallback drops the keyterm budget to the lower model's")
    func fallbackCostsKeytermBudget() {
        #expect(
            SpeechModelPreference.universal3Pro.keytermWordBudget
                == AssemblyAIConstants.maxKeytermWordsUniversal3
        )
        #expect(
            SpeechModelPreference.universal3ProWithFallback.keytermWordBudget
                == AssemblyAIConstants.maxKeytermWordsUniversal2
        )
        #expect(
            SpeechModelPreference.universal2.keytermWordBudget
                == AssemblyAIConstants.maxKeytermWordsUniversal2
        )
        #expect(
            SpeechModelPreference.universal3Pro.keytermWordBudget
                > SpeechModelPreference.universal3ProWithFallback.keytermWordBudget
        )
    }

    @Test("the shipped default asks for 3.5 Pro alone")
    func defaultIsProOnly() {
        #expect(SpeechModelPreference.default == .universal3Pro)
        #expect(AssemblyAIConstants.defaultSpeechModels == ["universal-3-5-pro"])
    }

    @Test("raw values round-trip, so a stored preference survives a relaunch")
    func rawValueRoundTrip() {
        for preference in SpeechModelPreference.allCases {
            #expect(SpeechModelPreference(rawValue: preference.rawValue) == preference)
        }
    }

    @Test("every choice explains itself")
    func everyChoiceHasCopy() {
        for preference in SpeechModelPreference.allCases {
            #expect(!preference.displayName.isEmpty)
            #expect(!preference.explanation.isEmpty)
        }
    }
}

@Suite("Speech model preference: settings storage")
struct SpeechModelPreferenceSettingsTests {

    @Test("unset reads as the default")
    func unsetIsDefault() {
        let settings = SettingsStore.ephemeral()
        defer { settings.removeAll() }

        #expect(settings.speechModelPreference == .default)
    }

    @Test("a stored choice reads back, and reaches the snapshot a job is built with")
    func roundTripsThroughSnapshot() {
        let settings = SettingsStore.ephemeral()
        defer { settings.removeAll() }

        settings.speechModelPreference = .universal3ProWithFallback

        #expect(settings.speechModelPreference == .universal3ProWithFallback)
        #expect(settings.snapshot().speechModelPreference == .universal3ProWithFallback)
    }

    /// A hand-edited plist, or a value written by a future version that knows
    /// models this one does not, must not leave transcription asking for a model
    /// the API will reject.
    @Test("an unrecognized stored value degrades to the default")
    func unknownValueFallsBack() {
        let suite = "kvoice.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("universal-9-turbo", forKey: SettingsStore.Key.speechModelPreference)

        let settings = SettingsStore(defaults: defaults)
        defer { settings.removeAll() }

        #expect(settings.speechModelPreference == .default)
    }

    @Test("removeAll forgets the choice")
    func removeAllClearsIt() {
        let settings = SettingsStore.ephemeral()
        settings.speechModelPreference = .universal2
        settings.removeAll()

        #expect(settings.speechModelPreference == .default)
    }
}
