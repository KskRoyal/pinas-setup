# Security policy

Please don't open a public issue for security problems. Report them privately using
GitHub's **Report a vulnerability** button on the repository's **Security** tab.

Security notes for users:

- The script creates a password-protected share; guest access is disabled.
- Never forward SMB ports 445 or 139 on your router. Use Tailscale or another VPN for
  remote access.
- The Samba password is passed to `smbpasswd` through stdin and is never written to the log.
