# OpenLearn (v1.1-beta)

The first local macOS AI study companion built with SwiftUI and a **Bring Your Own Key (BYOK)** architecture—giving students a clean study workspace with zero subscriptions and zero paywalls.

> **Status:** `v1.1-beta` — Early public preview. OpenLearn is currently available on **macOS** while in beta (**Windows support is planned / coming soon!**). Because it is still in active development, it is not yet a fully finished product—expect incomplete features, placeholder tabs, and ongoing updates. It is published here so anyone who wants to test it out, find bugs, or share feedback can reach out and collaborate to improve it together.

## The Vision

The core idea behind OpenLearn is to let students upload and publish their own **PDFs and PowerPoints (PPTs)** into a local AI-powered study workspace to generate study materials, ask questions, and organize topics. Because this is still the `v1.1-beta` release, full document workflows and additional modules are still under active development.

## Current Features (v1.1-beta)

- **AI Chatbox with Threads & Subjects:** Direct integration with Google's Gemini API using your personal API key, complete with multi-thread chat history and custom subject folders saved locally on your Mac.
- **PDF & PowerPoint (PPT) Uploads:** Import and study directly from your own PDF documents and PowerPoint slide decks inside the workspace.
- **Study Sets:** Create and organize local study sets and flashcards directly on your Mac.
- **Bring Your Own Key (BYOK) & Local-First:** Your profile, API key, study sets, and chat history stay in local device storage (`@AppStorage` and local JSON) and are never sent to third-party servers.

### Planned / Not Yet Available in v1.1-beta

- **Windows Version:** Cross-platform support for Windows (coming soon).
- **Math & Graphing:** Interactive equation and slope-intercept graphing workspace.
- **Animations & Transitions:** Smoother, more polished SwiftUI animations across views.
- **Official Logo & Visual Redesign:** Custom app icon, branding, and refined UI design.
- **And Many More:** Additional study tools, workflow improvements, and community-requested features coming soon.

## API Key Support

- **Currently Supported:** OpenLearn currently works exclusively with a **Google Gemini API key** (available for free via [Google AI Studio](https://aistudio.google.com/app/apikey)).
- **Coming Later:** Support for other AI providers and API keys will be added in future updates.

## Requirements

- **macOS** (14.0 Sonoma or later) — *Windows coming soon*
- **Xcode 15 or later** (required for building from source)
- A free **Gemini API key** from [Google AI Studio](https://aistudio.google.com/app/apikey)

## How to Build & Run OpenLearn

1. **Download & Unzip**
   * Download the latest `v1.1-beta` `.zip` file from the **Releases** page (or clone the repository) and double-click to decompress the folder.

2. **Create a New Project & Add Files**
   * Open **Xcode**, create a **New Xcode Project**, select **App**, and name it `OpenLearn`.
   * Drag and drop the unzipped source code files and folders directly into your new project's file navigator area in Xcode.

3. **Enable Network Access for Gemini (Required)**
   * In the left-hand **Project Navigator** sidebar, click the **blue Xcode project icon** at the very top (`OpenLearn v1`) to open your project settings.
   * Select your app under **TARGETS** and click the **Signing & Capabilities** tab at the top.
   * Scroll down to the **App Sandbox** section and check the box for **Outgoing Connections (Client)**.
   * *Why this matters:* Without **Outgoing Connections (Client)** enabled, macOS blocks the app from reaching Google's servers with your API key and you will get a network error.

4. **Build & Run**
   * Make sure **My Mac** is selected as the destination in the top toolbar, then press `Cmd + R` to build and launch OpenLearn.



