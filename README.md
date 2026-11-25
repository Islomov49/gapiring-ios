# Gapiring for iOS and macOS

Uzbek text-to-speech on the device. The Gapiring Edge v2 model ships inside the package: no network, no account, no key.

The model, the other platforms (Python, JavaScript, Android) and audio examples:
https://huggingface.co/islomov/gapi-uz-gapiring-v1

- iOS 15.1 or later, macOS 14 or later on Apple silicon
- Swift 5.9 or later (tested with Xcode 26.5)
- 24 kHz mono audio, streamed as it is made

## Installation

In Xcode: **File → Add Package Dependencies…**, enter `https://github.com/Islomov49/gapiring-ios`, choose version
`0.2.0` or later and add the `Gapiring` library to your app target.

In a `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Islomov49/gapiring-ios.git", from: "0.2.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "Gapiring", package: "gapiring-ios")]),
]
```

ONNX Runtime comes as a 35 MB zip attached to the 0.1.2 release; Swift Package Manager downloads it and checks its checksum.

## Usage

```swift
import Gapiring

let tts = try Gapiring()                                        // off the main thread
tts.play("Assalomu alaykum! Namuna kompaniyasining virtual yordamchisiman, sizga qanday yordam bera olaman?", voice: "f1", role: "assistant", manner: "warm")

try tts.stream("Bugun obunani rasmiylashtirsangiz, birinchi oy uchun to'liq ellik foiz chegirma beriladi, imkoniyatni qo'ldan boy bermang.", voice: "m1", role: "operator", manner: "calm") { chunk in   // [Float], 24 kHz mono
    return true                                                 // false stops the line
}
let audio = try tts.speak("Kechasi o'g'limning isitmasi chiqqanda shifokoringiz tez yetib kelib yordam berdi, klinika jamoasiga ming rahmat, baraka topinglar!", voice: "f1", role: "emotional", manner: "grateful")

let news = try tts.speak("Bugun erta tongda ikkita qishloqni bog'lovchi yangi ko'prik foydalanishga topshirildi.", voice: "m1", role: "narrator", manner: "news", pace: "fast")
```

- `Gapiring(threads: 2)` loads the model. Create it once, off the main thread, and keep it.
- `play` returns at once and speaks through the device's audio output; a new call waits for the line before it, and
  `stop()` drops what is playing and what waits. `completion:` gets the error, if any.
- `stream` calls you with chunks as they are made (the first after about 80 ms of speech); return `false` to stop.
  `speak` returns the whole line. Both block the calling thread.
- `seed:` (default 1) makes a line come out the same every time.
- A text of any length is spoken piece by piece (`Speech.splitText`: sentences, up to 150 characters a piece, 280 for
  the narrator) with `pause:` seconds of silence between the pieces (default 0.25), and the apostrophes phone keyboards
  type (`ʻ`, `ʼ`, `’` and others) are read as the plain `'`.
- English words, brands and abbreviations are read as they are written (eSIM, Google Lens, check-in): there is no
  dictionary in between.
- An instance speaks one line at a time: do not call `stream` or `speak` while `play` is speaking.
- `Gapiring(modelDirectory:)` loads a model folder from disk instead of the one in the package.

## Voices, roles and manners

Voices: `f1`, `m1`.

Each role speaks in its own manners (`Speech.roleManners`). The manner may be left out: the narrator then reads a
book, every other role is neutral.

| Role | Manners |
|---|---|
| `operator` | neutral, warm, cheerful, empathetic, calm, dictation, persuasive, brisk, serious |
| `assistant` | neutral, warm, cheerful, empathetic, calm, dictation, soothing, serious |
| `assistant_formal` | neutral, warm, cheerful, empathetic, calm, dictation, soothing, serious |
| `narrator` | book, article, news, tale (the genre) |
| `emotional` | angry, upset, irritated, worried, tired, sceptical, confused, hurried, joking, grateful, curious, friendly, calm, elderly |

`assistant` is a lively helper with a person's intonation; since 0.2 it speaks fluently, and `hesitant: true` gives it
the little hesitations of live speech it had in 0.1. `assistant_formal` is the same helper in an even, measured
delivery: choose it for announcements, voice menus, instructions, long texts, and wherever every take should sound the
same. `narrator` reads longer texts: a book, an article, the news, a tale.

One mark at a time may be added to a line (`stream`, `speak`, `play`, `tokens`, `Speech.tags`); a combination outside
this table, or two marks at once, throws before any audio is made:

| Mark | With |
|---|---|
| `pace: "slow"` or `"fast"` | `operator` with neutral, warm, cheerful, calm, persuasive; `assistant` and `assistant_formal` with neutral, warm, cheerful, calm; `narrator`: slow with article, fast with news (`Speech.paceManners`) |
| `serious: true` | `narrator` with article or news (for the other roles serious is a manner) |
| `hesitant: true` | `assistant` with every manner but serious |

Sounds inside the text: `[laugh]`, `[sigh]`, `[pause]`, `[breath]`. Write numbers as words.

## From 0.1

Code written for 0.1 runs on 0.2 unchanged: the four roles of 0.1 with all their manners, the same parameter labels in
the same order, the manner given or left out. The new parameters (`pace`, `serious`, `hesitant`) come after `pause`.
What sounds different is the model: `assistant` speaks fluently now (`hesitant: true` is how it spoke in 0.1), and
English words are read as written.

## Example app

`Example/GapiringDemo` is a one-screen iPhone app: it plays the three lines above and a longer text, and measures the
model's load time, the time to the first audio, the real-time factor and memory. Open `GapiringDemo.xcodeproj`, choose your team under
Signing & Capabilities and run it on a phone.

## Performance

On an iPhone 14 Pro Max (A16, iOS 27.0.1), with 2 threads, in the example app's Release build, the phone's thermal
state "fair" (measured with 0.1.2; Edge v2 has the same architecture):

| | |
|---|---|
| Model load | 0.23–0.38 s |
| First audio | 30–75 ms |
| Real-time factor | 0.13–0.16: 6–8 s of speech in 0.85–1.2 s |
| Memory | about 195 MB once loaded, 250 MB at the peak |

## Size and privacy

- The package adds about 150 MB to an app: the model (113 MB) and ONNX Runtime with the Swift code (36 MB in the
  example app's binary).
- It makes no network requests. ONNX Runtime's own usage telemetry, on by default in Microsoft's builds, is turned off
  by the package before ONNX Runtime starts (network activity checked on a Mac and in the iOS simulator).

## Tests

`swift test` on a Mac (or `xcodebuild test` in the iOS simulator) runs everything, the model included: the random
generator; the symbols, the text front and the token ids of 368 reference lines; the pieces of 165 reference texts;
the combinations that must throw; the 36 role and manner pairs of 0.1 and its call forms; ONNX Runtime's telemetry
switch; and the reference lines (narrator, English words, three paces, hesitant, a dictated number), a long text and
the two assistant roles spoken to WAV files in the temporary folder.

## Model

The model folder is `Sources/Gapiring/Model`. Another take of it, or of its graphs alone, under the same file names, goes
in with one command; then run the tests:

```sh
python3 scripts/replace_model.py gapiring-edge-v2-model.zip --sha256 <hash>
swift test
```

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
