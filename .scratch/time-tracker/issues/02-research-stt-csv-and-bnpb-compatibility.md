# Research STT CSV and BNPB Compatibility

Type: research
Status: resolved
Blocked by: none

## Question

What are the exact schema columns, date/time formatting rules, quoting rules, and tag delimiters required for 100% drop-in CSV export compatibility with both Simple Time Tracker and BNPB's `TimeTrackerParser` (including `w/` name markers and `Contact` tags), and how can the app perform continuous live export without file corruption or race conditions?

## Answer

Comprehensive research has been concluded and documented in [`02-stt-csv-and-bnpb-compatibility.md`](../research/02-stt-csv-and-bnpb-compatibility.md).

### Summary of Decisions & Findings:

1. **Exact CSV Schema & Header (8 Columns)**:
   - Header string: `activity name,time started,time ended,comment,categories,record tags,duration,duration minutes` (lowercase, comma-separated, newline-terminated).
   - Column order:
     0. `activity name` (quoted)
     1. `time started` (unquoted)
     2. `time ended` (unquoted)
     3. `comment` (quoted)
     4. `categories` (quoted)
     5. `record tags` (quoted)
     6. `duration` (unquoted)
     7. `duration minutes` (unquoted)
   - BNPB fatal check: `activity name`, `time started`, and `record tags` are strictly required. Missing any one causes BNPB to abort parsing and return an empty list.

2. **Quoting, Escaping & Delimiters**:
   - Quoting: `activity name`, `comment`, `categories`, and `record tags` are enclosed in double quotes (`"..."`). Timestamps and durations are unquoted.
   - Quote escaping: RFC 4180 standard double-quote escaping (`replace("\"", "\"\"")`).
   - Multiple tags / categories: Joined by comma-space (`", "`), e.g. `"Contact, FollowUp"`. Empty tag fields are output as `""`.
   - Durations: `duration` uses unpadded `$hr:$min:$sec` (e.g. `0:19:9`, `1:0:0`), while `duration minutes` is the total elapsed whole minutes as an integer string (`durationMs / 60000`).

3. **Timestamps & BNPB Deduplication Fingerprint**:
   - Timestamp format: Strict `yyyy-MM-dd HH:mm:ss` (US locale, local device wall-clock time, no timezone offset).
   - BNPB deduplication fingerprint: `sha256('$timeStartedStr|${durationMinutes ?? ''}|$activityName|$comment')`. Exact byte-for-byte formatting stability is required across export runs to prevent duplicate candidate interactions from staging in BNPB.

4. **Tag Filtering & Name Marker Integration (ADR-0005)**:
   - Ingestion filter: BNPB strictly filters rows where `record tags.toLowerCase().contains('contact')`. Non-contact rows are ignored.
   - Two-tier name extraction:
     - *Tier 1 (Marker-Respected)*: Prefixes `w/` and `with ` (with word boundary guard `(?=\s|$)`) extract text after the marker. Bare first names, full names, and nicknames are accepted. Prefixes before the marker are preserved in the summary title (e.g., `Dinner - Boba`).
     - *Tier 2 (Fallback)*: Comments without markers require a strong name signature (full name, first+last, or nickname); bare first names alone are rejected to avoid false matches. Unmatched rows default to `selected: false` in staging triage.

5. **Atomic Continuous Live Export Architecture**:
   - File naming and path: Default target is `stt_records_automatic.csv` in the Google Drive `Time track` folder (matching BNPB's automated sync prefix).
   - Atomic Write-Flush-Rename:
     1. Write full export to sibling temporary file `.stt_records_automatic.csv.tmp.<uuid>` on the same filesystem/mount point.
     2. Force physical disk sync via `fsync()` / `force(true)`.
     3. Atomically replace target using POSIX `rename()` / `Files.move(..., ATOMIC_MOVE, REPLACE_EXISTING)`. This completely eliminates partial reads, zero-byte windows, or corruption by concurrent readers (Google Drive sync daemon, BNPB).
   - Concurrency & Debounce: Background single-threaded mutex queue with a 1,000ms trailing-edge debounce on record mutations (`STOP`, `EDIT`, `DELETE`).

See the full specification and citations in [`02-stt-csv-and-bnpb-compatibility.md`](../research/02-stt-csv-and-bnpb-compatibility.md).
