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
import socket
import subprocess
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


# Daily Digest Helper Functions
def _summarize_emails_for_digest(emails: list, max_chars: int = 2000) -> str:
    """Create a condensed summary of emails for the digest prompt."""
    if not emails:
        return "No new emails in the last 24 hours."

    lines = []
    total_chars = 0
    for email in emails[:10]:
        line = f"- From: {email.get('from', 'Unknown')}, Subject: {email.get('subject', 'No Subject')}"
        body = (email.get('body', '') or '')[:200].replace('\n', ' ').strip()
        if body:
            line += f" - {body}..."
        if total_chars + len(line) > max_chars:
            break
        lines.append(line)
        total_chars += len(line)

    return "\n".join(lines)


def _summarize_events_for_digest(events: list) -> str:
    """Create a condensed summary of calendar events."""
    if not events:
        return "No calendar events for today."

    lines = []
    for event in events[:8]:
        line = f"- {event.get('title', 'Untitled')} at {event.get('start', 'TBD')}"
        if event.get('location'):
            line += f" ({event['location']})"
        lines.append(line)

    return "\n".join(lines)


def _summarize_reminders_for_digest(reminders: list) -> str:
    """Create a condensed summary of reminders."""
    if not reminders:
        return "No reminders due today."

    lines = []
    for reminder in reminders[:8]:
        line = f"- {reminder.get('title', 'Untitled')}"
        if reminder.get('due'):
            line += f" (due: {reminder['due']})"
        lines.append(line)

    return "\n".join(lines)


def _summarize_messages_for_digest(threads: list, max_chars: int = 1500) -> str:
    """Create a condensed summary of message threads."""
    if not threads:
        return "No new messages in the last 24 hours."

    lines = []
    total_chars = 0
    for thread in threads[:5]:
        title = thread.get('title', 'Unknown')
        msg_count = len(thread.get('messages', []))
        recent_msgs = thread.get('messages', [])[-3:]
        preview = "; ".join([m.get('text', '')[:50] for m in recent_msgs if m.get('text')])

        line = f"- {title} ({msg_count} messages): {preview[:150]}..."
        if total_chars + len(line) > max_chars:
            break
        lines.append(line)
        total_chars += len(line)

    return "\n".join(lines)


def _prepare_digest_content(emails, events, reminders, threads) -> dict:
    """Prepare condensed content for the digest prompt."""
    return {
        'emails': _summarize_emails_for_digest(emails),
        'events': _summarize_events_for_digest(events),
        'reminders': _summarize_reminders_for_digest(reminders),
        'messages': _summarize_messages_for_digest(threads),
        'counts': {
            'emails': len(emails),
            'events': len(events),
            'reminders': len(reminders),
            'threads': len(threads)
        }
    }


def _get_message_threads_for_digest(hours: int = 24, count: int = 5) -> list:
    """Get top message threads from the last N hours."""
    messages = messages_extractor.extract_recent(hours=hours, count=200)
    threads = {}
    for msg in messages:
        key = msg.get('chat_id') or msg.get('chat_name') or msg.get('sender') or 'unknown'
        thread = threads.setdefault(key, {
            'id': key,
            'title': msg.get('chat_name') or msg.get('sender') or 'Unknown',
            'messages': []
        })
        thread['messages'].append(msg)

    thread_list = list(threads.values())
    thread_list.sort(key=lambda t: len(t['messages']), reverse=True)
    return thread_list[:count]


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

@app.route('/api/digest', methods=['POST'])
def generate_daily_digest():
    """Generate a unified daily digest with streaming response."""
    data = request.json or {}
    selected_model = data.get('model')

    def generate():
        try:
            # Phase 1: Gather data
            yield f"data: {json.dumps({'type': 'status', 'phase': 'gathering', 'message': 'Gathering your data...'})}\n\n"

            emails = email_extractor.extract_emails(count=15, hours_back=24)
            events = calendar_extractor.extract_events(days=1, count=10)
            reminders = reminders_extractor.extract_due(days=1, count=10)
            threads = _get_message_threads_for_digest(hours=24, count=5)

            # Phase 2: Prepare content
            yield f"data: {json.dumps({'type': 'status', 'phase': 'analyzing', 'message': 'Analyzing content...'})}\n\n"

            category_data = _prepare_digest_content(emails, events, reminders, threads)

            # Phase 3: Generate digest
            yield f"data: {json.dumps({'type': 'status', 'phase': 'generating', 'message': 'Generating your digest...'})}\n\n"

            system_prompt = (
                "You are a personal assistant creating a daily briefing. "
                "Synthesize the information into a clear, actionable digest. "
                "Be concise but comprehensive. Use bullet points and clear sections. "
                "Focus on what matters most and any action items."
            )

            user_prompt = f"""Create my daily digest for today based on this data:

## EMAILS ({category_data['counts']['emails']} total)
{category_data['emails']}

## CALENDAR ({category_data['counts']['events']} events)
{category_data['events']}

## REMINDERS ({category_data['counts']['reminders']} items)
{category_data['reminders']}

## MESSAGES ({category_data['counts']['threads']} conversations)
{category_data['messages']}

---

Please create a structured daily digest with these sections:
1. **Today's Schedule** - Key events and their times
2. **Priority Actions** - What needs attention today (from emails, reminders, messages)
3. **Email Highlights** - Important messages that need response or attention
4. **Message Summary** - Key conversations and any follow-ups needed
5. **Quick Notes** - Anything else noteworthy

Keep each section concise. If a category has no items, briefly note it's clear."""

            model_used = None

            if is_apple_model(selected_model):
                summary, model_used = apple_client.generate(
                    system_prompt,
                    user_prompt,
                    max_tokens=1024,
                    temperature=0.4,
                )
                if summary:
                    yield f"data: {json.dumps({'type': 'chunk', 'content': summary})}\n\n"
                    yield f"data: {json.dumps({'type': 'model', 'content': model_used})}\n\n"
                else:
                    yield f"data: {json.dumps({'type': 'error', 'content': 'Failed to generate digest'})}\n\n"
                    return
            else:
                for event_type, content in mlx_client.summarize_text_stream(
                    system_prompt, user_prompt, model=selected_model
                ):
                    if event_type == "chunk":
                        yield f"data: {json.dumps({'type': 'chunk', 'content': content})}\n\n"
                    elif event_type == "model":
                        model_used = content
                        yield f"data: {json.dumps({'type': 'model', 'content': content})}\n\n"
                    elif event_type == "error":
                        yield f"data: {json.dumps({'type': 'error', 'content': content})}\n\n"
                        return

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

def is_port_in_use(port: int) -> bool:
    """Check if a port is in use."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        return s.connect_ex(('localhost', port)) == 0


def kill_process_on_port(port: int) -> bool:
    """Kill any process using the specified port (macOS/Linux)."""
    try:
        # Find PID using lsof
        result = subprocess.run(
            ['lsof', '-ti', f':{port}'],
            capture_output=True,
            text=True
        )
        pids = result.stdout.strip().split('\n')
        pids = [p for p in pids if p]

        if not pids:
            return False

        for pid in pids:
            try:
                os.kill(int(pid), signal.SIGTERM)
                print(f"Killed process {pid} on port {port}")
            except (ProcessLookupError, ValueError):
                pass

        # Wait a moment for the port to be released
        time.sleep(0.5)
        return True
    except FileNotFoundError:
        # lsof not available, try netstat approach
        return False


if __name__ == '__main__':
    PORT = 5001

    # Check if port is busy and kill existing process
    if is_port_in_use(PORT):
        print(f"Port {PORT} is busy. Killing existing process...")
        kill_process_on_port(PORT)
        # Double check
        if is_port_in_use(PORT):
            print(f"Warning: Port {PORT} still in use after kill attempt")

    init_db()
    print(f"Starting Local Digest (MLX local models) on http://localhost:{PORT}")
    debug_enabled = os.getenv("LOCAL_DIGEST_DEBUG", "1") == "1"
    reload_enabled = os.getenv("LOCAL_DIGEST_RELOAD", "1") == "1"
    app.run(debug=debug_enabled, use_reloader=reload_enabled, port=PORT)
