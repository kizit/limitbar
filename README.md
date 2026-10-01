# LimitBar

A small macOS menu bar app for your Codex 5-hour and weekly usage allowances.

LimitBar uses the Codex helper already installed on your Mac. Sign in to Codex with your own ChatGPT account; LimitBar follows that local sign-in. Open **Account & Sign-In** in the menu for setup help. The app does not request, store, or transmit your password or access token. To change accounts, switch the active account in Codex and refresh LimitBar.

Click the menu bar item to see remaining allowances, reset times, and refresh controls. The app refreshes every three minutes and after waking from sleep. Missing or expired data is shown as unavailable rather than as a full allowance.

## Requirements

- macOS 13 or later
- Apple Silicon Mac
- Codex or ChatGPT for macOS installed and signed in
- Xcode Command Line Tools to build from source

## Build

```sh
./build.sh
./LimitBar.app/Contents/MacOS/LimitBar --self-test
./LimitBar.app/Contents/MacOS/LimitBar --check
```

The build creates an ad-hoc signed `LimitBar.app` locally. It is not notarized for distribution. `--self-test` checks usage parsing without connecting. `--check` reads usage from the active Codex sign-in and prints the remaining percentages.

Move `LimitBar.app` to Applications, open it, and enable **Launch at Login** from the menu if you want it to start automatically. macOS may ask you to approve it in Login Items.

## Privacy and credentials

The app does not contain account names, passwords, API keys, or copied authentication tokens. For each refresh it starts the installed Codex app-server, requests usage through `account/rateLimits/read`, then closes the helper. Authentication remains managed by the user's Codex installation. Refreshes do not start model conversations.

## Source

- Swift menu bar app: `Source/main.swift`
- Build script: `build.sh`
- Usage interface: [Codex app-server rate limits](https://learn.chatgpt.com/docs/app-server#6-rate-limits-chatgpt)
