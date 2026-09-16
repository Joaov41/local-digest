#!/usr/bin/env python3
"""
Reminders extractor using AppleScript.
"""
import json
import subprocess
from datetime import datetime
from typing import Dict, List


class RemindersExtractor:
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
            set daysForward to item 2 of argv as integer

            set windowStart to current date
            set windowStart's hours to 0
            set windowStart's minutes to 0
            set windowStart's seconds to 0
            set windowEnd to windowStart + (daysForward * days)

            set reminderList to {}
            set exportedCount to 0

            tell application "Reminders"
                try
                    repeat with theList in lists
                        set listName to ""
                        try
                            set listName to name of theList as string
                        end try

                        set listReminders to (reminders of theList whose completed is false)
                        repeat with r in listReminders
                            if exportedCount >= maxCount then exit repeat

                            set reminderId to ""
                            set reminderTitle to ""
                            set reminderDue to ""
                            set reminderDueTs to ""
                            set reminderNotes to ""
                            set reminderDate to missing value

                            try
                                set reminderId to id of r as string
                            end try
                            try
                                set reminderTitle to name of r as string
                            end try
                            try
                                set reminderDate to due date of r
                            end try
                            if reminderDate is not missing value then
                                set reminderDue to my iso_date(reminderDate)
                                set reminderDueTs to reminderDue
                            end if
                            try
                                set reminderNotes to body of r as string
                            end try

                            if reminderDate is not missing value then
                                if reminderDate is greater than or equal to windowStart and reminderDate is less than windowEnd then
                                    set reminderRecord to "{"
                                    set reminderRecord to reminderRecord & "\"id\":\"" & my escape_json(reminderId) & "\","
                                    set reminderRecord to reminderRecord & "\"title\":\"" & my escape_json(reminderTitle) & "\","
                                    set reminderRecord to reminderRecord & "\"due\":\"" & my escape_json(reminderDue) & "\","
                                    set reminderRecord to reminderRecord & "\"due_ts\":\"" & reminderDueTs & "\","
                                    set reminderRecord to reminderRecord & "\"notes\":\"" & my escape_json(reminderNotes) & "\","
                                    set reminderRecord to reminderRecord & "\"list\":\"" & my escape_json(listName) & "\""
                                    set reminderRecord to reminderRecord & "}"

                                    set end of reminderList to reminderRecord
                                    set exportedCount to exportedCount + 1
                                end if
                            end if
                        end repeat
                    end repeat

                    set AppleScript's text item delimiters to ","
                    set jsonArray to "[" & (reminderList as string) & "]"
                    set AppleScript's text item delimiters to ""
                    return jsonArray
                on error errMsg
                    return "[]"
                end try
            end tell
        end run
        '''

    def extract_due(self, days: int = 1, count: int = 50) -> List[Dict]:
        try:
            result = subprocess.run(
                ['osascript', '-e', self.applescript, str(count), str(days)],
                capture_output=True,
                text=True,
                check=True
            )
            output = result.stdout.strip()
            if not output or output == "[]":
                return []

            reminders = json.loads(output)
            if not isinstance(reminders, list):
                return []

            for reminder in reminders:
                reminder['due_ts'] = self._parse_timestamp(reminder.get('due_ts') or reminder.get('due') or "")

            reminders.sort(key=lambda item: item.get('due_ts', 0))
            if count and len(reminders) > count:
                reminders = reminders[:count]
            return reminders

        except subprocess.CalledProcessError as exc:
            stderr = exc.stderr.strip() if exc.stderr else ""
            print(f"AppleScript error: {exc}\n{stderr}")
            return []
        except Exception as exc:
            print(f"Error extracting reminders: {exc}")
            return []

    def extract_today(self, count: int = 50) -> List[Dict]:
        return self.extract_due(days=1, count=count)

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
    extractor = RemindersExtractor()
    reminders = extractor.extract_due(days=1)
    print(f"Found {len(reminders)} reminders due today")
