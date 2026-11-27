

<p align="center"> <img src="OpenLearn Icon.png" width="140" alt="OpenLearn logo"> </p> <h1 align="center">OpenLearn </h1> <p align="center">A free, native macOS study app. Bring your own Gemini key, no account and no paywall.</p>

The first local macOS AI study companion built with SwiftUI and a **Bring Your Own Key (BYOK)** architecture—giving students a clean study workspace with zero subscriptions and zero paywalls.

## What It Does

You add your own study material (notes, PDFs, photos, slides) and OpenLearn uses Google's Gemini AI to help you study it. Everything stays locally on your Mac.

| Feature | What it does | Status |
| :--- | :--- | :--- |
| **AI Chatbox** | Multi-turn chat that remembers the conversation, with automatic retries when Google is busy. | Working |
| **Threads & Subjects** | Every chat is saved as a thread. Group chats under subjects like Calculus or Biology. | Working |
| **Model Switcher** | Pick a Gemini model, or use **Auto** to switch to another one when a model is busy or unavailable. | Working |
| **Study Sets** | Add notes and files, generate AI flashcards, edit cards, and study with flip cards and *Got it / Still learning* tracking. | Beta |
| **File Import** | Import PDF, photos, Word (`.docx`), PowerPoint (`.pptx`), Excel (`.xlsx`), text, Markdown, CSV, and RTF. | Beta |
| **Study Plan** | Upload a syllabus, let the AI read your exam dates, and get a day-by-day plan with tick-off tasks. | Beta |
| **Welcome Animation** | Animated first-launch screen. | Works, not fully finished |
| **Math & Graphing** | Equation grapher. | Placeholder, not built yet |

> *Note: Pages, Keynote, and Numbers files cannot be read directly. Export them to PDF first.*

## Requirements

- **macOS** (14.0 Sonoma or later) — *Windows coming soon*
- **Xcode 15 or later** (required for building from source)
- A free **Gemini API key** from [Google AI Studio](https://aistudio.google.com/app/apikey)

## How to Build & Run OpenLearn

1. **Download & Open**
   - Download the source from the **Releases** page (or clone this repository).
   - Open `OpenLearn.xcodeproj` in **Xcode**.

2. **Select Destination & Run**
   - Choose **My Mac** as the destination in the top toolbar and press `Cmd + R`.
   - On first launch, enter your name and paste your Gemini API key. The app verifies the key with Google before letting you into the workspace.
   - *Note:* The project already includes the app icon, sandbox settings, and all source files, so no extra setup is required.

<details>
<summary>Building in your own new Xcode project instead</summary>

1. Create a new **macOS App** project (SwiftUI) and add all the `.swift` files and the `Assets.xcassets` folder from this repository. Delete the default `ContentView.swift` and app file Xcode generated so there is only one `@main`.
2. Select your target, open **Build Phases**, expand **Copy Bundle Resources**, and verify `Assets.xcassets` is listed.
3. Open **Build Settings** and set **Asset Catalog App Icon Set Name** to `AppIcon`.
4. Open **Signing & Capabilities**, then **App Sandbox**. Check **Outgoing Connections (Client)** and set **User Selected File** to **Read Only**.
5. Set the minimum deployment target to **macOS 14.0** and press `Cmd + R`.

</details>

## Troubleshooting

| Problem | Likely cause | Fix |
| :--- | :--- | :--- |
| **Network error `-1003`** | The sandbox is blocking outgoing connections. | Tick **Outgoing Connections (Client)** under **App Sandbox**, then clean the build (`Shift + Cmd + K`) and run again. |
| **"Google rejected this key"** | Typo, restricted key, or the API isn't enabled for it. | Create a new key in Google AI Studio and copy the full key with no spaces. |
| **503 or "servers are busy"** | Google's model is overloaded. | Wait a few minutes, or pick another model in the chat toolbar. **Auto** mode retries automatically. |
| **404 "model no longer available"** | Google retired a model. | Edit the model list at the top of `Geminiservice.swift`. |
| **File import fails** | Missing file permission, or a scanned/unsupported file. | Set **User Selected File** to **Read Only**. Export Pages, Keynote, and Numbers files to PDF first. |
| **Password prompts while developing** | Xcode re-signs the app on every build, so Keychain asks again. | Choose **Always Allow** and set a signing team. |
| **App shows a blank icon** | The icon isn't packaged into the app. | Make sure `Assets.xcassets` is in **Copy Bundle Resources** and **Asset Catalog App Icon Set Name** is set to `AppIcon`. |

## Privacy & Local-First Architecture

- **Zero Servers or Tracking:** OpenLearn has no server, user account, or analytics of its own.
- **Keychain Protection:** Your API key is stored securely in your Mac's Keychain and sent only to Google.
- **Direct Gemini API Calls:** When you chat, generate flashcards, read a syllabus, or build a study plan, the relevant text and files are sent directly to Google's Gemini API using your own key. Google's
