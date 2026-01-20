#!/usr/bin/env python3
"""
Calendar extractor using AppleScript.
"""
import json
import subprocess
from typing import Dict, List


class CalendarExtractor:
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

        on run argv
            set maxCount to item 1 of argv as integer
            set daysForward to item 2 of argv as integer

            set startDate to current date
            set endDate to startDate + (daysForward * days)
            set eventList to {}

            tell application "Calendar"
                try
                    repeat with cal in calendars
                        set calName to ""
                        try
                            set calName to name of cal as string
                        end try
                        set calEvents to (every event of cal whose start date is greater than startDate and start date is less than endDate)
                        repeat with ev in calEvents
                            set evSummary to ""
                            set evStart to ""
                            set evEnd to ""
                            set evLocation to ""
                            set evNotes to ""
                            set evId to ""
                            set evStartTs to ""
                            set evEndTs to ""

                            try
                                set evSummary to summary of ev as string
                            end try
                            try
                                set evStart to start date of ev as string
                                set evStartTs to (start date of ev) as integer
                            end try
                            try
                                set evEnd to end date of ev as string
                                set evEndTs to (end date of ev) as integer
                            end try
                            try
                                set evLocation to location of ev as string
                            end try
                            try
                                set evNotes to description of ev as string
                            end try
                            try
                                set evId to uid of ev as string
                            end try
                            if evId is "" then
                                try
                                    set evId to id of ev as string
                                end try
                            end if
                            if evId is "" then
                                set evId to calName & ":" & evSummary & ":" & evStart
                            end if

                            set eventRecord to "{"
                            set eventRecord to eventRecord & "\"id\":\"" & my escape_json(evId) & "\","
                            set eventRecord to eventRecord & "\"title\":\"" & my escape_json(evSummary) & "\","
                            set eventRecord to eventRecord & "\"start\":\"" & my escape_json(evStart) & "\","
                            set eventRecord to eventRecord & "\"end\":\"" & my escape_json(evEnd) & "\","
                            set eventRecord to eventRecord & "\"start_ts\":\"" & evStartTs & "\","
                            set eventRecord to eventRecord & "\"end_ts\":\"" & evEndTs & "\","
                            set eventRecord to eventRecord & "\"location\":\"" & my escape_json(evLocation) & "\","
                            set eventRecord to eventRecord & "\"notes\":\"" & my escape_json(evNotes) & "\","
                            set eventRecord to eventRecord & "\"calendar\":\"" & my escape_json(calName) & "\""
                            set eventRecord to eventRecord & "}"

                            set end of eventList to eventRecord
                        end repeat
                    end repeat

                    set AppleScript's text item delimiters to ","
                    set jsonArray to "[" & (eventList as string) & "]"
                    set AppleScript's text item delimiters to ""
                    return jsonArray
                on error errMsg
                    return "[]"
                end try
            end tell
        end run
        '''

    def extract_events(self, days: int = 7, count: int = 20) -> List[Dict]:
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

            events = json.loads(output)
            if not isinstance(events, list):
                return []

            for event in events:
                try:
                    event['start_ts'] = int(event.get('start_ts') or 0)
                except Exception:
                    event['start_ts'] = 0
                try:
                    event['end_ts'] = int(event.get('end_ts') or 0)
                except Exception:
                    event['end_ts'] = 0

            events.sort(key=lambda item: item.get('start_ts', 0))
            if count and len(events) > count:
                events = events[:count]
            return events

        except subprocess.CalledProcessError as exc:
            print(f"AppleScript error: {exc}")
            return []
        except Exception as exc:
            print(f"Error extracting calendar events: {exc}")
            return []


if __name__ == "__main__":
    extractor = CalendarExtractor()
    events = extractor.extract_events()
    print(f"Found {len(events)} upcoming events")
