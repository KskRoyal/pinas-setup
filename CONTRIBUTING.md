# Contributing

Thanks for helping improve PiNAS Setup!

## Reporting bugs

Open an issue using the **Bug report** form and include:

- Raspberry Pi model and OS version (`cat /etc/os-release`)
- What you chose in the wizard and what happened
- The log: `/var/log/pinas-setup.log` (remove anything private first)
- The output of `lsblk -o NAME,SIZE,FSTYPE,TRAN,MODEL` if it's drive-related

## Pull requests

1. Fork the repo and create a branch from `main`.
2. Keep the script a single self-contained Bash file with no extra dependencies.
3. Check your changes before pushing:
   ```bash
   bash -n pinas-setup.sh
   shellcheck -S warning pinas-setup.sh
   ```
4. Test on a real Pi with `--dry-run` first, then a full run on a spare drive.
5. Add a line to `CHANGELOG.md` under an `Unreleased` heading.

Anything that could touch a disk must stay behind the review screen and the `ERASE`
confirmation.
