# Gapiring for iOS and macOS

Uzbek text-to-speech on the device. The Gapiring Edge model ships inside the package: no network, no account, no key.

The model, the other platforms (Python, JavaScript, Android) and audio examples:
https://huggingface.co/islomov/gapi-uz-gapiring-v1

- iOS 15.1 or later, macOS 14 or later on Apple silicon
- Swift 5.9 or later (tested with Xcode 26.5)
- 24 kHz mono audio, streamed as it is made

## Installation

In Xcode: **File → Add Package Dependencies…**, enter `https://github.com/Islomov49/gapiring-ios`, choose version
`0.1.2` or later and add the `Gapiring` library to your app target.

In a `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Islomov49/gapiring-ios.git", from: "0.1.2"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "Gapiring", package: "gapiring-ios")]),
]
```

ONNX Runtime comes as a 35 MB zip attached to the release; Swift Package Manager downloads it and checks its checksum.

## Usage

```swift
import Gapiring

let tts = try Gapiring()                                        // off the main thread
tts.play("Assalomu alaykum! Namuna kompaniyasining virtual yordamchisiman, sizga qanday yordam bera olaman?", voice: "f1", role: "assistant", manner: "warm")

try tts.stream("Bugun obunani rasmiylashtirsangiz, birinchi oy uchun to'liq ellik foiz chegirma beriladi, imkoniyatni qo'ldan boy bermang.", voice: "m1", role: "operator", manner: "calm") { chunk in   // [Float], 24 kHz mono
    return true                                                 // false stops the line
}
let audio = try tts.speak("Kechasi o'g'limning isitmasi chiqqanda shifokoringiz tez yetib kelib yordam berdi, klinika jamoasiga ming rahmat, baraka topinglar!", voice: "f1", role: "emotional", manner: "grateful")
```

- `Gapiring(threads: 2)` loads the model. Create it once, off the main thread, and keep it.
- `play` returns at once and speaks through the device's audio output; a new call waits for the line before it, and
  `stop()` drops what is playing and what waits. `completion:` gets the error, if any.
- `stream` calls you with chunks as they are made (the first after about 80 ms of speech); return `false` to stop.
  `speak` returns the whole line. Both block the calling thread.
- `seed:` (default 1) makes a line come out the same every time.
- An instance speaks one line at a time: do not call `stream` or `speak` while `play` is speaking.
- `Gapiring(modelDirectory:)` loads a model folder from disk instead of the one in the package.

## Voices, roles and manners

Voices: `f1`, `m1`.

Each role speaks in its own manners (`Speech.roleManners`):

| Role | Manners |
|---|---|
| `operator` | neutral, warm, cheerful, empathetic, calm, dictation, persuasive, brisk |
| `assistant` | neutral, warm, cheerful, empathetic, calm, dictation, soothing |
| `emotional` | angry, upset, irritated, worried, tired, sceptical, confused, hurried, joking, grateful, curious, friendly, calm, elderly |

Sounds inside the text: `[laugh]`, `[sigh]`, `[pause]`, `[breath]`. Write numbers as words.

## Example app

`Example/GapiringDemo` is a one-screen iPhone app: it plays the three lines above and measures the model's load time,
the time to the first audio, the real-time factor and memory. Open `GapiringDemo.xcodeproj`, choose your team under
Signing & Capabilities and run it on a phone.

## Size and privacy

- The package adds about 150 MB to an app: the model (113 MB) and ONNX Runtime with the Swift code (36 MB in the
  example app's binary).
- It makes no network requests. ONNX Runtime's own usage telemetry, on by default in Microsoft's builds, is turned off
  by the package before ONNX Runtime starts.

## Tests

`swift test` on a Mac runs everything, the model included: the random generator, the text front and the token ids on
146 reference lines, ONNX Runtime's telemetry switch, and three spoken lines written to WAV files in the temporary
folder.

## ONNX Runtime

The package uses ONNX Runtime 1.30.0 by Microsoft (MIT: `Frameworks/onnxruntime-LICENSE.txt`,
`Frameworks/onnxruntime-ThirdPartyNotices.txt`), taken from Microsoft's signed NuGet package
`Microsoft.ML.OnnxRuntime`: the iOS device and simulator and the macOS libraries, Apple silicon only.
`scripts/make_onnxruntime.py` checks the package's hash and Microsoft's signature, then writes
`Frameworks/onnxruntime.xcframework` and `dist/onnxruntime.xcframework.zip` with its checksum. To build against that
local copy instead of the release's zip:

```sh
python3 scripts/make_onnxruntime.py
GAPIRING_LOCAL_ONNXRUNTIME=1 swift test
```

## License

The code is MIT; the model files and voices are CC BY 4.0. See `LICENSE`, including the credit to give.
