---
name: arch_linux
description: Arch Linux system integration and packaging standards
---

# Arch Linux Development Skill

This skill provides guidelines and standards for developing software on Arch Linux, focusing on system integration, packaging, and respecting the Arch philosophy.

## Core operating principles

### Arch Linux System awareness

- **Rolling Release**: Always consider Arch Linux's rolling release model. Dependencies are always at their latest stable versions.
- **Package Ecosystem**: Prefer system libraries via `pacman` and `yay` when appropriate (e.g., `openssl`, `sqlite`, `systemd`).
- **Filesystem Hierarchy**: Respect the Arch filesystem hierarchy standard.
    - System binaries: `/usr/bin/`
    - User binaries: `~/.local/bin/`
    - System configuration: `/etc/`
    - User configuration: `~/.config/`
- **ABI Stability**: Handle `glibc` version compatibility and ABI stability, awareness that unrelated system updates might upgrade shared libraries.

### Arch Linux integration

- **Systemd**: If the application requires a background service, generate user-level (`~/.config/systemd/user/`) or system-level unit files explicitly.
    - **Type=notify**: For applications that support systemd readiness notification (use `sd-notify` crate in Rust).
    - **Type=simple**: For services that do not require notification.
- **Dependencies**: Provide the corresponding Arch Linux package name (e.g., `pacman -S openssl`) alongside language-specific dependencies.

#### Example of systemd unit

```ini
[Unit]
Description=My Service
After=network.target

[Service]
Type=notify
ExecStart=/usr/bin/my-service
User=my-service-user
Group=my-service-group
NotifyAccess=all
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

## Packaging

- **PKGBUILD**: This is the primary distribution method for Arch (AUR).
- **Naming**: Follow Arch package naming guidelines (e.g., `-bin` for precompiled, `-git` for latest commit).
- **Verification**: Use `namcap` to verify PKGBUILDs if available.
