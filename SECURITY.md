# Security

## What this plugin can do

- **Reads** battery readings from `/sys/class/power_supply/BAT*` (no privileges).
- **Runs** `asusctl battery info` and `asusctl battery limit <20-100>` as your user.
  The value is validated as a whole number before it is passed, as a separate argument, never through a shell string.
- **Asks for root once**, only when you click **Install asusctl**: `pkexec` runs a fixed command,
  `pacman -S --needed --noconfirm asusctl && systemctl start asusd.service`. Nothing else runs as root.
- **No network access**, no background downloads, no telemetry. All displayed text is plain text.

## Reporting a vulnerability

Please use GitHub's **Report a vulnerability** button on this repository's Security tab
(private vulnerability reporting) rather than opening a public issue.
