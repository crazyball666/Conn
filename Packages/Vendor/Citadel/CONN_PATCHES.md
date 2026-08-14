# Conn Citadel fork

This directory is a source-controlled fork of Citadel `0.12.1` at revision
`ae8562f895de06ccb86fdb1cbb65fd99c8976e12`.

Conn adds one deliberately small public seam in `TTY.swift`:

- `SSHClient.withProcess(_:terminal:environment:perform:)` sends an optional PTY
  request followed by an SSH `exec` request.
- It never sends `ShellRequest`, so machine protocols such as tmux Control Mode
  cannot accidentally enter a login shell.

`ConnSSHCitadel` adapts that seam to `ConnSSH.RemoteProcessChannel`. Keep this
fork pinned and review upstream changes to Citadel's TTY child-channel lifecycle
before rebasing it.
