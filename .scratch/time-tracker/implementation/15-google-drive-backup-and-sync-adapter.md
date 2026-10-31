# 15: Google Drive Backup and Sync Adapter

Status: ready
Phase: 5 - Mobile & Sync
Dependencies: 01, 03

## Scope
Implement private, user-controlled Google Drive backup and continuous export synchronization matching `attd` and `bnpb` conventions.

## Deliverables
- Google Drive API client using `drive.file` / `drive.appdata` scope.
- Automated push of `stt_records_automatic.csv` to Google Drive `Time track` folder for BNPB pickup.
- Encrypted or raw SQLite snapshot backup and manual restore capability.
