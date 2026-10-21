import Foundation

@main struct SoundsTests {
    static func main() {
        newMoveDefaultsPreserveExistingPreferences()
        movePreferencesPersistIndependently()
        print("Пройдено 2 проверки настроек звука перемещения")
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

    private static func withDefaults(_ body: (UserDefaults, String) -> Void) {
        let suite = "HerdrTavern.SoundTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults, suite)
    }
}
