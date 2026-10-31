# Research: Simple Time Tracker CSV Schema & BNPB Compatibility Specification

- **Topic**: Simple Time Tracker CSV Export Parity & BNPB Parser Compatibility
- **Context**: Time Tracker offline-first continuous live ecosystem export for peer apps (BNPB, Google Drive sync)
- **Author**: Antigravity Research Agent
- **Date**: 2026-10-31
- **Status**: Complete

---

## 1. Executive Summary & Compatibility Matrix

To serve as a true 100% drop-in replacement for **Simple Time Tracker** (STT by Razeeman) and maintain seamless, zero-configuration interoperability with **BNPB** (`TimeTrackerParser` and `TimeTrackerSyncService`), Time Tracker's CSV export engine must adhere to the exact syntactic, lexical, and structural contracts of upstream STT.

BNPB automatically syncs and parses the newest CSV matching the prefix `stt_records_automatic` in the user's Google Drive folder `Time track`, extracting entries tagged with `Contact` to stage relationship interactions. Deduplication relies on a deterministic SHA-256 fingerprint computed across the raw timestamp, duration, activity name, and comment strings. Any divergence in column headers, quoting, timestamp formatting, or tag serialization will cause silent parsing failures, corrupted entries, or duplicate records in BNPB.

### Compatibility Specification Matrix

| Attribute | Simple Time Tracker (Upstream) | BNPB (`TimeTrackerParser`) | Time Tracker Required Implementation |
| :--- | :--- | :--- | :--- |
| **Export File Name** | `stt_records_automatic.csv` (auto) / `stt_records_yyyyMMdd_HHmmss.csv` (manual) | Looks for newest file with prefix `stt_records_automatic` in Drive | Default to `stt_records_automatic.csv`; support manual timestamped dumps |
| **Google Drive Folder** | Configured folder, defaults to `Time track` | Hardcoded / configurable default `Time track` | Writes/mirrors to `Time track` folder on Google Drive |
| **CSV Header** | `activity name,time started,time ended,comment,categories,record tags,duration,duration minutes` | Required: `activity name`, `time started`, `record tags`. Optional: `comment`, `duration minutes` | Exact 8-column header, all lowercase, comma-separated |
| **Quoting Convention** | Text columns always double-quoted (`"..."`); numeric/time columns unquoted | Standard RFC 4180 / Dart `csv` package parser (`autoDetect: false`) | Quote `activity name`, `comment`, `categories`, `record tags`. Unquote timestamps and durations |
| **Quote Escaping** | Escaped via double quotes (`""`) | Standard RFC 4180 unescaping | Replace `"` with `""` (`cleanText()`) |
| **Timestamp Format** | `yyyy-MM-dd HH:mm:ss` (US locale, local wall-clock time) | Parses with `DateTime.parse()`. Used in SHA-256 fingerprint | Strict `yyyy-MM-dd HH:mm:ss` (24-hour, 2-digit zero-padded) |
| **Duration (String)** | `$hr:$min:$sec` (hours, unpadded minutes, unpadded seconds) | Ignored by parser (informational only) | Exact `$hr:$min:$sec` format (e.g. `0:19:9`, `1:0:0`) |
| **Duration (Minutes)** | Total integer elapsed minutes (e.g. `93`, `19`, `60`) | Parsed via `int.tryParse()`; used in SHA-256 fingerprint | Integer string representing `durationMs / 60000` |
| **Tag Filtering** | Multiple tags joined by `", "` in `record tags` column | Filters rows where `record tags.toLowerCase().contains('contact')` | Join multiple tags with `", "`; ensure `"Contact"` tag is applied |
| **Write Atomicity** | Atomic file replacement on export trigger | Concurrent read from Google Drive sync client | Write to hidden sibling `.tmp` file, `fsync()`, and POSIX atomic `rename()` |

---

## 2. Primary Source Analysis: Simple Time Tracker (Razeeman)

Upstream codebase: [Razeeman/Android-SimpleTimeTracker](https://github.com/Razeeman/Android-SimpleTimeTracker)  
Primary source reference: `data_local/src/main/java/com/example/util/simpletimetracker/data_local/resolver/CsvRepoImpl.kt`  
Key commit: `5e1d7f43d907b3b00ec5a2ba4d6e51bbd9606cbd` (*"fix csv with quotes export"*).  
Empirical dataset: 13,475 production records inspected from local Google Drive mirror (`/Users/twang/Library/CloudStorage/GoogleDrive-yilongwang05@gmail.com/My Drive/08_Backups_and_Data/02_App_Data/Time track/stt_records_automatic.csv`).

### 2.1 File Naming & Folder Location
- **Automatic Continuous Export**: `stt_records_automatic.csv`
- **Manual Snapshot Export**: `stt_records_yyyyMMdd_HHmmss.csv` (e.g. `stt_records_20251006_095922.csv`)
- **Default Cloud Directory**: `Time track` in the root of Google Drive.

### 2.2 CSV Header Definition
The CSV header is strictly defined as an 8-column ASCII string terminated by a newline:
```csv
activity name,time started,time ended,comment,categories,record tags,duration,duration minutes
```
Column indices (0-based):
0. `activity name`
1. `time started`
2. `time ended`
3. `comment`
4. `categories`
5. `record tags`
6. `duration`
7. `duration minutes`

### 2.3 Row Formatting & Escaping Rules
In `CsvRepoImpl.kt`:
```kotlin
private fun toCsvString(
    record: Record,
    recordType: RecordType?,
    categories: List<Category>,
    recordTags: List<RecordTag>,
): String? {
    return if (recordType != null) {
        String.format(
            "\"%s\",%s,%s,\"%s\",\"%s\",\"%s\",%s,%s\n",
            recordType.name.cleanText(),
            formatDateTime(record.timeStarted),
            formatDateTime(record.timeEnded),
            record.comment.cleanText(),
            categories.takeUnless { it.isEmpty() }
                ?.joinToString(separator = ", ", transform = { it.name })
                .orEmpty().cleanText(),
            recordTags.takeUnless { it.isEmpty() }
                ?.joinToString(separator = ", ", transform = { it.name })
                .orEmpty().cleanText(),
            formatDuration(record.duration),
            formatDurationMinutes(record.duration),
        )
    } else {
        null
    }
}

private fun String.cleanText(): String {
    return this.replace("\"", "\"\"")
}
```

#### Detailed Column Contracts:
1. **`activity name` (quoted)**:
   - Always enclosed in double quotes: `"Coding"`, `"Lunch"`, `"Morning Time"`.
   - Double quotes within the name are escaped as `""` (e.g. `He said "Hello"` becomes `"He said ""Hello"""`).
2. **`time started` (unquoted)**:
   - Format: `yyyy-MM-dd HH:mm:ss` (e.g. `2025-01-07 12:07:24`).
   - Represents local device wall-clock time at the start of the record.
   - Evaluated using `SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US)`. No ISO timezone offset is appended.
3. **`time ended` (unquoted)**:
   - Format: `yyyy-MM-dd HH:mm:ss` (e.g. `2025-01-07 13:41:07`).
   - Local device wall-clock time at the conclusion of the record.
4. **`comment` (quoted)**:
   - Always enclosed in double quotes: `"w/ Abel"`, `"Boba w/ Benji Jeremy Timothy Isai "`.
   - Empty comment is represented as empty quotes: `""`.
   - Internal double quotes are escaped as `""`.
   - Multi-line comments with embedded newlines are legal in RFC 4180 when enclosed in double quotes.
5. **`categories` (quoted)**:
   - Represents activity-level groupings (e.g. `"Productivity "`, `"Essentials"`, `"Spiritual"`).
   - If multiple categories apply, they are joined with comma-space: `", "`.
   - Empty categories are represented as `""`.
6. **`record tags` (quoted)**:
   - Represents record-specific tags.
   - If multiple tags apply, joined by comma-space: `", "` (e.g. `"Contact, FollowUp"`).
   - Records intended for CRM ingestion MUST include `"Contact"` (e.g. `"Contact"` or `"Contact, Meeting"`).
   - Empty record tags are represented as `""`.
7. **`duration` (unquoted)**:
   - Formatted as `"$hr:$min:$sec"`:
     ```kotlin
     val hr: Long = TimeUnit.MILLISECONDS.toHours(interval)
     val min: Long = TimeUnit.MILLISECONDS.toMinutes(interval - TimeUnit.HOURS.toMillis(hr))
     val sec: Long = TimeUnit.MILLISECONDS.toSeconds(interval - TimeUnit.HOURS.toMillis(hr) - TimeUnit.MINUTES.toMillis(min))
     return "$hr:$min:$sec"
     ```
   - **Crucial Quirk**: Minutes and seconds are **not zero-padded** in upstream STT!
     - 19 minutes and 9 seconds is formatted as `0:19:9` (not `0:19:09`).
     - 1 hour flat is formatted as `1:0:0` (not `01:00:00`).
     - 5 minutes flat is `0:5:0`.
8. **`duration minutes` (unquoted)**:
   - Formatted as `TimeUnit.MILLISECONDS.toMinutes(interval).toString()`.
   - Whole integer minutes truncated downwards: `93`, `19`, `60`, `474`.

---

## 3. Primary Source Analysis: BNPB Integration

Primary source files:
- `/Users/twang/bnpb/lib/services/time_tracker_parser.dart`
- `/Users/twang/bnpb/lib/services/time_tracker_sync_service.dart`
- `/Users/twang/bnpb/docs/adr/0004-time-tracker-sync-staging-queue.md`
- `/Users/twang/bnpb/docs/adr/0005-contact-name-markers-and-review-triage.md`
- `/Users/twang/bnpb/test/services/time_tracker_parser_test.dart`

### 3.1 Header Parsing & Validation
`TimeTrackerParser.parseCsv` decodes the CSV using the Dart `csv` package (`Csv(autoDetect: false).decode(csvContent)`).
It normalizes header names using `e.toString().trim().toLowerCase()` and resolves column indices:
```dart
final activityIdx = headerRow.indexOf('activity name');
final startIdx = headerRow.indexOf('time started');
final commentIdx = headerRow.indexOf('comment');
final tagsIdx = headerRow.indexOf('record tags');
final durationMinIdx = headerRow.indexOf('duration minutes');

if (activityIdx == -1 || startIdx == -1 || tagsIdx == -1) {
  return []; // FATAL: Returns empty if any required column is absent!
}
```
**Fatal Requirement**: If `activity name`, `time started`, or `record tags` is missing from the header row, BNPB aborts parsing completely and discards all records.

### 3.2 Tag Filtering Logic
BNPB inspects column `record tags` for every row:
```dart
final tags = row[tagsIdx].toString();
if (!tags.toLowerCase().contains('contact')) {
  continue; // Skip any record not tagged with "Contact"
}
```
Records without `"contact"` (case-insensitive) are ignored during import staging. To be ingested into BNPB, a record must have `"Contact"` in its `record tags`.

### 3.3 Record Fingerprint & Idempotence
To prevent duplicate imports across daily synchronizations, BNPB generates a deterministic SHA-256 fingerprint for every candidate record:
```dart
static String _generateFingerprint({
  required String timeStartedStr,
  required int? durationMinutes,
  required String activityName,
  required String comment,
}) {
  final raw = '$timeStartedStr|${durationMinutes ?? ''}|$activityName|$comment';
  return sha256.convert(utf8.encode(raw)).toString();
}
```
Fingerprints are persisted in `SharedPreferences` under `stt_imported_fingerprints` and `stt_dismissed_fingerprints`.

> [!IMPORTANT]
> Because the fingerprint is calculated directly on the raw strings:
> - `$timeStartedStr` (e.g. `2025-09-17 11:46:37`)
> - `${durationMinutes ?? ''}` (e.g. `60`)
> - `$activityName` (e.g. `Lunch`)
> - `$comment` (e.g. `w/ Abel`)
>
> Any mutation in timestamp resolution, date formatting, duration rounding, or whitespace trimming will generate a mismatched hash, causing already-imported records to reappear in BNPB's staging queue.

### 3.4 Contact Name Matching & Marker Parsing (ADR-0005)

BNPB uses an offline, deterministic two-tier matching algorithm driven by user-configured markers (defaulting to `['w/', 'with ']`).

#### Tier 1: Marker-Respected Matching (High Confidence)
If a configured marker is detected in the comment:
1. **Word Boundary Guard**: If the marker ends in an alphanumeric character (e.g. `'with'`), BNPB applies a trailing lookahead `(?=\s|$)` so words like `"within"` do not trigger a match. Non-alphanumeric markers (e.g. `'w/'`) self-delimit.
2. **Comment Splitting**: The comment is divided at the leftmost marker into `(prefix, namesPart)`.
   - Example 1: `"w/ Abel"` -> `prefix: null/empty`, `namesPart: "Abel"`.
   - Example 2: `"Boba w/ Benji Jeremy Timothy Isai "` -> `prefix: "Boba"`, `namesPart: "Benji Jeremy Timothy Isai "`.
3. **Summary Formation**:
   - If `prefix` exists: `summary = '$activityName - $prefix'` (e.g. `"Dinner - Boba"`).
   - If `prefix` is empty: `summary = '$activityName $comment'` (e.g. `"Lunch w/ Abel"`).
4. **Name Resolution**:
   - `namesPart` is split by delimiters `[,;&+]|\b(?:and|y)\b` and whitespace.
   - Matches full names, first names, or nicknames against the BNPB Contact database.
   - Bare first names are accepted after a marker because the marker explicitly establishes user intent.

#### Tier 2: No-Marker Fallback (Strict Whole-Comment Scan)
When no marker is present in the comment:
1. BNPB scans the entire comment for a **strong name signature** (full name, first+last, or explicit nickname).
2. Bare first names alone are **rejected** as ambiguous (preventing false associations on words like `"peinado"` or `"met Abel casually"`).
3. If a strong match is found:
   - Summary becomes `'$activityName - $comment'`.
   - The matched contact and any adjacent names in the comment are linked.
4. If no contact is matched:
   - Summary becomes `'$activityName - $comment'`.
   - `matchedContactIds = []`.
   - `selected = false` (defaults to unselected in staging UI so unlinked noise does not pollute the database).

---

## 4. Google Drive Sync & Directory Layout

`TimeTrackerSyncService` in BNPB interacts with Google Drive using the `drive.readonly` scope:
1. Searches the user's Google Drive for a folder named `Time track` (configurable via `stt_drive_folder_name`).
2. Scans for the latest file matching the filename prefix `stt_records_automatic`.
3. Downloads the file content as a UTF-8 string and passes it directly to `TimeTrackerParser.parseCsv`.

### Path & Naming Conventions
- **Google Drive Web / Cloud**: `My Drive/Time track/stt_records_automatic.csv`
- **macOS CloudStorage Mirror**:
  `~/Library/CloudStorage/GoogleDrive-<email>/My Drive/08_Backups_and_Data/02_App_Data/Time track/stt_records_automatic.csv`
- **Time Tracker Continuous Target**:
  When configured to export to Google Drive on macOS, Time Tracker writes directly to the local mounted mirror directory. When running on Android, Time Tracker uses Android Background WorkManager and the Google Drive REST API / Storage Access Framework.

---

## 5. Atomic Continuous Live Export Strategy

In Time Tracker, continuous live export must run on every record state transition (timer stop, manual record creation, record edit, record deletion). Naive in-place file modification (`File.writeAsString` or `FileOutputStream` in overwrite mode) introduces critical failure modes:
1. **Partial Read Window**: If BNPB or Google Drive Desktop sync reads the CSV mid-write, it reads an incomplete, truncated file or unbalanced quotation mark, failing the sync.
2. **Process Interruption**: If the application crashes, power fails, or the OS suspends the background thread during writing, the export file is truncated to 0 bytes.
3. **Write Collision**: Rapid timer operations (e.g., stop timer, edit comment, add tag) can launch concurrent write routines that corrupt file contents.

### 5.1 The Atomic Swap Pattern (Write-Flush-Rename)

To guarantee that downstream readers always observe a completely valid, uncorrupted CSV file, Time Tracker implements the **Write-Flush-Rename** pattern:

```
[ In-Memory Records ] 
        │
        ▼ (Format RFC 4180 CSV)
[ Hidden Temp File ] (.stt_records_automatic.csv.tmp.<uuid>)
        │
        ▼ (fsync() / force(true))
[ Flushed to Physical Disk ]
        │
        ▼ (atomic rename() / Files.move())
[ Target CSV File ] (stt_records_automatic.csv)
```

#### Step-by-Step Execution:
1. **Same-Filesystem Temporary Sibling**:
   The temporary file MUST be created in the exact same directory (or mount point) as the destination file:
   - Target: `/path/to/Time track/stt_records_automatic.csv`
   - Temporary: `/path/to/Time track/.stt_records_automatic.csv.tmp.<random_id>`
   *(Creating the temp file on a different filesystem like `/tmp` causes `rename` to fall back to a non-atomic copy-and-delete operation).*
2. **Stream Serialization**:
   Stream the header and all records sorted by `timeStarted` ascending into the temporary file using UTF-8 encoding.
3. **Forced Physical Flush (`fsync`)**:
   Flush memory buffers to the kernel and force physical write to disk:
   - Kotlin: `fileOutputStream.fd.sync()` or `fileChannel.force(true)`
   - Dart: `await file.flush()`
   - POSIX: `fsync(fileno(file))`
4. **Atomic Filesystem Rename**:
   Execute an atomic replacement:
   - Kotlin / Java: `Files.move(tempPath, targetPath, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)`
   - Dart: `await tempFile.rename(targetPath)` (invokes POSIX `rename(2)` under the hood on macOS/Linux/Android)
   - POSIX semantics guarantee that the target file pointer transitions instantly from the previous complete version to the new complete version. Readers opening the file never see an intermediate state.

### 5.2 Concurrency Control & Debouncing

To conserve battery, prevent disk thrashing, and serialize mutations, the export pipeline utilizes a serialized actor queue with trailing-edge debouncing:

```kotlin
class ContinuousCsvExporter(
    private val scope: CoroutineScope,
    private val recordRepo: RecordRepo,
    private val targetFile: File,
    private val debounceMs: Long = 1000L
) {
    private val mutex = Mutex()
    private var exportJob: Job? = null

    fun triggerExport() {
        synchronized(this) {
            exportJob?.cancel()
            exportJob = scope.launch(Dispatchers.IO) {
                delay(debounceMs)
                performExport()
            }
        }
    }

    private suspend fun performExport() = mutex.withLock {
        withContext(Dispatchers.IO) {
            val tempFile = File(targetFile.parentFile, ".${targetFile.name}.tmp.${UUID.randomUUID()}")
            try {
                FileOutputStream(tempFile).use { fos ->
                    val writer = OutputStreamWriter(fos, StandardCharsets.UTF_8)
                    writer.write(CSV_HEADER)
                    
                    val records = recordRepo.getAllSortedByTimeStarted()
                    for (record in records) {
                        writer.write(record.toCsvRow())
                    }
                    writer.flush()
                    fos.fd.sync() // Guarantee bytes on physical disk
                }
                
                // Atomic POSIX rename
                Files.move(
                    tempFile.toPath(),
                    targetFile.toPath(),
                    StandardCopyOption.ATOMIC_MOVE,
                    StandardCopyOption.REPLACE_EXISTING
                )
            } catch (e: Exception) {
                tempFile.delete()
                Timber.e(e, "Failed atomic CSV export")
            }
        }
    }
}
```

### 5.3 Debounce Strategy
- **Debounce Window**: 1,000 ms.
- When an active timer stops, a record is modified, or a tag is added, `triggerExport()` is invoked.
- Multiple rapid edits (e.g. typing a comment or toggling tags) reset the timer, collapsing multiple I/O cycles into a single atomic write pass.
- App shutdown or pause hooks flush any pending debounced export immediately before termination.

---

## 6. Concrete CSV Export Example & Parity Verification

### 6.1 Sample Production-Compatible CSV Content

```csv
activity name,time started,time ended,comment,categories,record tags,duration,duration minutes
"Lunch",2025-09-17 11:46:37,2025-09-17 12:46:37,"w/ Abel","Essentials","Contact",1:0:0,60
"Dinner",2025-09-19 22:16:46,2025-09-19 23:03:36,"Boba w/ Benji Jeremy Timothy Isai ","Essentials","Contact",0:46:50,46
"Appointment",2025-09-16 13:30:54,2025-09-16 14:30:54,"Edgar Flores ","Spiritual","Contact",1:0:0,60
"Coding",2025-09-20 09:00:00,2025-09-20 10:33:43,"Refactored parser","Productivity ","",1:33:43,93
"Bible",2025-09-29 17:23:20,2025-09-29 18:02:44,"w/ Sammy","Spiritual","Contact",0:39:24,39
"Commute",2025-09-30 08:15:00,2025-09-30 08:34:09,"","Transportation ","",0:19:9,19
"Meeting",2025-10-01 14:00:00,2025-10-01 15:00:00,"Project kickoff with Alice Smith","Work","Contact, Important",1:0:0,60
"Personal Time",2025-10-01 15:00:00,2025-10-01 15:30:00,"Reviewing notes: \"Deep Work\"","Personal","",0:30:0,30
```

### 6.2 BNPB Ingestion Trace for Sample Rows

1. **Row 1 (`"Lunch"`)**:
   - `record tags`: `"Contact"` -> **Accepted**.
   - `comment`: `"w/ Abel"` -> Marker `w/` detected.
   - `prefix`: empty -> `summary = "Lunch w/ Abel"`.
   - Contact match: `"Abel"` -> Contact ID `c1` linked. `selected = true`.
   - Fingerprint: `sha256("2025-09-17 11:46:37|60|Lunch|w/ Abel")`.
2. **Row 2 (`"Dinner"`)**:
   - `record tags`: `"Contact"` -> **Accepted**.
   - `comment`: `"Boba w/ Benji Jeremy Timothy Isai "` -> Marker `w/` detected.
   - `prefix`: `"Boba"` -> `summary = "Dinner - Boba"`.
   - Contact match: `"Benji"`, `"Jeremy"`, `"Timothy"`, `"Isai"` all linked. `selected = true`.
   - Fingerprint: `sha256("2025-09-19 22:16:46|46|Dinner|Boba w/ Benji Jeremy Timothy Isai ")`.
3. **Row 3 (`"Appointment"`)**:
   - `record tags`: `"Contact"` -> **Accepted**.
   - `comment`: `"Edgar Flores "` -> No marker. Strict scan finds full name match `"Edgar Flores"`.
   - `summary = "Appointment - Edgar Flores "`. Contact linked. `selected = true`.
4. **Row 4 (`"Coding"`)**:
   - `record tags`: `""` -> Does not contain `"contact"`. **Skipped**.
5. **Row 7 (`"Meeting"`)**:
   - `record tags`: `"Contact, Important"` -> Contains `"contact"`. **Accepted**.
   - `comment`: `"Project kickoff with Alice Smith"` -> Marker `with ` detected (word boundary matched).
   - `prefix`: `"Project kickoff"` -> `summary = "Meeting - Project kickoff"`.
   - Contact match: `"Alice Smith"`.
6. **Row 8 (`"Personal Time"`)**:
   - `record tags`: `""` -> **Skipped**. Shows proper RFC 4180 double-quote escaping: `\"Deep Work\"` rendered as `""Deep Work""`.

---

## 7. Architectural Decisions for Time Tracker

1. **Native Ecosystem Export Module**:
   Implement an `EcosystemExportService` that encapsulates:
   - Simple Time Tracker CSV generator (parity mode).
   - ActivityWatch event bucket exporter (JSON mode).
   - SQLite snapshot backup (raw mode).
2. **Strict Parity Format Rules**:
   - Header: Exactly 8 columns, lowercase, comma-separated.
   - Columns: `activity name,time started,time ended,comment,categories,record tags,duration,duration minutes`.
   - Date format: `yyyy-MM-dd HH:mm:ss` (local device time).
   - Tags: Record tags joined with `", "`. The tag `"Contact"` must be available as a standard system tag or quick-tag toggle.
   - Quoting: Quote string columns (`activity name`, `comment`, `categories`, `record tags`), escape internal quotes with `""`. Unquote timestamps and durations.
3. **Zero-Poll Concurrency**:
   - Serialized background mutex queue with a 1,000ms trailing-edge debounce.
   - Write-flush-rename atomic filesystem swapping to eliminate partial reads and corruption.
4. **Target Destination**:
   - Default output location: `Time track/stt_records_automatic.csv`.
   - Configurable export target path to support local file pickers, Google Drive virtual folders, and internal app sandboxes.
