#!/usr/bin/env python3
"""
Email extractor using AppleScript
"""
import subprocess
import json
from datetime import datetime, timedelta
from typing import List, Dict, Optional

class EmailExtractor:
    def __init__(self):
        self.applescript = '''
        -- Export latest emails from inbox
        on run argv
            set maxCount to item 1 of argv as integer
            set hoursBack to item 2 of argv as integer
            
            set currentDate to current date
            set cutoffDate to currentDate - (hoursBack * hours)
            
            set emailList to {}
            
            tell application "Mail"
                try
                    set inboxMessages to messages of inbox whose date received is greater than cutoffDate
                    
                    set messageCount to count of inboxMessages
                    if messageCount > maxCount then
                        set messagesToExport to items 1 through maxCount of inboxMessages
                    else
                        set messagesToExport to inboxMessages
                    end if
                    
                    repeat with msg in messagesToExport
                        try
                            set msgId to (get id of msg) as string
                            set msgDate to (get date received of msg) as string
                            set msgFrom to (get sender of msg) as string
                            set msgSubject to (get subject of msg) as string
                            set msgBody to (get content of msg) as string
                            
                            set emailRecord to "{"
                            set emailRecord to emailRecord & "\\"id\\":\\"" & msgId & "\\","
                            set emailRecord to emailRecord & "\\"date\\":\\"" & msgDate & "\\","
                            set emailRecord to emailRecord & "\\"from\\":\\"" & msgFrom & "\\","
                            set emailRecord to emailRecord & "\\"subject\\":\\"" & msgSubject & "\\","
                            set emailRecord to emailRecord & "\\"body\\":\\"" & msgBody & "\\""
                            set emailRecord to emailRecord & "}"
                            
                            set end of emailList to emailRecord
                        end try
                    end repeat
                    
                    set AppleScript's text item delimiters to ","
                    set jsonArray to "[" & (emailList as string) & "]"
                    set AppleScript's text item delimiters to ""
                    
                    return jsonArray
                on error errMsg
                    return "[]"
                end try
            end tell
        end run
        '''
    
    def extract_emails(self, count: int = 10, hours_back: int = 24) -> List[Dict]:
        """Extract latest emails using AppleScript"""
        try:
            # Run AppleScript with parameters
            result = subprocess.run(
                ['osascript', '-e', self.applescript, str(count), str(hours_back)],
                capture_output=True,
                text=True,
                check=True
            )
            
            # Parse the JSON-like output
            output = result.stdout.strip()
            if not output or output == "[]":
                return []
            
            # Clean up the output for JSON parsing
            # AppleScript doesn't properly escape JSON, so we need to fix it
            emails = []
            
            # Simple parsing since AppleScript output isn't proper JSON
            import re
            pattern = r'\{[^}]+\}'
            matches = re.findall(pattern, output)
            
            for match in matches:
                try:
                    # Extract fields manually
                    email = {}
                    
                    # Extract ID
                    id_match = re.search(r'"id":"([^"]*)"', match)
                    if id_match:
                        email['id'] = id_match.group(1)
                    
                    # Extract date
                    date_match = re.search(r'"date":"([^"]*)"', match)
                    if date_match:
                        email['date'] = date_match.group(1)
                    
                    # Extract from
                    from_match = re.search(r'"from":"([^"]*)"', match)
                    if from_match:
                        email['from'] = from_match.group(1)
                    
                    # Extract subject
                    subject_match = re.search(r'"subject":"([^"]*)"', match)
                    if subject_match:
                        email['subject'] = subject_match.group(1)
                    
                    # Extract body (this is tricky due to newlines)
                    body_match = re.search(r'"body":"(.*?)"(?:,|\})', match, re.DOTALL)
                    if body_match:
                        email['body'] = body_match.group(1)
                    
                    if email:
                        emails.append(email)
                        
                except Exception as e:
                    print(f"Error parsing email: {e}")
                    continue
            
            return emails
            
        except subprocess.CalledProcessError as e:
            print(f"AppleScript error: {e}")
            return []
        except Exception as e:
            print(f"Error extracting emails: {e}")
            return []
    
    def extract_single_email(self, subject: str, sender: str) -> Optional[Dict]:
        """Extract a specific email by subject and sender"""
        emails = self.extract_emails(count=50, hours_back=48)
        
        for email in emails:
            if email.get('subject') == subject and email.get('from') == sender:
                return email
        
        return None

if __name__ == "__main__":
    # Test the extractor
    extractor = EmailExtractor()
    emails = extractor.extract_emails(count=5)
    
    print(f"Found {len(emails)} emails:")
    for email in emails:
        print(f"- {email.get('subject', 'No subject')} from {email.get('from', 'Unknown')}")