#!/usr/bin/env python3
"""
Flask web application for email summarization using MLX local models
"""
from flask import Flask, render_template, jsonify, request, Response, stream_with_context
from flask_cors import CORS
import sqlite3
import json
from datetime import datetime
import os
import time
import threading
import signal
from email_extractor import EmailExtractor
from calendar_extractor import CalendarExtractor
from reminders_extractor import RemindersExtractor
from messages_extractor import MessagesExtractor
from mlx_client import MLXClient
from apple_model_client import AppleFoundationClient

app = Flask(__name__)
CORS(app)

# Initialize components
email_extractor = EmailExtractor()
mlx_client = MLXClient()
apple_client = AppleFoundationClient()
calendar_extractor = CalendarExtractor()
reminders_extractor = RemindersExtractor()
messages_extractor = MessagesExtractor()

# Database setup
DB_PATH = "email_summaries.db"
DB_LOCK = threading.Lock()
APPLE_MODEL_ID = "apple:foundation"

def is_apple_model(model_id: str | None) -> bool:
    return model_id == APPLE_MODEL_ID

def init_db():
    """Initialize SQLite database"""
    conn = sqlite3.connect(DB_PATH, timeout=30)
    conn.execute("PRAGMA journal_mode=WAL")  # Enable WAL mode for better concurrency
    cursor = conn.cursor()
    
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS summaries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            email_id TEXT UNIQUE,
            subject TEXT,
            sender TEXT,
            email_date TEXT,
            body TEXT,
            summary TEXT,
            model_used TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    ''')
    
    conn.commit()
    conn.close()

def get_db():
    """Get database connection with retry logic"""
    max_retries = 5
    retry_delay = 0.1
    
    for i in range(max_retries):
        try:
            conn = sqlite3.connect(DB_PATH, timeout=30)
            conn.row_factory = sqlite3.Row
            conn.execute("PRAGMA journal_mode=WAL")
            return conn
        except sqlite3.OperationalError as e:
            if "locked" in str(e) and i < max_retries - 1:
                time.sleep(retry_delay * (i + 1))
                continue
            raise
    
    raise sqlite3.OperationalError("Database is locked after multiple retries")

def execute_with_retry(func, *args, **kwargs):
    """Execute database operation with retry logic"""
    max_retries = 5
    retry_delay = 0.1
    
    for i in range(max_retries):
        try:
            return func(*args, **kwargs)
        except sqlite3.OperationalError as e:
            if "locked" in str(e) and i < max_retries - 1:
                time.sleep(retry_delay * (i + 1))
                continue
            raise

def _strip_code_blocks(text: str | None) -> str | None:
    if not text:
        return text
    if "```" not in text:
        return text.strip()
    return text.split("```", 1)[0].strip()

def _compact_text(text: str | None, limit: int = 200) -> str:
    if not text:
        return ""
    cleaned = " ".join(str(text).replace("\r", " ").replace("\n", " ").split())
    if len(cleaned) <= limit:
        return cleaned
    trimmed = cleaned[: max(0, limit - 3)].rstrip()
    return f"{trimmed}..."

def _format_overview_section(title: str, lines: list[str]) -> str:
    if lines:
        return f"{title}\n" + "\n".join(lines)
    return f"{title}\n- None"

def _format_overview_email(email: dict) -> str:
    subject = email.get('subject') or 'No subject'
    sender = email.get('from') or 'Unknown sender'
    date = email.get('date') or 'Unknown date'
    snippet = _compact_text(email.get('body'), 180)
    parts = [f"{subject} (from {sender}, {date})"]
    if snippet:
        parts.append(f"Snippet: {snippet}")
    return "- " + " | ".join(parts)

def _format_overview_event(event: dict) -> str:
    title = event.get('title') or 'Untitled Event'
    start = event.get('start') or 'Unknown start'
    end = event.get('end') or 'Unknown end'
    parts = [f"{title} ({start} - {end})"]
    location = event.get('location') or ''
    notes = _compact_text(event.get('notes'), 160)
    if location:
        parts.append(f"Location: {location}")
    if notes:
        parts.append(f"Notes: {notes}")
    return "- " + " | ".join(parts)

def _format_overview_reminder(reminder: dict) -> str:
    title = reminder.get('title') or 'Untitled Reminder'
    due = reminder.get('due') or 'Today'
    list_name = reminder.get('list') or 'Reminders'
    notes = _compact_text(reminder.get('notes'), 160)
    parts = [f"{title} (List: {list_name}, Due: {due})"]
    if notes:
        parts.append(f"Notes: {notes}")
    return "- " + " | ".join(parts)

def _resolve_message_sender(msg: dict) -> str:
    sender = msg.get('sender')
    if sender:
        return sender
    direction = (msg.get('direction') or '').lower()
    if direction == 'outgoing':
        return 'Me'
    return 'Unknown'

def _format_overview_message(msg: dict) -> str:
    thread = msg.get('chat_name') or msg.get('chat_id') or 'Conversation'
    sender = _resolve_message_sender(msg)
    date = msg.get('date') or 'Unknown date'
    text = _compact_text(msg.get('text'), 160)
    line = f"{thread} | {sender} at {date}"
    if text:
        line = f"{line}: {text}"
    return f"- {line}"

@app.route('/')
def index():
    """Main page"""
    return render_template('index.html')

@app.route('/api/status')
def status():
    """Check system status"""
    apple_available = apple_client.is_available()
    models_info = mlx_client.list_models_with_info()
    if apple_available:
        models_info.insert(0, {
            "id": APPLE_MODEL_ID,
            "name": "Apple Foundation Model",
            "type": "apple",
            "valid": True,
            "path": None
        })
    return jsonify({
        'mlx_available': mlx_client.is_available(),
        'mlx_models': mlx_client.list_models(),
        'mlx_models_info': models_info,
        'current_model': mlx_client.model,
        'local_models_dir': mlx_client.get_local_models_dir(),
        'apple_model_available': apple_available,
        'apple_model_availability': apple_client.get_availability()
    })

@app.route('/api/models/add', methods=['POST'])
def add_model():
    """Add a model ID to the local model list and warm it up."""
    try:
        data = request.json or {}
        model_id = data.get('model')
        make_default = bool(data.get('make_default', False))

        models = mlx_client.add_model(model_id, make_default=make_default)

        def warm_up():
            try:
                import asyncio
                asyncio.run(mlx_client.warm_up_model(model_id))
            except Exception:
                pass

        threading.Thread(target=warm_up, daemon=True).start()

        return jsonify({
            'success': True,
            'models': models,
            'current_model': mlx_client.model
        })
    except Exception as e:
        return jsonify({
            'success': False,
            'error': str(e)
        }), 400

@app.route('/api/models/local-dir', methods=['GET', 'POST'])
def local_models_dir():
    """Get or set the local models directory."""
    if request.method == 'GET':
        return jsonify({
            'success': True,
            'directory': mlx_client.get_local_models_dir()
        })

    try:
        data = request.json or {}
        directory = data.get('directory', '')

        if mlx_client.set_local_models_dir(directory):
            return jsonify({
                'success': True,
                'directory': mlx_client.get_local_models_dir()
            })
        else:
            return jsonify({
                'success': False,
                'error': 'Invalid directory path'
            }), 400
    except Exception as e:
        return jsonify({
            'success': False,
            'error': str(e)
        }), 400


@app.route('/api/models/scan', methods=['GET', 'POST'])
def scan_local_models():
    """Scan a directory for local MLX models."""
    try:
        if request.method == 'POST':
            data = request.json or {}
            directory = data.get('directory')
        else:
            directory = request.args.get('directory')

        models = mlx_client.scan_local_models(directory)

        return jsonify({
            'success': True,
            'models': models,
            'count': len(models),
            'directory': directory or mlx_client.get_local_models_dir()
        })
    except Exception as e:
        return jsonify({
            'success': False,
            'error': str(e)
        }), 500


@app.route('/api/models/add-local', methods=['POST'])
def add_local_model():
    """Add a local model path to the models list."""
    try:
        data = request.json or {}
        path = data.get('path')
        make_default = bool(data.get('make_default', False))

        if not path:
            return jsonify({
                'success': False,
                'error': 'Path is required'
            }), 400

        models = mlx_client.add_local_model(path, make_default=make_default)

        # Warm up in background
        def warm_up():
            try:
                import asyncio
                asyncio.run(mlx_client.warm_up_model(path))
            except Exception:
                pass

        threading.Thread(target=warm_up, daemon=True).start()

        return jsonify({
            'success': True,
            'models': models,
            'current_model': mlx_client.model
        })
    except Exception as e:
        return jsonify({
            'success': False,
            'error': str(e)
        }), 400


@app.route('/api/warm-up', methods=['POST'])
async def warm_up():
    """Warm up the MLX model"""
    try:
        import asyncio
        success = await mlx_client.warm_up_model()
        return jsonify({
            'success': success
        })
    except Exception as e:
        return jsonify({
            'success': False,
            'error': str(e)
        }), 500

@app.route('/api/emails')
def get_emails():
    """Get latest emails"""
    try:
        count = request.args.get('count', 10, type=int)
        hours = request.args.get('hours', 24, type=int)
        
        emails = email_extractor.extract_emails(count=count, hours_back=hours)
        
        # Check which ones already have summaries
        conn = get_db()
        try:
            cursor = conn.cursor()
            
            for email in emails:
                cursor.execute('SELECT id FROM summaries WHERE email_id = ?', (email.get('id', ''),))
                email['has_summary'] = cursor.fetchone() is not None
        finally:
            conn.close()
        
        return jsonify({
            'success': True,
            'emails': emails,
            'count': len(emails)
        })
        
    except Exception as e:
        return jsonify({
            'success': False,
            'error': str(e)
        }), 500

@app.route('/api/calendar')
def get_calendar_events():
    """Get upcoming calendar events"""
    try:
        days = request.args.get('days', 7, type=int)
        count = request.args.get('count', 20, type=int)

        events = calendar_extractor.extract_events(days=days, count=count)

        return jsonify({
            'success': True,
            'events': events,
            'count': len(events)
        })
    except Exception as e:
        return jsonify({
            'success': False,
            'error': str(e)
        }), 500

@app.route('/api/reminders')
def get_reminders():
    """Get reminders due in the next N days"""
    try:
        count = request.args.get('count', 50, type=int)
        days = request.args.get('days', 3, type=int)
        reminders = reminders_extractor.extract_due(days=days, count=count)

        return jsonify({
            'success': True,
            'reminders': reminders,
            'count': len(reminders)
        })
    except Exception as e:
        return jsonify({
            'success': False,
            'error': str(e)
        }), 500

@app.route('/api/messages')
def get_messages():
    """Get iMessage/SMS threads for the last N hours"""
    try:
        count = request.args.get('count', 200, type=int)
        hours = request.args.get('hours', 48, type=int)
        messages = messages_extractor.extract_recent(hours=hours, count=count)

        threads = {}
        for msg in messages:
            key = msg.get('chat_id') or msg.get('chat_name') or msg.get('sender') or 'unknown'
            thread = threads.setdefault(key, {
                'id': key,
                'title': msg.get('chat_name') or msg.get('sender') or 'Unknown',
                'messages': []
            })

            direction = msg.get('direction') or ''
            sender = msg.get('sender') or ''
            if not sender and direction.lower() == 'outgoing':
                msg['sender'] = 'Me'

            thread['messages'].append(msg)

        thread_list = []
        for thread in threads.values():
            thread['messages'].sort(key=lambda item: item.get('timestamp', 0))
            last_message = thread['messages'][-1] if thread['messages'] else {}
            thread['last_message'] = last_message.get('text', '')
            thread['last_date'] = last_message.get('date', '')
            thread['last_ts'] = last_message.get('timestamp', 0)
            thread['message_count'] = len(thread['messages'])
            thread_list.append(thread)

        thread_list.sort(key=lambda item: item.get('last_ts', 0), reverse=True)

        return jsonify({
            'success': True,
            'threads': thread_list,
            'count': len(thread_list)
        })
    except Exception as e:
        return jsonify({
            'success': False,
            'error': str(e)
        }), 500

@app.route('/api/overview', methods=['POST'])
def get_overview():
    """Generate an overview from emails, calendar, reminders, and messages."""
    try:
        data = request.json or {}
        selected_model = data.get('model')

        emails = email_extractor.extract_emails(count=10, hours_back=24)
        events = calendar_extractor.extract_events(days=1, count=20)
        reminders = reminders_extractor.extract_due(days=1, count=20)

        messages = messages_extractor.extract_recent(hours=24, count=100)
        messages_sorted = sorted(messages, key=lambda item: item.get('timestamp', 0), reverse=True)
        recent_messages = messages_sorted[:5]

        email_lines = [_format_overview_email(email) for email in emails]
        event_lines = [_format_overview_event(event) for event in events]
        reminder_lines = [_format_overview_reminder(reminder) for reminder in reminders]
        message_lines = [_format_overview_message(msg) for msg in recent_messages]

        if not any([email_lines, event_lines, reminder_lines, message_lines]):
            return jsonify({
                'success': False,
                'error': 'No data available for overview'
            }), 400

        system_prompt = (
            "You are a helpful assistant that creates concise daily overviews. "
            "Use the provided emails, calendar events, reminders, and messages. "
            "Highlight key actions, deadlines, and notable updates. "
            "Do not include code blocks or templates."
        )
        user_prompt = (
            "Create a concise overview of the day. "
            "Use short bullet points and call out anything urgent or time-sensitive.\n\n"
            f"{_format_overview_section('Emails (latest 10):', email_lines)}\n\n"
            f"{_format_overview_section('Calendar (today):', event_lines)}\n\n"
            f"{_format_overview_section('Reminders (today):', reminder_lines)}\n\n"
            f"{_format_overview_section('Messages (last 5):', message_lines)}"
        )

        if is_apple_model(selected_model):
            summary, model_used = apple_client.generate(
                system_prompt,
                user_prompt,
                max_tokens=512,
                temperature=0.3,
            )
        else:
            summary, model_used = mlx_client.summarize_text(system_prompt, user_prompt, model=selected_model)
        summary = _strip_code_blocks(summary)

        if not summary:
            return jsonify({
                'success': False,
                'error': 'Failed to generate overview'
            }), 500

        return jsonify({
            'success': True,
            'summary': summary,
            'model_used': model_used,
            'counts': {
                'emails': len(emails),
                'events': len(events),
                'reminders': len(reminders),
                'messages': len(recent_messages)
            },
            'generated_at': datetime.now().isoformat()
        })
    except Exception as e:
        return jsonify({
            'success': False,
            'error': str(e)
        }), 500

@app.route('/api/summarize', methods=['POST'])
def summarize_email():
    """Summarize a specific email"""
    try:
        data = request.json
        email_id = data.get('email_id')
        email_body = data.get('body')
        email_subject = data.get('subject')
        email_sender = data.get('sender')
        email_date = data.get('date')
        selected_model = data.get('model')
        
        if not email_body:
            return jsonify({
                'success': False,
                'error': 'No email body provided'
            }), 400
        
        # Check if summary already exists
        conn = get_db()
        try:
            cursor = conn.cursor()
            cursor.execute('SELECT summary FROM summaries WHERE email_id = ?', (email_id,))
            existing = cursor.fetchone()
            
            if existing:
                return jsonify({
                    'success': True,
                    'summary': existing['summary'],
                    'cached': True
                })
        finally:
            conn.close()
        
        # Generate new summary
        if is_apple_model(selected_model):
            system_prompt = "You are a helpful assistant that summarizes emails concisely."
            user_prompt = (
                "Summarize this email concisely. Include key points, actions needed, and important details.\n\n"
                f"Email:\n{email_body}\n\nSummary:"
            )
            summary, model_used = apple_client.generate(
                system_prompt,
                user_prompt,
                max_tokens=512,
                temperature=0.3,
            )
        else:
            summary, model_used = mlx_client.summarize_email(email_body, model=selected_model)
        
        if not summary:
            return jsonify({
                'success': False,
                'error': 'Failed to generate summary'
            }), 500
        
        # Save to database with retry
        def save_summary():
            conn = get_db()
            try:
                cursor = conn.cursor()
                cursor.execute('''
                    INSERT INTO summaries (email_id, subject, sender, email_date, body, summary, model_used)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                ''', (email_id, email_subject, email_sender, email_date, email_body, summary, model_used))
                conn.commit()
            finally:
                conn.close()
        
        execute_with_retry(save_summary)
        
        return jsonify({
            'success': True,
            'summary': summary,
            'model_used': model_used,
            'cached': False
        })
        
    except Exception as e:
        return jsonify({
            'success': False,
            'error': str(e)
        }), 500

@app.route('/api/summarize-generic', methods=['POST'])
def summarize_generic():
    """Summarize calendar, reminders, or messages"""
    try:
        data = request.json or {}
        kind = data.get('kind')
        content = data.get('content')
        title = data.get('title', '')
        selected_model = data.get('model')

        if not kind or not content:
            return jsonify({
                'success': False,
                'error': 'kind and content are required'
            }), 400

        if kind == 'calendar':
            system_prompt = (
                "You are a helpful assistant that summarizes upcoming calendar events. "
                "Do not include code blocks or templates."
            )
            user_prompt = (
                f"Summarize this calendar item. Focus on time, location, and preparation needed.\n\n"
                f"Title: {title}\n{content}\n\nSummary:"
            )
        elif kind == 'reminder':
            system_prompt = (
                "You are a helpful assistant that summarizes reminders and action items. "
                "Do not include code blocks or templates."
            )
            user_prompt = (
                f"Summarize this reminder and suggest any action needed.\n\n"
                f"Title: {title}\n{content}\n\nSummary:"
            )
        elif kind == 'messages':
            system_prompt = (
                "You are a helpful assistant that summarizes message conversations. "
                "Do not include code blocks or templates."
            )
            user_prompt = (
                f"Summarize today's messages in this conversation. Highlight decisions and next steps.\n\n"
                f"Conversation: {title}\n{content}\n\nSummary:"
            )
        else:
            return jsonify({
                'success': False,
                'error': f'Unknown kind: {kind}'
            }), 400

        if is_apple_model(selected_model):
            summary, model_used = apple_client.generate(
                system_prompt,
                user_prompt,
                max_tokens=512,
                temperature=0.3,
            )
        else:
            summary, model_used = mlx_client.summarize_text(system_prompt, user_prompt, model=selected_model)
        summary = _strip_code_blocks(summary)

        if not summary:
            return jsonify({
                'success': False,
                'error': 'Failed to generate summary'
            }), 500

        return jsonify({
            'success': True,
            'summary': summary,
            'model_used': model_used
        })
    except Exception as e:
        return jsonify({
            'success': False,
            'error': str(e)
        }), 500

@app.route('/api/summarize-stream', methods=['POST'])
def summarize_email_stream():
    """Summarize a specific email with streaming response"""
    data = request.json
    email_id = data.get('email_id')
    email_body = data.get('body')
    email_subject = data.get('subject')
    email_sender = data.get('sender')
    email_date = data.get('date')
    selected_model = data.get('model')
    
    if not email_body:
        return jsonify({'success': False, 'error': 'No email body provided'}), 400
    
    # Check if summary already exists
    conn = get_db()
    try:
        cursor = conn.cursor()
        cursor.execute('SELECT summary FROM summaries WHERE email_id = ?', (email_id,))
        existing = cursor.fetchone()
    finally:
        conn.close()
    
    if existing:
        # Return cached summary as a single chunk
        def generate():
            yield f"data: {json.dumps({'type': 'chunk', 'content': existing['summary']})}\n\n"
            yield f"data: {json.dumps({'type': 'cached', 'value': True})}\n\n"
            yield f"data: {json.dumps({'type': 'done'})}\n\n"
        
        return Response(
            stream_with_context(generate()),
            mimetype='text/event-stream',
            headers={
                'Cache-Control': 'no-cache',
                'X-Accel-Buffering': 'no'
            }
        )
    
    def generate():
        summary_chunks = []
        model_used = None
        
        try:
            if is_apple_model(selected_model):
                system_prompt = "You are a helpful assistant that summarizes emails concisely."
                user_prompt = (
                    "Summarize this email concisely. Include key points, actions needed, and important details.\n\n"
                    f"Email:\n{email_body}\n\nSummary:"
                )
                summary, model_used = apple_client.generate(
                    system_prompt,
                    user_prompt,
                    max_tokens=512,
                    temperature=0.3,
                )
                if not summary:
                    yield f"data: {json.dumps({'type': 'error', 'content': 'Failed to generate summary'})}\n\n"
                    return
                summary_chunks.append(summary)
                yield f"data: {json.dumps({'type': 'chunk', 'content': summary})}\n\n"
                yield f"data: {json.dumps({'type': 'model', 'content': model_used})}\n\n"
            else:
                for event_type, content in mlx_client.summarize_email_stream(email_body, model=selected_model):
                    if event_type == "chunk":
                        summary_chunks.append(content)
                        yield f"data: {json.dumps({'type': 'chunk', 'content': content})}\n\n"
                    elif event_type == "model":
                        model_used = content
                        yield f"data: {json.dumps({'type': 'model', 'content': content})}\n\n"
                    elif event_type == "error":
                        yield f"data: {json.dumps({'type': 'error', 'content': content})}\n\n"
                        return
            
            # Save complete summary to database
            if summary_chunks and model_used:
                complete_summary = ''.join(summary_chunks)
                
                def save_summary():
                    conn = get_db()
                    try:
                        cursor = conn.cursor()
                        cursor.execute('''
                            INSERT OR REPLACE INTO summaries (email_id, subject, sender, email_date, body, summary, model_used)
                            VALUES (?, ?, ?, ?, ?, ?, ?)
                        ''', (email_id, email_subject, email_sender, email_date, email_body, complete_summary, model_used))
                        conn.commit()
                    finally:
                        conn.close()
                
                try:
                    execute_with_retry(save_summary)
                except Exception as e:
                    print(f"Warning: Failed to save summary to database: {e}")
                    # Don't fail the streaming response if we can't save
            
            yield f"data: {json.dumps({'type': 'done'})}\n\n"
            
        except Exception as e:
            yield f"data: {json.dumps({'type': 'error', 'content': str(e)})}\n\n"
    
    return Response(
        stream_with_context(generate()),
        mimetype='text/event-stream',
        headers={
            'Cache-Control': 'no-cache',
            'X-Accel-Buffering': 'no'
        }
    )

@app.route('/api/summaries')
def get_summaries():
    """Get all saved summaries"""
    try:
        conn = get_db()
        try:
            cursor = conn.cursor()
            
            cursor.execute('''
                SELECT id, email_id, subject, sender, email_date, summary, model_used, created_at
                FROM summaries
                ORDER BY created_at DESC
                LIMIT 100
            ''')
            
            summaries = []
            for row in cursor.fetchall():
                summaries.append({
                    'id': row['id'],
                    'email_id': row['email_id'],
                    'subject': row['subject'],
                    'sender': row['sender'],
                    'email_date': row['email_date'],
                    'summary': row['summary'],
                    'model_used': row['model_used'],
                    'created_at': row['created_at']
                })
        finally:
            conn.close()
        
        return jsonify({
            'success': True,
            'summaries': summaries,
            'count': len(summaries)
        })
        
    except Exception as e:
        return jsonify({
            'success': False,
            'error': str(e)
        }), 500

@app.route('/api/summaries/<int:summary_id>', methods=['DELETE'])
def delete_summary(summary_id):
    """Delete a summary"""
    try:
        def delete():
            conn = get_db()
            try:
                cursor = conn.cursor()
                cursor.execute('DELETE FROM summaries WHERE id = ?', (summary_id,))
                conn.commit()
            finally:
                conn.close()
        
        execute_with_retry(delete)
        
        return jsonify({
            'success': True
        })
        
    except Exception as e:
        return jsonify({
            'success': False,
            'error': str(e)
        }), 500

@app.route('/api/clear-all', methods=['POST'])
def clear_all():
    """Clear all summaries"""
    try:
        def clear():
            conn = get_db()
            try:
                cursor = conn.cursor()
                cursor.execute('DELETE FROM summaries')
                conn.commit()
            finally:
                conn.close()
        
        execute_with_retry(clear)
        
        return jsonify({
            'success': True
        })
        
    except Exception as e:
        return jsonify({
            'success': False,
            'error': str(e)
        }), 500

@app.route('/api/chat', methods=['POST'])
def chat_with_email():
    """Chat about a specific email with context"""
    try:
        data = request.json
        email_id = data.get('email_id')
        email_body = data.get('email_body')
        email_summary = data.get('summary')
        user_question = data.get('question')
        chat_history = data.get('chat_history', [])
        selected_model = data.get('model')
        
        if not user_question or not email_body:
            return jsonify({
                'success': False,
                'error': 'Question and email body are required'
            }), 400
        
        # Build context from email, summary, and chat history
        context = f"Email Content:\n{email_body}\n\n"
        if email_summary:
            context += f"Summary:\n{email_summary}\n\n"
        
        if chat_history:
            context += "Previous conversation:\n"
            for msg in chat_history[-4:]:  # Keep last 4 exchanges for context
                context += f"{msg['role']}: {msg['content']}\n"
            context += "\n"
        
        # Generate response
        if is_apple_model(selected_model):
            system_prompt = (
                "You are a helpful assistant answering questions about an email. "
                "Use the provided email content and summary to answer questions accurately and concisely. "
                "Do not repeat the question or include labels."
            )
            user_prompt = (
                f"Context:\n{context}\n\n"
                f"Question: {user_question}\n\n"
                "Respond with a concise answer."
            )
            response, _ = apple_client.generate(
                system_prompt,
                user_prompt,
                max_tokens=256,
                temperature=0.3,
            )
        else:
            response = mlx_client.chat_about_email(context, user_question, model=selected_model)
        
        if not response:
            return jsonify({
                'success': False,
                'error': 'Failed to generate response'
            }), 500
        
        return jsonify({
            'success': True,
            'response': response
        })
        
    except Exception as e:
        return jsonify({
            'success': False,
            'error': str(e)
        }), 500

@app.route('/api/chat-stream', methods=['POST'])
def chat_with_email_stream():
    """Chat about a specific email with streaming response"""
    data = request.json
    email_id = data.get('email_id')
    email_body = data.get('email_body')
    email_summary = data.get('summary')
    user_question = data.get('question')
    chat_history = data.get('chat_history', [])
    selected_model = data.get('model')
    
    if not user_question or not email_body:
        return jsonify({'success': False, 'error': 'Question and email body are required'}), 400
    
    # Build context from email, summary, and chat history
    context = f"Email Content:\n{email_body}\n\n"
    if email_summary:
        context += f"Summary:\n{email_summary}\n\n"
    
    if chat_history:
        context += "Previous conversation:\n"
        for msg in chat_history[-4:]:  # Keep last 4 exchanges for context
            context += f"{msg['role']}: {msg['content']}\n"
        context += "\n"
    
    def generate():
        try:
            if is_apple_model(selected_model):
                system_prompt = (
                    "You are a helpful assistant answering questions about an email. "
                    "Use the provided email content and summary to answer questions accurately and concisely. "
                    "Do not repeat the question or include labels."
                )
                user_prompt = (
                    f"Context:\n{context}\n\n"
                    f"Question: {user_question}\n\n"
                    "Respond with a concise answer."
                )
                response, _ = apple_client.generate(
                    system_prompt,
                    user_prompt,
                    max_tokens=256,
                    temperature=0.3,
                )
                if response:
                    yield f"data: {json.dumps({'type': 'chunk', 'content': response})}\n\n"
                else:
                    yield f"data: {json.dumps({'type': 'error', 'content': 'Failed to generate response'})}\n\n"
                    return
            else:
                for chunk in mlx_client.chat_about_email_stream(context, user_question, model=selected_model):
                    if chunk:
                        yield f"data: {json.dumps({'type': 'chunk', 'content': chunk})}\n\n"

            yield f"data: {json.dumps({'type': 'done'})}\n\n"
            
        except Exception as e:
            yield f"data: {json.dumps({'type': 'error', 'content': str(e)})}\n\n"
    
    return Response(
        stream_with_context(generate()),
        mimetype='text/event-stream',
        headers={
            'Cache-Control': 'no-cache',
            'X-Accel-Buffering': 'no'
        }
    )

@app.route('/api/chat-generic', methods=['POST'])
def chat_generic():
    """Chat about calendar, reminders, or messages"""
    try:
        data = request.json or {}
        kind = data.get('kind')
        context = data.get('context')
        question = data.get('question')
        selected_model = data.get('model')

        if not kind or not context or not question:
            return jsonify({
                'success': False,
                'error': 'kind, context, and question are required'
            }), 400

        prompt_prefix = {
            'calendar': "Calendar context:",
            'reminder': "Reminder context:",
            'messages': "Messages context:"
        }.get(kind, "Context:")

        full_context = f"{prompt_prefix}\n{context}"
        if is_apple_model(selected_model):
            system_prompt = (
                "You are a helpful assistant answering questions based on the provided context. "
                "Use the context accurately and respond concisely. "
                "Do not repeat the question or include labels."
            )
            user_prompt = (
                f"Context:\n{full_context}\n\n"
                f"Question: {question}\n\n"
                "Respond with a concise answer."
            )
            response, _ = apple_client.generate(
                system_prompt,
                user_prompt,
                max_tokens=256,
                temperature=0.3,
            )
        else:
            response = mlx_client.chat_about_context(full_context, question, model=selected_model)

        if not response:
            return jsonify({
                'success': False,
                'error': 'Failed to generate response'
            }), 500

        return jsonify({
            'success': True,
            'response': response
        })
    except Exception as e:
        return jsonify({
            'success': False,
            'error': str(e)
        }), 500

@app.route('/api/chat-generic-stream', methods=['POST'])
def chat_generic_stream():
    """Chat about calendar, reminders, or messages with streaming response"""
    data = request.json or {}
    kind = data.get('kind')
    context = data.get('context')
    question = data.get('question')
    selected_model = data.get('model')

    if not kind or not context or not question:
        return jsonify({'success': False, 'error': 'kind, context, and question are required'}), 400

    prompt_prefix = {
        'calendar': "Calendar context:",
        'reminder': "Reminder context:",
        'messages': "Messages context:"
    }.get(kind, "Context:")

    full_context = f"{prompt_prefix}\n{context}"

    def generate():
        try:
            if is_apple_model(selected_model):
                system_prompt = (
                    "You are a helpful assistant answering questions based on the provided context. "
                    "Use the context accurately and respond concisely. "
                    "Do not repeat the question or include labels."
                )
                user_prompt = (
                    f"Context:\n{full_context}\n\n"
                    f"Question: {question}\n\n"
                    "Respond with a concise answer."
                )
                response, _ = apple_client.generate(
                    system_prompt,
                    user_prompt,
                    max_tokens=256,
                    temperature=0.3,
                )
                if response:
                    yield f"data: {json.dumps({'type': 'chunk', 'content': response})}\n\n"
                else:
                    yield f"data: {json.dumps({'type': 'error', 'content': 'Failed to generate response'})}\n\n"
                    return
            else:
                for chunk in mlx_client.chat_about_context_stream(full_context, question, model=selected_model):
                    if chunk:
                        yield f"data: {json.dumps({'type': 'chunk', 'content': chunk})}\n\n"

            yield f"data: {json.dumps({'type': 'done'})}\n\n"

        except Exception as e:
            yield f"data: {json.dumps({'type': 'error', 'content': str(e)})}\n\n"

    return Response(
        stream_with_context(generate()),
        mimetype='text/event-stream',
        headers={
            'Cache-Control': 'no-cache',
            'X-Accel-Buffering': 'no'
        }
    )

@app.route('/api/shutdown', methods=['POST'])
def shutdown():
    if request.remote_addr not in ("127.0.0.1", "::1"):
        return jsonify({'success': False, 'error': 'Forbidden'}), 403
    shutdown_func = request.environ.get('werkzeug.server.shutdown')
    if shutdown_func:
        shutdown_func()
        return jsonify({'success': True})
    os.kill(os.getpid(), signal.SIGTERM)
    return jsonify({'success': True})

if __name__ == '__main__':
    init_db()
    print("Starting Local Digest (MLX local models) on http://localhost:5001")
    debug_enabled = os.getenv("LOCAL_DIGEST_DEBUG", "1") == "1"
    reload_enabled = os.getenv("LOCAL_DIGEST_RELOAD", "1") == "1"
    app.run(debug=debug_enabled, use_reloader=reload_enabled, port=5001)
