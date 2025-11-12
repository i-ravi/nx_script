# Bulk Root Password Reset Script

This Bash script automates the process of resetting the root password across multiple AHV servers using SSH. It attempts to log in using a list of candidate passwords and updates the root password if authentication succeeds.

---

## Features

- Reads a list of IP addresses from a file
- Tries multiple current passwords for each host
- Changes the root password remotely via SSH
- Logs success and failure per host
- Generates summary reports

---

## Usage

```bash
./password_reset.sh --ip-file <file> --current-passwords <pass1> [pass2...] --new-password <password>
```

### Arguments

| Flag | Description |
|------|-------------|
| `--ip-file` | Path to a file containing one IP address per line |
| `--current-passwords` | One or more possible current root passwords |
| `--new-password` | The new root password to set |

---

## Output Files

- `password_reset.log`: Detailed log of all operations
- `successful_ips.txt`: List of IPs where password reset succeeded
- `failed_ips.txt`: List of IPs where login or password change failed

---

## Requirements

- **sshpass**: Required for non-interactive SSH authentication

Install `sshpass` if not available

---

## Example

```bash
./password_reset.sh \
  --ip-file servers.txt \
  --current-passwords oldpass1 oldpass2 \
  --new-password NewSecurePass123
```

---

## 🛠 Troubleshooting

- **IP file not found**: Ensure the path to the IP file is correct.
- **sshpass not installed**: Install it using your package manager.
- **Permission denied**: Check SSH access and root credentials.
- **Password change fails**: Target system may not support `passwd --stdin`.
