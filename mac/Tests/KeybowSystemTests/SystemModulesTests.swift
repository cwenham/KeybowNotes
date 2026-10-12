import CoreGraphics
import KeybowKit
@testable import KeybowSystem
import XCTest

// Made-up speakers, screens, radios and shortcuts: nothing on the Mac running
// the tests changes.

private final class FakeSound: SoundControl, @unchecked Sendable {
    var names: [SoundSide: String] = [.output: "Speakers", .input: "Microphone"]
    var volumes: [SoundSide: Double] = [.output: 0.5, .input: 0.8]
    var mutes: [SoundSide: Bool] = [.output: false, .input: false]
    var watching: [@Sendable () -> Void] = []

    func deviceName(_ side: SoundSide) -> String? { names[side] }
    func volume(_ side: SoundSide) -> Double? { volumes[side] }
    func setVolume(_ level: Double, _ side: SoundSide) throws {
        guard volumes[side] != nil else { throw ModuleError("no volume") }
        volumes[side] = level
    }
    func isMuted(_ side: SoundSide) -> Bool? { mutes[side] }
    func setMuted(_ muted: Bool, _ side: SoundSide) throws {
        guard mutes[side] != nil else { throw ModuleError("can't be muted") }
        mutes[side] = muted
        watching.forEach { $0() }
    }
    func watch(_ side: SoundSide, _ changed: @escaping @Sendable () -> Void) { watching.append(changed) }
}

private final class FakeBrightness: BrightnessControl, @unchecked Sendable {
    var levels: [CGDirectDisplayID: Double] = [:]
    func level(of display: DisplayInfo) throws -> Double {
        guard let level = levels[display.id] else { throw ModuleError("\(display.name)'s brightness can't be set from here") }
        return level
    }
    func setLevel(_ level: Double, of display: DisplayInfo) throws {
        guard levels[display.id] != nil else { throw ModuleError("\(display.name)'s brightness can't be set from here") }
        levels[display.id] = level
    }
}

private final class FakeRadios: RadioControl, @unchecked Sendable {
    var on: [Radio: Bool] = [.wifi: true, .bluetooth: true]
    var switched: [(Radio, Bool)] = []
    func isOn(_ radio: Radio) -> Bool? { on[radio] }
    func allow(_ radio: Radio) async throws {}
    func set(_ radio: Radio, on: Bool) async throws {
        self.on[radio] = on
        switched.append((radio, on))
    }
}

private final class FakeAppearance: AppearanceControl, @unchecked Sendable {
    var night = false
    var dark = true
    func nightShift() throws -> Bool { night }
    func setNightShift(_ on: Bool) throws { night = on }
    func isDark() -> Bool { dark }
    func setDark(_ dark: Bool) async throws { self.dark = dark }
}

private final class FakeBlocker: SleepBlocker, @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    var isHeld: Bool { lock.withLock { held } }
    func hold() { lock.withLock { held = true } }
    func release() { lock.withLock { held = false } }
}

private final class Ran: @unchecked Sendable {
    var shortcuts: [String] = []
}

private func request(_ type: String, _ fields: [String: String] = [:], leaf: String = "Key") -> ModuleRequest {
    ModuleRequest(type: type, fields: fields, labels: ["Branch", leaf])
}

final class VolumeModuleTests: XCTestCase {
    func testTheLabelSaysWhichWay() {
        let step = Adjustment.keyStep
        XCTAssertEqual(VolumeModule.labelled("Louder", step: step), .adjust(.up(by: step)))
        XCTAssertEqual(VolumeModule.labelled("Volume up", step: step), .adjust(.up(by: step)))
        XCTAssertEqual(VolumeModule.labelled("+", step: step), .adjust(.up(by: step)))
        XCTAssertEqual(VolumeModule.labelled("Quieter", step: step), .adjust(.down(by: step)))
        XCTAssertEqual(VolumeModule.labelled("−", step: step), .adjust(.down(by: step)))
        XCTAssertEqual(VolumeModule.labelled("Mute", step: step), .mute(.toggle), "as the Mute key does")
        XCTAssertEqual(VolumeModule.labelled("Unmute", step: step), .mute(.off))
        XCTAssertEqual(VolumeModule.labelled("40%", step: step), .adjust(.to(0.4)))
        XCTAssertEqual(VolumeModule.labelled("Half — 50 %", step: step), .adjust(.to(0.5)))
        XCTAssertNil(VolumeModule.labelled("Speakers", step: step))
    }

    func testFieldsWinAndMistakesAreSaid() {
        XCTAssertEqual(VolumeModule.command(request("volume", ["do": "mute"], leaf: "Louder")).0, .mute(.on))
        XCTAssertEqual(VolumeModule.command(request("volume", ["level": "30"], leaf: "Mute")).0, .adjust(.to(0.3)))
        XCTAssertEqual(VolumeModule.command(request("volume", ["step": "10"], leaf: "Up")).0, .adjust(.up(by: 0.1)))
        XCTAssertEqual(VolumeModule.command(request("volume", [:], leaf: "Speakers")).0, .mute(.toggle))
        let module = VolumeModule(sound: FakeSound())
        XCTAssertEqual(module.problem(with: request("volume", ["level": "loud"])), "“loud” isn't a volume: 0 to 100.")
        XCTAssertEqual(module.problem(with: request("volume", ["do": "shout"])),
                       "“shout” isn't something the volume does: up, down, mute, unmute or toggle.")
        XCTAssertNotNil(module.problem(with: request("volume", ["step": "0"], leaf: "Up")))
        XCTAssertTrue(module.firesAtOnce(request("volume")))
    }

    func testUpAndDownStepAndUnmute() async {
        let sound = FakeSound()
        sound.mutes[.output] = true
        let module = VolumeModule(sound: sound)
        let up = await module.run(request("volume", leaf: "Louder"), now: Date())
        XCTAssertEqual(up.message, "Volume 56%")
        XCTAssertEqual(up.detail, "Speakers")
        XCTAssertEqual(sound.volumes[.output]!, 0.5625, accuracy: 1e-9)
        XCTAssertEqual(sound.mutes[.output], false, "going up unmutes, as the keys do")

        sound.volumes[.output] = 0.02
        _ = await module.run(request("volume", leaf: "Quieter"), now: Date())
        XCTAssertEqual(sound.volumes[.output], 0, "never below nothing")
    }

    func testMuteToggles() async {
        let sound = FakeSound()
        let module = VolumeModule(sound: sound)
        XCTAssertEqual(module.summary(of: request("volume", leaf: "Mute"), now: Date()).verb, "Mute")
        let muted = await module.run(request("volume", leaf: "Mute"), now: Date())
        XCTAssertEqual(muted.message, "Sound muted")
        XCTAssertEqual(sound.mutes[.output], true)
        XCTAssertEqual(module.summary(of: request("volume", leaf: "Mute"), now: Date()).verb, "Unmute")
        let back = await module.run(request("volume", leaf: "Mute"), now: Date())
        XCTAssertEqual(back.message, "Sound on")
        XCTAssertEqual(back.detail, "Volume 50% · Speakers")
    }

    func testADeviceWithoutAVolumeSaysSo() async {
        let sound = FakeSound()
        sound.names[.output] = "LG TV"
        sound.volumes[.output] = nil
        sound.mutes[.output] = nil
        let module = VolumeModule(sound: sound)
        let up = await module.run(request("volume", leaf: "Up"), now: Date())
        XCTAssertFalse(up.succeeded)
        XCTAssertEqual(up.message, "LG TV has no volume to set")
        let mute = await module.run(request("volume", leaf: "Mute"), now: Date())
        XCTAssertEqual(mute.message, "LG TV can't be muted")
    }
}

final class MicrophoneModuleTests: XCTestCase {
    func testMutingShowsAndLightsTheKey() async {
        let sound = FakeSound()
        let module = MicrophoneModule(sound: sound)
        module.start(host: MemoryModuleHost())
        XCTAssertNil(module.status(now: Date()))
        XCTAssertEqual(module.summary(of: request("microphone", leaf: "Mic"), now: Date()).verb, "Mute")

        let muted = await module.run(request("microphone", leaf: "Mic"), now: Date())
        XCTAssertEqual(muted.message, "Microphone muted")
        XCTAssertEqual(sound.mutes[.input], true)
        let status = module.status(now: Date())
        XCTAssertEqual(status?.text, "muted")
        XCTAssertEqual(status?.lightsKeys, true)
        XCTAssertEqual(module.menuItems(now: Date()).first?.title, "Unmute")

        let unmuted = await module.run(request("microphone", leaf: "Unmute"), now: Date())
        XCTAssertEqual(unmuted.message, "Microphone on")
        XCTAssertNil(module.status(now: Date()))
        // Unmute only unmutes.
        _ = await module.run(request("microphone", leaf: "Unmute"), now: Date())
        XCTAssertEqual(sound.mutes[.input], false)
    }

    func testOneThatCantBeMutedIsTurnedDownAndBackUp() async {
        let sound = FakeSound()
        sound.mutes[.input] = nil
        sound.volumes[.input] = 0.6
        let host = MemoryModuleHost()
        let module = MicrophoneModule(sound: sound)
        module.start(host: host)
        _ = await module.run(request("microphone", ["do": "mute"]), now: Date())
        XCTAssertEqual(sound.volumes[.input], 0)
        XCTAssertEqual(module.status(now: Date())?.text, "muted")

        // The level it was at outlives a restart.
        let again = MicrophoneModule(sound: sound)
        again.start(host: host)
        _ = await again.run(request("microphone", ["do": "unmute"]), now: Date())
        XCTAssertEqual(sound.volumes[.input], 0.6)
    }

    func testNoMicrophone() async {
        let sound = FakeSound()
        sound.names[.input] = nil
        let outcome = await MicrophoneModule(sound: sound).run(request("microphone"), now: Date())
        XCTAssertEqual(outcome.message, "There's no microphone")
        XCTAssertEqual(MicrophoneModule(sound: sound).problem(with: request("microphone", ["do": "shush"])),
                       "“shush” isn't something the microphone does: toggle, mute or unmute.")
    }
}

final class BrightnessModuleTests: XCTestCase {
    // Left to right: an HDMI monitor stood on end, the built-in screen, an iMac lent as a screen.
    private let side = DisplayInfo(id: 3, name: "Side Monitor", frame: CGRect(x: -1080, y: 0, width: 1080, height: 1920), isBuiltIn: false)
    private let builtIn = DisplayInfo(id: 1, name: "iMac", frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), isBuiltIn: true)
    private let lent = DisplayInfo(id: 2, name: "iMac", frame: CGRect(x: 2560, y: 0, width: 2560, height: 1440), isBuiltIn: false)
    private var all: [DisplayInfo] { [builtIn, lent, side] }

    func testWhichScreens() throws {
        let pointer = CGPoint(x: 3000, y: 500)
        XCTAssertEqual(try BrightnessModule.chosen(nil, among: all, pointer: pointer), [lent], "the pointer's")
        XCTAssertEqual(try BrightnessModule.chosen("all", among: all, pointer: pointer), [side, builtIn, lent], "from the left")
        XCTAssertEqual(try BrightnessModule.chosen("Built-in", among: all, pointer: pointer), [builtIn])
        XCTAssertEqual(try BrightnessModule.chosen("main", among: all, pointer: pointer), [builtIn])
        XCTAssertEqual(try BrightnessModule.chosen("1", among: all, pointer: pointer), [side])
        XCTAssertEqual(try BrightnessModule.chosen("Side", among: all, pointer: pointer), [side])
        XCTAssertThrowsError(try BrightnessModule.chosen("4", among: all, pointer: pointer))
        XCTAssertThrowsError(try BrightnessModule.chosen("built-in", among: [lent], pointer: pointer))
    }

    func testTheLabelSaysWhichWay() {
        XCTAssertEqual(BrightnessModule.adjustment(request("brightness", leaf: "Brighter")).0, .up(by: Adjustment.keyStep))
        XCTAssertEqual(BrightnessModule.adjustment(request("brightness", leaf: "Dim")).0, .down(by: Adjustment.keyStep))
        XCTAssertEqual(BrightnessModule.adjustment(request("brightness", leaf: "Evening 30%")).0, .to(0.3))
        XCTAssertEqual(BrightnessModule.adjustment(request("brightness", ["do": "down", "step": "25"])).0, .down(by: 0.25))
        XCTAssertNotNil(BrightnessModule.adjustment(request("brightness", leaf: "Screen")).problem)
    }

    func testEachScreenSetAndThoseThatCantBeSaid() async {
        let control = FakeBrightness()
        control.levels = [1: 0.5, 2: 0.9]
        let module = BrightnessModule(control: control, screens: { [all] in (all, CGPoint(x: 100, y: 100)) })
        let one = await module.run(request("brightness", leaf: "Brighter"), now: Date())
        XCTAssertEqual(one.message, "Brightness 56%")
        XCTAssertEqual(one.detail, "iMac")

        let every = await module.run(request("brightness", ["screen": "all"], leaf: "Brighter"), now: Date())
        XCTAssertTrue(every.succeeded)
        XCTAssertEqual(every.message, "Brightness up")
        XCTAssertEqual(every.detail, "iMac 63% · iMac 96% — Side Monitor's brightness can't be set from here")
        XCTAssertEqual(control.levels[2], 0.9625)

        let none = await module.run(request("brightness", ["screen": "1"], leaf: "Brighter"), now: Date())
        XCTAssertFalse(none.succeeded)
        XCTAssertEqual(none.message, "Side Monitor's brightness can't be set from here")
    }

    func testDDCMessages() {
        XCTAssertEqual(DDC.readRequest(DDC.brightness), [0x51, 0x82, 0x01, 0x10, 0xAC])
        XCTAssertEqual(DDC.writeRequest(DDC.brightness, value: 50), [0x51, 0x84, 0x03, 0x10, 0x00, 0x32, 0x9A])
        // As a monitor answered: 48 of 100.
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x30, 0xF0]
        XCTAssertEqual(DDC.reading(reply, for: DDC.brightness)?.value, 48)
        XCTAssertEqual(DDC.reading(reply, for: DDC.brightness)?.maximum, 100)
        XCTAssertNil(DDC.reading(reply, for: 0x12), "about another control")
        var garbled = reply
        garbled[9] = 0x31
        XCTAssertNil(DDC.reading(garbled, for: DDC.brightness), "a bad checksum")
        XCTAssertNil(DDC.reading([0x6E, 0x80, 0xBE] + Array(repeating: 0, count: 8), for: DDC.brightness), "nothing to say yet")
        // An iMac lent as a screen answers anything with ones.
        XCTAssertNil(DDC.reading([0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xA4], for: DDC.brightness))
    }
}

final class RadioModuleTests: XCTestCase {
    func testToggleOnOffAndTheLabel() async {
        let radios = FakeRadios()
        let module = RadioModule(radios: radios)
        XCTAssertFalse(module.firesAtOnce(request("wifi")), "keeps the time to cancel")
        XCTAssertEqual(module.summary(of: request("wifi", leaf: "Wi‑Fi"), now: Date()).verb, "Turn off")

        let off = await module.run(request("wifi", leaf: "Wi‑Fi"), now: Date())
        XCTAssertEqual(off.message, "Wi‑Fi off")
        XCTAssertEqual(radios.on[.wifi], false)
        let on = await module.run(request("wifi", leaf: "Wi‑Fi on"), now: Date())
        XCTAssertEqual(on.message, "Wi‑Fi on")
        let again = await module.run(request("wifi", ["do": "on"]), now: Date())
        XCTAssertEqual(again.detail, "It already was")
        XCTAssertEqual(radios.switched.count, 2, "on when it's on does nothing")
    }

    func testBluetoothOffWarns() async {
        let radios = FakeRadios()
        let module = RadioModule(radios: radios)
        XCTAssertEqual(module.summary(of: request("bluetooth", leaf: "Bluetooth"), now: Date()).details,
                       ["Bluetooth keyboards and mice disconnect"])
        let off = await module.run(request("bluetooth", leaf: "Bluetooth"), now: Date())
        XCTAssertEqual(off.message, "Bluetooth off")
        XCTAssertEqual(off.detail, "Its keyboards, mice and headphones are disconnected until it's back on")
        XCTAssertEqual(module.problem(with: request("bluetooth", ["do": "maybe"])),
                       "“maybe” isn't something Bluetooth does: toggle, on or off.")
    }

    func testSwitchWords() {
        XCTAssertEqual(Switch(words: "Turn off Wi‑Fi"), .off)
        XCTAssertEqual(Switch(words: "Bluetooth on"), .on)
        XCTAssertEqual(Switch(words: "Toggle"), .toggle)
        XCTAssertNil(Switch(words: "Night Shift"))
        XCTAssertNil(Switch(words: "Stay awake"))
    }
}

final class AppearanceModuleTests: XCTestCase {
    func testDarkModeAndNightShift() async {
        let control = FakeAppearance()
        let module = AppearanceModule(control: control)
        XCTAssertEqual(module.summary(of: request("darkMode", leaf: "Dark mode"), now: Date()).subject, "light mode")
        let light = await module.run(request("darkMode", leaf: "Dark mode"), now: Date())
        XCTAssertTrue(light.isQuiet, "what it did is on the screen")
        XCTAssertFalse(control.dark)
        _ = await module.run(request("darkMode", leaf: "Light"), now: Date())
        XCTAssertFalse(control.dark, "Light is light, not a toggle")
        _ = await module.run(request("darkMode", ["do": "dark"]), now: Date())
        XCTAssertTrue(control.dark)

        let night = await module.run(request("nightShift", leaf: "Night Shift"), now: Date())
        XCTAssertEqual(night.message, "Night Shift on")
        XCTAssertTrue(control.night)
        let off = await module.run(request("nightShift", leaf: "Night Shift off"), now: Date())
        XCTAssertEqual(off.message, "Night Shift off")
    }

    func testNightShiftStatus() {
        // As CoreBrightness gave it, Night Shift off: active, then enabled.
        XCTAssertFalse(SystemAppearance.isEnabled([0x01, 0x00, 0x01, 0x81, 0, 0, 0, 0, 0x16]))
        XCTAssertTrue(SystemAppearance.isEnabled([0x01, 0x01, 0x01, 0x81]))
    }
}

final class StayAwakeModuleTests: XCTestCase {
    func testToggledWithAndWithoutATime() async {
        let blocker = FakeBlocker()
        let module = StayAwakeModule(blocker: blocker)
        module.start(host: MemoryModuleHost())
        let now = Date()

        let on = await module.run(request("stayAwake", leaf: "Stay awake"), now: now)
        XCTAssertEqual(on.message, "Staying awake")
        XCTAssertEqual(on.detail, "Until it's turned off")
        XCTAssertTrue(blocker.isHeld)
        XCTAssertEqual(module.status(now: now)?.text, "on")
        XCTAssertEqual(module.status(now: now)?.lightsKeys, true)

        let off = await module.run(request("stayAwake", leaf: "Stay awake"), now: now)
        XCTAssertEqual(off.message, "The Mac can sleep again")
        XCTAssertFalse(blocker.isHeld)
        XCTAssertNil(module.status(now: now))

        XCTAssertEqual(module.summary(of: request("stayAwake", ["duration": "45m"]), now: now).details, ["for 45 min"])
        _ = await module.run(request("stayAwake", leaf: "1 hour"), now: now)
        XCTAssertEqual(module.status(now: now)?.text.hasPrefix("until "), true, "the label's length")
    }

    func testATimeRunsOut() async {
        let blocker = FakeBlocker()
        let module = StayAwakeModule(blocker: blocker)
        module.start(host: MemoryModuleHost())
        _ = await module.run(request("stayAwake", ["duration": "1s"]), now: Date())
        XCTAssertTrue(blocker.isHeld)
        XCTAssertTrue(module.status(now: Date())?.text.hasPrefix("until") == true)
        for _ in 0..<40 where blocker.isHeld { try? await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertFalse(blocker.isHeld)
        XCTAssertNil(module.status(now: Date()))
    }

    func testItCarriesOnThroughARestartUnlessItsTimeIsUp() async {
        let host = MemoryModuleHost()
        let first = StayAwakeModule(blocker: FakeBlocker())
        first.start(host: host)
        _ = await first.run(request("stayAwake", ["duration": "2h"]), now: Date())

        let blocker = FakeBlocker()
        StayAwakeModule(blocker: blocker).start(host: host)
        XCTAssertTrue(blocker.isHeld)

        let past = Date().addingTimeInterval(-3 * 3600)
        _ = await first.run(request("stayAwake", ["do": "on", "duration": "1h"]), now: past)
        let late = FakeBlocker()
        StayAwakeModule(blocker: late).start(host: host)
        XCTAssertFalse(late.isHeld, "its hour ended while the app was closed")
    }

    func testMistakes() {
        let module = StayAwakeModule(blocker: FakeBlocker())
        XCTAssertEqual(module.problem(with: request("stayAwake", ["duration": "a while"])),
                       "“a while” isn't a length or a time: 30m, 1h 30m, 16:30.")
    }
}

final class FocusModuleTests: XCTestCase {
    func testItRunsTheShortcutOrSaysHowToMakeIt() async {
        let ran = Ran()
        let module = FocusModule(shortcuts: { ["KeybowNotes Sleep Focus"] }, run: { ran.shortcuts.append($0) })
        let sleep = await module.run(request("focus", leaf: "Bedtime"), now: Date())
        XCTAssertEqual(sleep.message, "Sleep Focus switched")
        XCTAssertEqual(ran.shortcuts, ["KeybowNotes Sleep Focus"])

        let work = await module.run(request("focus", ["name": "Work"], leaf: "Work"), now: Date())
        XCTAssertFalse(work.succeeded)
        XCTAssertEqual(work.message, "Set up the “KeybowNotes Work Focus” shortcut first")
        XCTAssertEqual(work.detail, "In Shortcuts, make a shortcut called “KeybowNotes Work Focus”: Get Current Focus; "
                       + "then If Current Focus is Work, Set Focus to turn Work off; Otherwise, Set Focus to turn Work on "
                       + "until turned off.")
        XCTAssertEqual(ran.shortcuts.count, 1)

        let own = await module.run(request("focus", ["shortcut": "KeybowNotes Sleep Focus", "name": "Bedtime"]), now: Date())
        XCTAssertEqual(own.message, "Bedtime Focus switched")
    }

    /// Until the shortcut's made, the key shows how, and Open Shortcuts copies
    /// its name and opens the app.
    func testOpenShortcutsCopiesTheName() async {
        let opened = Ran()
        let host = MemoryModuleHost()
        host.displayResult = .ok
        let module = FocusModule(shortcuts: { [] }, run: { _ in }, open: { opened.shortcuts.append("Shortcuts"); return true })
        module.start(host: host)

        let outcome = await module.run(request("focus", leaf: "Bedtime"), now: Date())
        XCTAssertEqual(outcome.message, "Copied “KeybowNotes Sleep Focus”")
        XCTAssertEqual(host.copied, ["KeybowNotes Sleep Focus"])
        XCTAssertEqual(opened.shortcuts, ["Shortcuts"])
        let shown = host.displayed.first
        XCTAssertEqual(shown?.okTitle, "Open Shortcuts")
        XCTAssertEqual(shown?.buttons, [.cancel, .ok])
        guard case .markdown(let page)? = shown?.content else { return XCTFail("shown as Markdown") }
        XCTAssertTrue(page.contains("Make a new shortcut called **KeybowNotes Sleep Focus**, with:"), page)
        XCTAssertTrue(page.contains("**If** Current Focus is Sleep: **Set Focus**, turning Sleep off"), page)

        host.displayResult = .cancel
        let cancelled = await module.run(request("focus", leaf: "Bedtime"), now: Date())
        XCTAssertTrue(cancelled.isQuiet)
        XCTAssertEqual(host.copied.count, 1, "Cancel copies nothing")
        XCTAssertEqual(opened.shortcuts.count, 1)
    }
}

final class SystemKeywordsTests: XCTestCase {
    func testTheKeywordsCompile() {
        for module: KeybowModule in [VolumeModule(sound: FakeSound()), MicrophoneModule(sound: FakeSound()),
                                     BrightnessModule(control: FakeBrightness()), RadioModule(radios: FakeRadios()),
                                     AppearanceModule(control: FakeAppearance()), StayAwakeModule(blocker: FakeBlocker()),
                                     FocusModule(shortcuts: { [] }, run: { _ in })] {
            ModuleRegistry.shared.register(module, host: MemoryModuleHost())
        }
        let (document, _) = OutlineParser.parse("""
            # row 2
            1. Sound
               1. Louder [Volume]
               2. Mic [Mic]
            2. Screen
               1. Brighter [Brightness, screen: all]
               2. Night [Night Shift]
               3. Dark [Dark Mode]
            3. Radio
               1. Wi‑Fi [Wi-Fi]
               2. Bluetooth [Bluetooth, do: on]
            4. Other
               1. Awake [Stay Awake, duration: 1h]
               2. Bedtime [Focus]
            """)
        let json = OutlineCompiler.compile(document, locateApp: { _ in nil }).json
        for type in ["volume", "microphone", "brightness", "wifi", "bluetooth", "nightShift", "darkMode", "stayAwake", "focus"] {
            XCTAssertTrue(json.contains(#""type": "\#(type)""#), "\(type) in \(json)")
        }
        XCTAssertTrue(json.contains(#""screen": "all""#), json)
        XCTAssertTrue(json.contains(#""duration": "1h""#), json)
    }
}
