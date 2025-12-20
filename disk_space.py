import csv
import smtplib
from email.message import EmailMessage
from pathlib import Path

import wmi
SERVER_LIST_PATH = Path("servers.txt")
OUTPUT_PATH = Path("disk_space_report.csv")

SMTP_SERVER = "smtp.example.com"
SMTP_PORT = 25
MAIL_FROM = "disk-report@example.com"
MAIL_TO = ["ops@example.com"]
MAIL_SUBJECT = "Disk Space Report"


def load_servers(path: Path) -> list[str]:
    # Read one server name per line, ignore blanks.
    return [line.strip() for line in path.read_text().splitlines() if line.strip()]


def run_wmi(server: str) -> list[dict]:
    # Query remote disks using WMI (requires the `wmi` Python package).
    conn = wmi.WMI(computer=server)
    rows: list[dict] = []
    for disk in conn.Win32_LogicalDisk(DriveType=3):
        size = int(disk.Size or 0)
        free = int(disk.FreeSpace or 0)
        size_gb = round(size / 1_073_741_824, 2) if size else 0
        free_gb = round(free / 1_073_741_824, 2) if free else 0
        free_pct = round((free / size) * 100, 1) if size else 0
        rows.append(
            {
                "Server": server,
                "Drive": disk.DeviceID,
                "SizeGB": size_gb,
                "FreeGB": free_gb,
                "FreePct": free_pct,
            }
        )
    return rows


def write_csv(rows: list[dict], path: Path) -> None:
    # Write results to CSV in a stable column order.
    fieldnames = ["Server", "Drive", "SizeGB", "FreeGB", "FreePct"]
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow({k: row.get(k, "") for k in fieldnames})


def send_email(attachment: Path) -> None:
    # Send the report file as an email attachment.
    msg = EmailMessage()
    msg["From"] = MAIL_FROM
    msg["To"] = ", ".join(MAIL_TO)
    msg["Subject"] = MAIL_SUBJECT
    msg.set_content("Disk space report attached.")
    msg.add_attachment(
        attachment.read_bytes(),
        maintype="text",
        subtype="csv",
        filename=attachment.name,
    )

    with smtplib.SMTP(SMTP_SERVER, SMTP_PORT) as smtp:
        smtp.send_message(msg)


def main() -> None:
    servers = load_servers(SERVER_LIST_PATH)
    if not servers:
        raise SystemExit(f"No servers found in {SERVER_LIST_PATH}")

    all_rows: list[dict] = []
    for server in servers:
        try:
            all_rows.extend(run_wmi(server))
        except Exception as exc:
            print(f"Warning: failed to query {server}: {exc}")

    all_rows.sort(key=lambda r: (r.get("Server", ""), r.get("Drive", "")))
    write_csv(all_rows, OUTPUT_PATH)
    send_email(OUTPUT_PATH)
    print(f"Report written to {OUTPUT_PATH}")


if __name__ == "__main__":
    main()
