# Security Policy

## Supported versions

Only the latest release of Infinity Terminal receives security fixes. Update
from [Releases](https://github.com/bujna94/infinityTerminal/releases/latest)
or with `brew upgrade --cask infinity-terminal`.

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub's
[private vulnerability reporting](https://github.com/bujna94/infinityTerminal/security/advisories/new),
not in a public issue. Include the version, macOS version, and steps to
reproduce. You'll get a reply within a few days, and a fix will ship in the
next release with credit if you want it.

## Scope

Infinity Terminal is a terminal emulator: it runs your shell with your
privileges, without a sandbox, so a PTY works normally. Reports about the
app itself are in scope (for example escape sequences that execute
commands, leak data, or corrupt the clipboard). Behaviour of the programs you
run inside it is not.
