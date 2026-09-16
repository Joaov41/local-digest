#!/usr/bin/env python3
"""
Messages extractor using AppleScript.
"""
import json
import os
import sqlite3
import subprocess
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Dict, List


class MessagesExtractor:
    def __init__(self) -> None:
        self.applescript = r'''
        on escape_json(theText)
            if theText is missing value then return ""
            set theText to theText as string
            set theText to my replace_chars(theText, "\\", "\\\\")
            set theText to my replace_chars(theText, "\"", "\\\"")
            set theText to my replace_chars(theText, return, "\\n")
            set theText to my replace_chars(theText, linefeed, "\\n")
            return theText
        end escape_json

        on replace_chars(theText, searchString, replacementString)
            set AppleScript's text item delimiters to searchString
            set theItems to every text item of theText
            set AppleScript's text item delimiters to replacementString
            set theText to theItems as string
            set AppleScript's text item delimiters to ""
            return theText
        end replace_chars

        on pad2(n)
            set n to n as integer
            if n < 10 then return "0" & n
            return n as string
        end pad2

        on iso_date(theDate)
            if theDate is missing value then return ""
            set y to year of theDate as integer
            set m to month of theDate as integer
            set d to day of theDate as integer
            set h to hours of theDate as integer
            set mi to minutes of theDate as integer
            set s to seconds of theDate as integer
            return (y as string) & "-" & my pad2(m) & "-" & my pad2(d) & " " & my pad2(h) & ":" & my pad2(mi) & ":" & my pad2(s)
        end iso_date

        on run argv
            set maxCount to item 1 of argv as integer
            set hoursBack to item 2 of argv as integer

            set windowEnd to current date
            set windowStart to windowEnd - (hoursBack * hours)

            set messageList to {}
            set exportedCount to 0

            tell application "Messages"
                try
                    repeat with c in chats
                        if exportedCount >= maxCount then exit repeat
                        set chatName to ""
                        set chatId to ""
                        try
                            set chatName to name of c as string
                        end try
                        try
                            set chatId to id of c as string
                        end try
                        if chatId is "" then
                            set chatId to chatName
                        end if

                        set chatMessages to messages of c
                        set msgCount to count of chatMessages
                        if msgCount is 0 then
                            -- skip empty chats
                        else
                            set firstDate to missing value
                            set lastDate to missing value
                            try
                                set firstDate to date of item 1 of chatMessages
                            end try
                            try
                                set lastDate to date of item msgCount of chatMessages
                            end try

                            set scanStep to -1
                            set startIndex to msgCount
                            set endIndex to 1
                            set canBreakEarly to false

                            if firstDate is not missing value and lastDate is not missing value then
                                set canBreakEarly to true
                                if firstDate is greater than lastDate then
                                    set scanStep to 1
                                    set startIndex to 1
                                    set endIndex to msgCount
                                end if
                            end if

                            repeat with i from startIndex to endIndex by scanStep
                            if exportedCount >= maxCount then exit repeat
                            set m to item i of chatMessages

                            set msgText to ""
                            set msgDate to ""
                            set msgTs to ""
                            set msgDirection to ""
                            set senderName to ""
                            set msgDateObj to missing value

                            try
                                set msgText to content of m as string
                            end try
                            if msgText is "" then
                                set msgText to ""
                            end if
                            try
                                set msgDateObj to date of m
                            end try
                            if msgDateObj is not missing value then
                                set msgDate to my iso_date(msgDateObj)
                                set msgTs to msgDate
                                if msgDateObj is greater than windowEnd then
                                    -- skip future-dated
                                else if msgDateObj < windowStart then
                                    if canBreakEarly then exit repeat
                                else
                                    try
                                        set msgDirection to direction of m as string
                                    end try
                                    try
                                        set senderName to name of sender of m as string
                                    end try

                                    set msgRecord to "{"
                                    set msgRecord to msgRecord & "\"chat_id\":\"" & my escape_json(chatId) & "\","
                                    set msgRecord to msgRecord & "\"chat_name\":\"" & my escape_json(chatName) & "\","
                                    set msgRecord to msgRecord & "\"sender\":\"" & my escape_json(senderName) & "\","
                                    set msgRecord to msgRecord & "\"direction\":\"" & my escape_json(msgDirection) & "\","
                                    set msgRecord to msgRecord & "\"date\":\"" & my escape_json(msgDate) & "\","
                                    set msgRecord to msgRecord & "\"timestamp\":\"" & msgTs & "\","
                                    set msgRecord to msgRecord & "\"text\":\"" & my escape_json(msgText) & "\""
                                    set msgRecord to msgRecord & "}"

                                    set end of messageList to msgRecord
                                    set exportedCount to exportedCount + 1
                                end if
                            end if
                            end repeat
                        end if
                    end repeat

                    set AppleScript's text item delimiters to ","
                    set jsonArray to "[" & (messageList as string) & "]"
                    set AppleScript's text item delimiters to ""
                    return jsonArray
                on error errMsg
                    return "[]"
                end try
            end tell
        end run
        '''

    def extract_recent(self, hours: int = 48, count: int = 200) -> List[Dict]:
        applescript_failed = False
        messages: List[Dict] = []
        try:
            result = subprocess.run(
                ['osascript', '-e', self.applescript, str(count), str(hours)],
                capture_output=True,
                text=True,
                check=True
            )
            output = result.stdout.strip()
            if output and output != "[]":
                messages = json.loads(output)

            if not isinstance(messages, list):
                messages = []

            for msg in messages:
                msg['timestamp'] = self._parse_timestamp(msg.get('timestamp') or msg.get('date') or "")

        except subprocess.CalledProcessError as exc:
            stderr = exc.stderr.strip() if exc.stderr else ""
            print(f"AppleScript error: {exc}\n{stderr}")
            applescript_failed = True
        except Exception as exc:
            print(f"Error extracting messages: {exc}")
            applescript_failed = True

        if messages:
            return messages

        fallback = os.getenv("MESSAGES_DB_FALLBACK", "1").lower() in ("1", "true", "yes")
        if applescript_failed or fallback:
            return self._extract_from_db(hours=hours, count=count)

        return []

    def extract_today(self, count: int = 200) -> List[Dict]:
        return self.extract_recent(hours=24, count=count)

    def _extract_from_db(self, hours: int, count: int) -> List[Dict]:
        db_path = Path.home() / "Library" / "Messages" / "chat.db"
        if not db_path.exists():
            return []

        cutoff = datetime.now(timezone.utc) - timedelta(hours=hours)
        cutoff_apple = cutoff.timestamp() - 978307200  # Apple epoch 2001-01-01

        try:
            conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        except sqlite3.OperationalError as exc:
            print(f"Messages DB access error: {exc}")
            try:
                with tempfile.TemporaryDirectory() as tmpdir:
                    temp_db = Path(tmpdir) / "chat.db"
                    temp_wal = Path(tmpdir) / "chat.db-wal"
                    temp_shm = Path(tmpdir) / "chat.db-shm"
                    temp_db.write_bytes(db_path.read_bytes())
                    wal_path = db_path.with_suffix(".db-wal")
                    shm_path = db_path.with_suffix(".db-shm")
                    if wal_path.exists():
                        temp_wal.write_bytes(wal_path.read_bytes())
                    if shm_path.exists():
                        temp_shm.write_bytes(shm_path.read_bytes())
                    conn = sqlite3.connect(str(temp_db))
            except Exception as exc_copy:
                print(f"Messages DB fallback copy failed: {exc_copy}")
                return []

        try:
            conn.row_factory = sqlite3.Row
            cursor = conn.cursor()
            cursor.execute("PRAGMA busy_timeout=2000")

            cursor.execute("SELECT date FROM message WHERE date IS NOT NULL ORDER BY date DESC LIMIT 1")
            row = cursor.fetchone()
            max_date = row["date"] if row else None
            nanos = bool(max_date and max_date > 100000000000)
            cutoff_value = cutoff_apple * (1000000000 if nanos else 1)

            cursor.execute(
                """
                SELECT
                    m.ROWID as message_id,
                    m.date,
                    m.text,
                    m.is_from_me,
                    h.id as handle_id,
                    c.chat_identifier,
                    c.display_name
                FROM message m
                LEFT JOIN handle h ON m.handle_id = h.ROWID
                LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
                LEFT JOIN chat c ON c.ROWID = cmj.chat_id
                WHERE m.date >= ?
                  AND m.text IS NOT NULL
                  AND m.text != ''
                ORDER BY m.date DESC
                LIMIT ?
                """,
                (cutoff_value, count),
            )

            messages: List[Dict] = []
            for row in cursor.fetchall():
                date_value = row["date"]
                if date_value is None:
                    continue
                seconds = date_value / 1000000000 if nanos else date_value
                unix_ts = seconds + 978307200
                dt = datetime.fromtimestamp(unix_ts)
                chat_identifier = row["chat_identifier"] or row["handle_id"] or str(row["message_id"])
                chat_name = row["display_name"] or row["handle_id"] or "Unknown"
                is_from_me = row["is_from_me"] == 1

                messages.append({
                    "chat_id": chat_identifier,
                    "chat_name": chat_name,
                    "sender": "Me" if is_from_me else (row["handle_id"] or "Unknown"),
                    "direction": "outgoing" if is_from_me else "incoming",
                    "date": dt.strftime("%Y-%m-%d %H:%M:%S"),
                    "timestamp": int(unix_ts),
                    "text": row["text"] or "",
                })

            return messages
        except Exception as exc:
            print(f"Messages DB query failed: {exc}")
            return []
        finally:
            try:
                conn.close()
            except Exception:
                pass

    @staticmethod
    def _parse_timestamp(value: str) -> int:
        if not value:
            return 0
        if isinstance(value, (int, float)):
            return int(value)
        value_str = str(value).strip()
        if value_str.isdigit():
            return int(value_str)
        try:
            dt = datetime.strptime(value_str, "%Y-%m-%d %H:%M:%S")
            return int(dt.timestamp())
        except Exception:
            return 0


if __name__ == "__main__":
    extractor = MessagesExtractor()
    messages = extractor.extract_recent(hours=48)
    print(f"Found {len(messages)} messages in the last 48 hours")
