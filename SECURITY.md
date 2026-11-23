# Security Policy

## Supported Versions

OpenLearn is currently in early beta (`v1.0-beta`) with active development underway for `v1.1-beta`. Security updates and bug fixes are applied to the active release and the upcoming development branch.

| Version | Status | Supported |
| ------- | ------ | ------------------ |
| v1.1-beta | In Development | :white_check_mark: |
| v1.0-beta | Current Release | :white_check_mark: |

## Privacy & API Key Architecture

OpenLearn follows a local-first, **Bring Your Own Key (BYOK)** design:
* **Local Storage:** Your Google Gemini API key and profile preferences are stored locally on your Mac (via `@AppStorage` / Keychain) and are never transmitted to any third-party backend servers.
* **Direct API Calls:** All AI requests go directly from your machine to Google's Gemini API (`generativelanguage.googleapis.com`) using macOS App Sandbox **Outgoing Connections (Client)**.
* **Never Commit Keys:** Contributors must never hardcode personal API keys or credentials into pull requests or commits.

## Reporting a Vulnerability

If you discover a security issue (such as API key exposure, unsafe local storage handling, or sandbox permission flaws), **please do not open a public GitHub Issue**.

Instead, report it privately using one of the following methods:
1. **GitHub Private Vulnerability Reporting:** Go to the **Security** tab of this repository and click **Report a vulnerability**.
2. **Direct Contact:** Reach out directly to the maintainer via email (`brightaction24x@gmail.com`) or message me on discord with username (`a._24._`) with the subject line `[OpenLearn Security]`.

### What to Include in Your Report
* A clear summary of the vulnerability and its potential impact.
* Step-by-step instructions to reproduce the issue.
* Your macOS and Xcode versions, plus which version (`v1.0-beta` or `v1.1-beta (still in testing)`) you tested.

### Response Timeline
* **Acknowledgment:** You will receive a reply confirming receipt within **48–72 hours**.
* **Updates & Fixes:** Once reproduced and verified, a fix will be prioritized for `v1.0-beta` and backported if needed, and you will be notified once the patch is live.
