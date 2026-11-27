# Installation

[← Repository home](https://github.com/jftuga/mac-screen-search)

## Requirements

- macOS (uses ScreenCaptureKit, Vision, and CoreGraphics)
- Screen Recording permission (for screenshot mode)
- Swift compiler (only needed if compiling from source; otherwise install via [Homebrew](#homebrew) or download a [release](https://github.com/jftuga/mac-screen-search/releases))

## Homebrew

```sh
brew tap jftuga/tap
brew install jftuga/tap/mac-screen-search
```

To upgrade to a newer version:

```sh
brew update
brew upgrade mac-screen-search
```

## Manual download

Download the macOS arm64 binary from the [releases page](https://github.com/jftuga/mac-screen-search/releases):

```sh
tar -xJf mac-screen-search_v*.tar.xz
cd mac-screen-search_v*/
sudo cp mac-screen-search /usr/local/bin/
```

## Building

```sh
swiftc -o mac-screen-search mac-screen-search.swift
```
