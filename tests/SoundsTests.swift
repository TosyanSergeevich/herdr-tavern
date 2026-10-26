import Foundation

@main struct SoundsTests {
    static func main() {
        newMoveDefaultsPreserveExistingPreferences()
        movePreferencesPersistIndependently()
        normalizedPreferencesPersistWithoutChangingResources()
        print("Пройдено 3 проверки настроек звука")
    }

    static func newMoveDefaultsPreserveExistingPreferences() {
        withDefaults { defaults, suite in
            let prefix = "HerdrTavern.sounds.v1."
            let filename = "tavern-sound-\(UUID().uuidString).wav"
            defaults.set(false, forKey: prefix + "enabled")
            defaults.set(0.23, forKey: prefix + "volume")
            defaults.set(["enabled": false, "volume": 0.61,
                          "customFilename": filename, "customDisplayName": "Мой клик.wav"],
                         forKey: prefix + "event.interfaceClick")
            defaults.set("сохранить", forKey: "unrelated.preference")
            let before = defaults.persistentDomain(forName: suite)!

            let settings = TavernSoundSettings(defaults: defaults)
            precondition(!settings.enabled && settings.volume == 0.23,
                         "Новое событие не включает общий выключатель и не меняет громкость")
            let click = settings.choice(for: .interfaceClick)
            precondition(!click.enabled && click.volume == 0.61)
            precondition(click.customFilename == filename && click.customDisplayName == "Мой клик.wav")
            precondition(NSDictionary(dictionary: before).isEqual(
                to: defaults.persistentDomain(forName: suite)!),
                "Чтение новых defaults не должно перезаписывать существующие предпочтения")
        }
    }

    static func movePreferencesPersistIndependently() {
        withDefaults { defaults, suite in
            let settings = TavernSoundSettings(defaults: defaults)
            settings.setEnabled(false, for: .interfaceMove)
            settings.setVolume(0.42, for: .interfaceMove)

            let restored = TavernSoundSettings(defaults: defaults)
            precondition(!restored.choice(for: .interfaceMove).enabled)
            precondition(restored.choice(for: .interfaceMove).volume == 0.42)
            precondition(Set(defaults.persistentDomain(forName: suite)!.keys)
                         == ["HerdrTavern.sounds.v1.event.interfaceMove"],
                         "Настройка перемещения должна сохраняться отдельно от остальных звуков")
        }
    }

    static func normalizedPreferencesPersistWithoutChangingResources() {
        withDefaults { defaults, _ in
            let settings = TavernSoundSettings(defaults: defaults)
            let initial = settings.resource(for: .interfaceMove)
            settings.volume = 2
            settings.setVolume(-1, for: .interfaceMove)
            settings.setEnabled(false, for: .interfaceMove)
            precondition(settings.volume == 1)
            precondition(settings.choice(for: .interfaceMove).volume == 0)
            precondition(settings.resource(for: .interfaceMove) == initial,
                         "Громкость и enabled не меняют revision источника")
            settings.volume = .nan
            settings.setVolume(.infinity, for: .interfaceMove)
            let restored = TavernSoundSettings(defaults: defaults)
            precondition(restored.volume == 0.5)
            precondition(restored.choice(for: .interfaceMove).volume
                         == TavernSoundEvent.interfaceMove.defaultVolume)
            precondition(!restored.choice(for: .interfaceMove).enabled)
        }
    }

    private static func withDefaults(_ body: (UserDefaults, String) -> Void) {
        let suite = "HerdrTavern.SoundTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults, suite)
    }
}
