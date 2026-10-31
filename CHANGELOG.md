# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project
uses [Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-10-31

### Added
- Interactive whiptail wizard, with a plain-text fallback (`--text`)
- Drive detection that hides the system disk, with keep / format / erase-disk options
- Warning for FAT, exFAT and NTFS drives (iOS Files error -61)
- Persistent mount by UUID with `nofail` and a device timeout
- Mount-point lock (`chattr +i`) so files can't land on the microSD card
- Samba share with Apple / iOS compatibility (`catia fruit streams_xattr`)
- Backups, `testparm` validation and automatic rollback for config edits
- Re-runnable managed config blocks
- Health checks (`--verify`), dry-run mode (`--dry-run`), non-interactive mode (`--config`)

[1.0.0]: https://github.com/YOUR-USERNAME/pinas-setup/releases/tag/v1.0.0
