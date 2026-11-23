# OpenLearn (v1.0-beta)

The first local macOS AI study companion built with SwiftUI and a **Bring Your Own Key (BYOK)** architecture—giving students a clean study workspace with zero subscriptions and zero paywalls.

> **Status:** `v1.0-beta` — Early public preview. OpenLearn is currently only available on **macOS** while it is in beta, and it is not fully completed yet. It is published here so anyone who wants to test it out, find bugs, or share feedback can reach out and collaborate to improve it together.

## The Vision

The core idea behind OpenLearn is to let students upload and publish their own **PDFs and PowerPoints (PPTs)** into a local AI-powered study workspace to generate study materials, ask questions, and organize topics. Because this is still the `v1.0-beta` release, full document workflows and additional modules are still under active development.

## Current Features (v1.0-beta)

* **AI Chatbot:** Direct integration with Google's Gemini API using your personal API key.
* **Bring Your Own Key (BYOK) & Local-First:** Your profile, progress, and API key stay in local device storage (`@AppStorage`) and are never sent to third-party servers.

### Planned / Not Yet Available in v1.0-beta

* **PDF & PPT Publishing:** Uploading and studying directly from PDF and PowerPoint files.
* **Study Sets:** Local flashcard and topic folder organization.
* **Math & Graphing:** Interactive equation and slope-intercept graphing workspace.

## API Key Support

* **Currently Supported:** OpenLearn currently works exclusively with a **Google Gemini API key** (available for free via [Google AI Studio](https://aistudio.google.com/app/apikey)).
* **Coming Later:** Support for other AI providers and API keys will be added in future updates.

## Requirements

* **macOS** (14.0 Sonoma or later)
* **Xcode 15 or later** (required for building from source)
* A free **Gemini API key** from [Google AI Studio](https://aistudio.google.com/app/apikey)

## Getting Started (Building from Source)

1. Clone the repository:
   ```bash
   git clone [https://github.com/YOUR_USERNAME/OpenLearn.git](https://github.com/YOUR_USERNAME/OpenLearn.git)
