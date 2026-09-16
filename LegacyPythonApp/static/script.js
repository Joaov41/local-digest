// Local Digest Frontend

let currentEmails = [];
let selectedEmail = null;
let autoRefreshEnabled = false;
let autoRefreshInterval = null;
let refreshCountdown = 60;
let countdownInterval = null;
let useStreaming = true;  // Enable streaming by default
let selectedModel = null;  // Currently selected model
let currentSummary = null;  // Store current summary
let chatHistory = [];  // Store email chat history
let chatHistoryCalendar = [];
let chatHistoryMessages = [];
let currentEvents = [];
let currentReminders = [];
let currentThreads = [];
let selectedEvent = null;
let selectedReminder = null;
let selectedThread = null;
let activeTab = 'email';
let tabState = {
    email: true,
    calendar: false,
    messages: false
};
let currentDigest = null;  // Store current daily digest

// Initialize on page load
document.addEventListener('DOMContentLoaded', () => {
    checkMlxStatus();
    loadModels();
    loadEmails();
    setupEventListeners();
    setupTabs();
    setupTheme();
    
    // Load auto-refresh preference
    const savedAutoRefresh = localStorage.getItem('autoRefresh') === 'true';
    if (savedAutoRefresh) {
        document.getElementById('auto-refresh-toggle').checked = true;
        startAutoRefresh();
    }
    
    // Load saved model preference
    const savedModel = localStorage.getItem('selectedModel');
    if (savedModel) {
        selectedModel = savedModel;
    }
});

// Setup event listeners
function setupEventListeners() {
    document.getElementById('refresh-btn').addEventListener('click', () => {
        loadEmails();
        resetRefreshCountdown();
    });
    document.getElementById('email-count').addEventListener('change', loadEmails);
    document.getElementById('email-hours').addEventListener('change', loadEmails);
    document.getElementById('view-all-summaries').addEventListener('click', showAllSummaries);
    document.getElementById('clear-all-btn').addEventListener('click', clearAllSummaries);
    document.getElementById('export-email').addEventListener('click', exportEmail);
    
    // Auto-refresh toggle
    document.getElementById('auto-refresh-toggle').addEventListener('change', (e) => {
        if (e.target.checked) {
            startAutoRefresh();
        } else {
            stopAutoRefresh();
        }
        localStorage.setItem('autoRefresh', e.target.checked);
    });

    const shutdownBtn = document.getElementById('shutdown-btn');
    if (shutdownBtn) {
        shutdownBtn.addEventListener('click', async () => {
            if (!confirm('Stop Local Digest?')) return;
            try {
                await fetch('/api/shutdown', { method: 'POST' });
            } catch (error) {
                console.error('Error shutting down:', error);
            } finally {
                window.close();
            }
        });
    }

    const darkToggle = document.getElementById('dark-mode-toggle');
    if (darkToggle) {
        darkToggle.addEventListener('change', (e) => {
            const theme = e.target.checked ? 'dark' : 'light';
            applyTheme(theme);
            localStorage.setItem('theme', theme);
        });
    }
    
    // Modal close
    document.querySelector('.close-btn').addEventListener('click', () => {
        document.getElementById('summaries-modal').classList.remove('show');
    });
    
    // Model selector
    document.getElementById('model-selector').addEventListener('change', (e) => {
        selectedModel = e.target.value;
        localStorage.setItem('selectedModel', selectedModel);
    });

    document.getElementById('model-add').addEventListener('click', addModel);
    document.getElementById('model-input').addEventListener('keypress', (e) => {
        if (e.key === 'Enter') {
            addModel();
        }
    });

    document.getElementById('calendar-refresh').addEventListener('click', loadCalendar);
    document.getElementById('calendar-days').addEventListener('change', loadCalendar);
    document.getElementById('reminders-refresh').addEventListener('click', loadReminders);
    document.getElementById('reminders-days').addEventListener('change', loadReminders);
    document.getElementById('messages-refresh').addEventListener('click', loadMessages);

    // Daily Digest
    document.getElementById('generate-digest-btn').addEventListener('click', generateDailyDigest);
    document.getElementById('close-digest').addEventListener('click', () => {
        document.getElementById('digest-modal').classList.remove('show');
    });
    document.getElementById('export-digest').addEventListener('click', exportDigest);
    
    // Chat functionality
    document.getElementById('chat-send').addEventListener('click', sendChatMessage);
    document.getElementById('chat-input').addEventListener('keypress', (e) => {
        if (e.key === 'Enter') {
            sendChatMessage();
        }
    });

    document.getElementById('calendar-chat-send').addEventListener('click', sendCalendarChatMessage);
    document.getElementById('calendar-chat-input').addEventListener('keypress', (e) => {
        if (e.key === 'Enter') {
            sendCalendarChatMessage();
        }
    });

    document.getElementById('messages-chat-send').addEventListener('click', sendMessagesChatMessage);
    document.getElementById('messages-chat-input').addEventListener('keypress', (e) => {
        if (e.key === 'Enter') {
            sendMessagesChatMessage();
        }
    });
}

// Tabs
function setupTabs() {
    document.querySelectorAll('.tab').forEach(tab => {
        tab.addEventListener('click', () => {
            switchTab(tab.dataset.tab);
        });
    });
}

function switchTab(tabName) {
    activeTab = tabName;

    document.querySelectorAll('.tab').forEach(tab => {
        tab.classList.toggle('active', tab.dataset.tab === tabName);
    });

    document.querySelectorAll('.tab-content').forEach(content => {
        content.classList.toggle('active', content.id === `tab-${tabName}`);
    });

    if (tabName !== 'email') {
        hideChatInterface();
    }

    if (tabName === 'calendar' && !tabState.calendar) {
        loadCalendar();
        loadReminders();
        tabState.calendar = true;
    }

    if (tabName === 'messages' && !tabState.messages) {
        loadMessages();
        tabState.messages = true;
    }
}

function hideChatInterface() {
    const chatContainer = document.getElementById('chat-container');
    chatContainer.style.display = 'none';
    const calendarChat = document.getElementById('calendar-chat-container');
    if (calendarChat) calendarChat.style.display = 'none';
    const messagesChat = document.getElementById('messages-chat-container');
    if (messagesChat) messagesChat.style.display = 'none';
    document.getElementById('export-email').style.display = 'none';
}

// Auto-refresh functions
function startAutoRefresh() {
    autoRefreshEnabled = true;
    refreshCountdown = 60;
    updateCountdown();
    
    // Start countdown timer
    countdownInterval = setInterval(() => {
        refreshCountdown--;
        updateCountdown();
        
        if (refreshCountdown <= 0) {
            loadEmails();
            refreshCountdown = 60;
        }
    }, 1000);
    
    // Start refresh interval
    autoRefreshInterval = setInterval(() => {
        loadEmails();
    }, 60000); // 60 seconds
}

function stopAutoRefresh() {
    autoRefreshEnabled = false;
    clearInterval(autoRefreshInterval);
    clearInterval(countdownInterval);
    document.getElementById('refresh-countdown').textContent = '';
}

function resetRefreshCountdown() {
    if (autoRefreshEnabled) {
        refreshCountdown = 60;
        updateCountdown();
    }
}

function updateCountdown() {
    if (autoRefreshEnabled) {
        document.getElementById('refresh-countdown').textContent = `${refreshCountdown}s`;
    }
}

// Check MLX status
async function checkMlxStatus() {
    try {
        const response = await fetch('/api/status');
        const data = await response.json();
        
        const statusEl = document.getElementById('mlx-status');
        const statusText = statusEl.querySelector('.status-text');
        
        if (data.mlx_available) {
            statusEl.classList.add('active');
            statusEl.classList.remove('error');
            statusText.textContent = `MLX`;
        } else {
            statusEl.classList.add('error');
            statusEl.classList.remove('active');
            statusText.textContent = 'MLX not available';
        }
    } catch (error) {
        console.error('Error checking status:', error);
    }
}

// Load available models
async function loadModels() {
    try {
        const response = await fetch('/api/status');
        const data = await response.json();

        const modelSelector = document.getElementById('model-selector');

        if (data.mlx_models_info && data.mlx_models_info.length > 0) {
            modelSelector.innerHTML = data.mlx_models_info.map(info => {
                let prefix = 'HF ';
                if (info.type === 'local') {
                    prefix = 'Local ';
                } else if (info.type === 'apple') {
                    prefix = 'Apple ';
                }
                const displayName = info.name;
                const isSelected = info.id === (selectedModel || data.current_model);
                return `<option value="${info.id}" ${isSelected ? 'selected' : ''}>${prefix}${displayName}</option>`;
            }).join('');

            // Update selectedModel if not set
            if (!selectedModel) {
                selectedModel = modelSelector.value;
            }
        } else if (data.mlx_available && data.mlx_models.length > 0) {
            // Fallback to simple model list
            modelSelector.innerHTML = data.mlx_models.map(model =>
                `<option value="${model}" ${model === (selectedModel || data.current_model) ? 'selected' : ''}>${model}</option>`
            ).join('');

            if (!selectedModel) {
                selectedModel = modelSelector.value;
            }
        } else {
            modelSelector.innerHTML = '<option value="">No models available</option>';
        }
    } catch (error) {
        console.error('Error loading models:', error);
    }
}

function setupTheme() {
    const savedTheme = localStorage.getItem('theme') || 'light';
    applyTheme(savedTheme);
    const toggle = document.getElementById('dark-mode-toggle');
    if (toggle) {
        toggle.checked = savedTheme === 'dark';
    }
}

function applyTheme(theme) {
    document.body.dataset.theme = theme;
}

// Add a new model to the list and trigger download
async function addModel() {
    const input = document.getElementById('model-input');
    const status = document.getElementById('model-add-status');
    const model = input.value.trim();

    if (!model) {
        status.textContent = 'Enter a model id or path';
        return;
    }

    // Detect if it's a local path or HuggingFace ID
    const isLocalPath = model.startsWith('/') || model.startsWith('~') || model.startsWith('.');
    const endpoint = isLocalPath ? '/api/models/add-local' : '/api/models/add';
    const payload = isLocalPath ? { path: model, make_default: true } : { model, make_default: true };

    status.textContent = 'Adding...';

    try {
        const response = await fetch(endpoint, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload)
        });
        const data = await response.json();

        if (data.success) {
            selectedModel = data.current_model || model;
            localStorage.setItem('selectedModel', selectedModel);
            await loadModels();
            status.textContent = 'Added!';
            input.value = '';
        } else {
            status.textContent = data.error || 'Failed to add model';
        }
    } catch (error) {
        console.error('Error adding model:', error);
        status.textContent = 'Failed to add model';
    } finally {
        setTimeout(() => {
            status.textContent = '';
        }, 4000);
    }
}

// Load emails
async function loadEmails() {
    const count = document.getElementById('email-count').value;
    const hours = document.getElementById('email-hours').value;
    
    const emailList = document.getElementById('email-list');
    const selectedEmailId = selectedEmail?.id;
    
    // Don't show loading if auto-refreshing to avoid UI flicker
    if (!autoRefreshEnabled) {
        emailList.innerHTML = '<div class="loading"><span class="loading-spinner"></span> Loading emails...</div>';
    }
    
    try {
        const response = await fetch(`/api/emails?count=${count}&hours=${hours}`);
        const data = await response.json();
        
        if (data.success) {
            currentEmails = data.emails;
            // Pre-calculate email sizes for better UX
            currentEmails.forEach(email => {
                if (email.body) {
                    email.bodyLength = email.body.length;
                    email.estimatedTokens = Math.ceil(email.body.length / 4);
                }
            });
            displayEmails(data.emails);
            
            // Re-select previously selected email if it still exists
            if (selectedEmailId) {
                const emailIndex = currentEmails.findIndex(e => e.id === selectedEmailId);
                if (emailIndex !== -1) {
                    selectEmail(emailIndex);
                }
            }
        } else {
            emailList.innerHTML = '<div class="empty-state">Failed to load emails</div>';
        }
    } catch (error) {
        console.error('Error loading emails:', error);
        emailList.innerHTML = '<div class="empty-state">Error loading emails</div>';
    }
}

// Display emails in list
function displayEmails(emails) {
    const emailList = document.getElementById('email-list');
    
    if (emails.length === 0) {
        emailList.innerHTML = '<div class="empty-state">No emails found</div>';
        return;
    }
    
    emailList.innerHTML = emails.map((email, index) => {
        // Add size indicator for large emails
        let sizeIndicator = '';
        if (email.estimatedTokens > 20000) {
            sizeIndicator = ' • <span style="color: #ff9500;">Large</span>';
        } else if (email.estimatedTokens > 10000) {
            sizeIndicator = ' • <span style="color: #007aff;">Medium</span>';
        }
        
        return `
            <div class="email-item ${email.has_summary ? 'has-summary' : ''}" data-index="${index}">
                <div class="email-subject">${escapeHtml(email.subject || 'No Subject')}</div>
                <div class="email-meta">
                    ${escapeHtml(email.from || 'Unknown')} • ${formatDate(email.date)}${sizeIndicator}
                </div>
            </div>
        `;
    }).join('');
    
    // Add click listeners
    document.querySelectorAll('.email-item').forEach(item => {
        item.addEventListener('click', () => selectEmail(parseInt(item.dataset.index)));
    });
}

// Select email
function selectEmail(index) {
    selectedEmail = currentEmails[index];
    
    // Update UI
    document.querySelectorAll('.email-item').forEach(item => {
        item.classList.remove('selected');
    });
    document.querySelector(`[data-index="${index}"]`).classList.add('selected');
    
    // Show summary or generate
    if (selectedEmail.has_summary) {
        loadSummary(selectedEmail);
    } else {
        generateSummary(selectedEmail);
    }
}

// Load calendar events
async function loadCalendar() {
    const days = document.getElementById('calendar-days').value;
    const calendarList = document.getElementById('calendar-list');
    calendarList.innerHTML = '<div class="loading"><span class="loading-spinner"></span> Loading events...</div>';

    try {
        const response = await fetch(`/api/calendar?days=${days}`);
        const data = await response.json();

        if (data.success) {
            currentEvents = data.events || [];
            displayCalendarEvents(currentEvents);
        } else {
            calendarList.innerHTML = '<div class="empty-state">Failed to load events</div>';
        }
    } catch (error) {
        console.error('Error loading calendar:', error);
        calendarList.innerHTML = '<div class="empty-state">Error loading events</div>';
    }
}

function displayCalendarEvents(events) {
    const calendarList = document.getElementById('calendar-list');

    if (!events.length) {
        calendarList.innerHTML = '<div class="empty-state">No upcoming events</div>';
        return;
    }

    calendarList.innerHTML = events.map((event, index) => `
        <div class="calendar-item" data-index="${index}">
            <div class="email-subject">${escapeHtml(event.title || 'Untitled Event')}</div>
            <div class="email-meta">${escapeHtml(event.calendar || 'Calendar')} • ${formatDate(event.start)}</div>
        </div>
    `).join('');

    document.querySelectorAll('.calendar-item').forEach(item => {
        item.addEventListener('click', () => selectCalendarEvent(parseInt(item.dataset.index, 10)));
    });
}

function selectCalendarEvent(index) {
    selectedEvent = currentEvents[index];
    document.querySelectorAll('.calendar-item').forEach(item => item.classList.remove('selected'));
    const selectedEl = document.querySelector(`.calendar-item[data-index="${index}"]`);
    if (selectedEl) selectedEl.classList.add('selected');

    summarizeGeneric(
        'calendar',
        buildCalendarContent(selectedEvent),
        selectedEvent.title || 'Calendar Event',
        'calendar-summary-content'
    );

    showChatInterfaceFor('calendar');
}

function buildCalendarContent(event) {
    const parts = [
        `Calendar: ${event.calendar || 'Calendar'}`,
        `Start: ${event.start || 'Unknown'}`,
        `End: ${event.end || 'Unknown'}`
    ];
    if (event.location) parts.push(`Location: ${event.location}`);
    if (event.notes) parts.push(`Notes: ${event.notes}`);
    return parts.join('\n');
}

// Load reminders
async function loadReminders() {
    const days = document.getElementById('reminders-days').value;
    const remindersList = document.getElementById('reminders-list');
    remindersList.innerHTML = '<div class="loading"><span class="loading-spinner"></span> Loading reminders...</div>';

    try {
        const response = await fetch(`/api/reminders?days=${days}`);
        const data = await response.json();

        if (data.success) {
            currentReminders = data.reminders || [];
            displayReminders(currentReminders);
        } else {
            remindersList.innerHTML = '<div class="empty-state">Failed to load reminders</div>';
        }
    } catch (error) {
        console.error('Error loading reminders:', error);
        remindersList.innerHTML = '<div class="empty-state">Error loading reminders</div>';
    }
}

function displayReminders(reminders) {
    const remindersList = document.getElementById('reminders-list');

    if (!reminders.length) {
        remindersList.innerHTML = '<div class="empty-state">No reminders due in this range</div>';
        return;
    }

    remindersList.innerHTML = reminders.map((reminder, index) => `
        <div class="reminder-item" data-index="${index}">
            <div class="email-subject">${escapeHtml(reminder.title || 'Untitled Reminder')}</div>
            <div class="email-meta">${escapeHtml(reminder.list || 'Reminders')} • ${formatDate(reminder.due)}</div>
        </div>
    `).join('');

    document.querySelectorAll('.reminder-item').forEach(item => {
        item.addEventListener('click', () => selectReminder(parseInt(item.dataset.index, 10)));
    });
}

function selectReminder(index) {
    selectedReminder = currentReminders[index];
    document.querySelectorAll('.reminder-item').forEach(item => item.classList.remove('selected'));
    const selectedEl = document.querySelector(`.reminder-item[data-index="${index}"]`);
    if (selectedEl) selectedEl.classList.add('selected');

    summarizeGeneric(
        'reminder',
        buildReminderContent(selectedReminder),
        selectedReminder.title || 'Reminder',
        'calendar-summary-content'
    );

    showChatInterfaceFor('calendar');
}

function buildReminderContent(reminder) {
    const parts = [
        `List: ${reminder.list || 'Reminders'}`,
        `Due: ${reminder.due || 'Today'}`
    ];
    if (reminder.notes) parts.push(`Notes: ${reminder.notes}`);
    return parts.join('\n');
}

// Load messages
async function loadMessages() {
    const messagesList = document.getElementById('messages-list');
    messagesList.innerHTML = '<div class="loading"><span class="loading-spinner"></span> Loading messages...</div>';

    try {
        const response = await fetch('/api/messages');
        const data = await response.json();

        if (data.success) {
            currentThreads = data.threads || [];
            displayMessages(currentThreads);
        } else {
            messagesList.innerHTML = '<div class="empty-state">Failed to load messages</div>';
        }
    } catch (error) {
        console.error('Error loading messages:', error);
        messagesList.innerHTML = '<div class="empty-state">Error loading messages</div>';
    }
}

function displayMessages(threads) {
    const messagesList = document.getElementById('messages-list');

    if (!threads.length) {
        messagesList.innerHTML = '<div class="empty-state">No messages in the last 48 hours</div>';
        return;
    }

    messagesList.innerHTML = threads.map((thread, index) => `
        <div class="message-thread-item" data-index="${index}">
            <div class="email-subject">${escapeHtml(thread.title || 'Unknown')}</div>
            <div class="email-meta">${formatDate(thread.last_date)} • ${thread.message_count} messages</div>
            <div class="message-preview">${escapeHtml(thread.last_message || '')}</div>
        </div>
    `).join('');

    document.querySelectorAll('.message-thread-item').forEach(item => {
        item.addEventListener('click', () => selectThread(parseInt(item.dataset.index, 10)));
    });
}

function selectThread(index) {
    selectedThread = currentThreads[index];
    document.querySelectorAll('.message-thread-item').forEach(item => item.classList.remove('selected'));
    const selectedEl = document.querySelector(`.message-thread-item[data-index="${index}"]`);
    if (selectedEl) selectedEl.classList.add('selected');

    summarizeGeneric(
        'messages',
        buildMessagesContent(selectedThread),
        selectedThread.title || 'Conversation',
        'messages-summary-content'
    );

    showChatInterfaceFor('messages');
}

function buildMessagesContent(thread) {
    const messages = (thread.messages || []).map(msg => {
        const sender = msg.sender || (msg.direction && msg.direction.toLowerCase() === 'outgoing' ? 'Me' : 'Unknown');
        return `${sender}: ${msg.text || ''}`;
    }).join('\n');
    return messages || 'No messages found.';
}

// Summarize generic content (calendar/reminders/messages)
async function summarizeGeneric(kind, content, title, targetId) {
    const summaryContent = document.getElementById(targetId);
    summaryContent.innerHTML = `
        <div class="summary-header">
            <h3>${escapeHtml(title)}</h3>
            <div class="summary-meta">Generating summary...</div>
        </div>
        <div class="loading"><span class="loading-spinner"></span> Working...</div>
    `;

    try {
        const response = await fetch('/api/summarize-generic', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                kind,
                title,
                content,
                model: selectedModel
            })
        });
        const data = await response.json();

        if (data.success) {
            summaryContent.innerHTML = `
                <div class="summary-header">
                    <h3>${escapeHtml(title)}</h3>
                    <div class="summary-meta">${data.model_used ? `Model: ${escapeHtml(data.model_used)}` : ''}</div>
                </div>
                <div class="summary-body">${escapeHtml(data.summary)}</div>
            `;
        } else {
            summaryContent.innerHTML = '<div class="empty-state">Failed to generate summary</div>';
        }
    } catch (error) {
        console.error('Error generating summary:', error);
        summaryContent.innerHTML = '<div class="empty-state">Error generating summary</div>';
    }
}

// Generate summary
async function generateSummary(email) {
    const summaryContent = document.getElementById('summary-content');
    
    if (useStreaming) {
        // Use streaming endpoint
        generateSummaryStream(email);
    } else {
        // Use regular endpoint
        summaryContent.innerHTML = `
            <div class="summary-header">
                <h3>${escapeHtml(email.subject || 'No Subject')}</h3>
                <div class="summary-meta">${escapeHtml(email.from || 'Unknown')} • ${formatDate(email.date)}</div>
            </div>
            <div class="loading"><span class="loading-spinner"></span> Generating summary...</div>
        `;
        
        try {
            const response = await fetch('/api/summarize', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    email_id: email.id,
                    body: email.body,
                    subject: email.subject,
                    sender: email.from,
                    date: email.date,
                    model: selectedModel
                })
            });
            
            const data = await response.json();
            
            if (data.success) {
                displaySummary(email, data.summary, data.model_used, data.cached);
                // Update email status
                email.has_summary = true;
                document.querySelector(`[data-index="${currentEmails.indexOf(email)}"]`).classList.add('has-summary');
            } else {
                summaryContent.innerHTML += '<div class="empty-state">Failed to generate summary</div>';
            }
        } catch (error) {
            console.error('Error generating summary:', error);
            summaryContent.innerHTML += '<div class="empty-state">Error generating summary</div>';
        }
    }
}

// Generate summary with streaming
async function generateSummaryStream(email) {
    const summaryContent = document.getElementById('summary-content');
    
    // Show different message based on email size
    let processingMsg = 'Processing email...';
    if (email.estimatedTokens > 20000) {
        processingMsg = 'Processing large email (this may take a moment)...';
    } else if (email.estimatedTokens > 10000) {
        processingMsg = 'Processing email...';
    }
    
    summaryContent.innerHTML = `
        <div class="summary-header">
            <h3>${escapeHtml(email.subject || 'No Subject')}</h3>
            <div class="summary-meta">${escapeHtml(email.from || 'Unknown')} • ${formatDate(email.date)}</div>
        </div>
        <div class="summary-body">
            <div style="color: #86868b; font-style: italic;">${processingMsg}</div>
            <span class="streaming-indicator"></span>
        </div>
    `;
    
    const summaryBody = summaryContent.querySelector('.summary-body');
    let fullSummary = '';
    let modelUsed = '';
    let isCached = false;
    
    try {
        const response = await fetch('/api/summarize-stream', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                email_id: email.id,
                body: email.body,
                subject: email.subject,
                sender: email.from,
                date: email.date,
                model: selectedModel
            })
        });
        
        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        
        while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            
            const chunk = decoder.decode(value);
            const lines = chunk.split('\n');
            
            for (const line of lines) {
                if (line.startsWith('data: ')) {
                    try {
                        const data = JSON.parse(line.slice(6));
                        
                        if (data.type === 'chunk') {
                            // First chunk - clear the processing message and show "Generating summary..."
                            if (fullSummary === '') {
                                summaryBody.innerHTML = '<div style="color: #86868b; font-style: italic; margin-bottom: 10px;">Generating summary...</div>';
                            }
                            fullSummary += data.content;
                            // Update content while keeping the status message
                            const statusMsg = fullSummary === data.content ? '<div style="color: #86868b; font-style: italic; margin-bottom: 10px;">Generating summary...</div>' : '';
                            summaryBody.innerHTML = statusMsg + escapeHtml(fullSummary) + '<span class="streaming-indicator"></span>';
                        } else if (data.type === 'model') {
                            modelUsed = data.content;
                        } else if (data.type === 'cached') {
                            isCached = data.value;
                        } else if (data.type === 'done') {
                            // Remove streaming indicator
                            summaryBody.innerHTML = escapeHtml(fullSummary);
                            
                            // Update meta info
                            const metaEl = summaryContent.querySelector('.summary-meta');
                            metaEl.innerHTML += ` • ${modelUsed}${isCached ? ' • (Cached)' : ''}`;
                            
                            // Update email status
                            email.has_summary = true;
                            document.querySelector(`[data-index="${currentEmails.indexOf(email)}"]`).classList.add('has-summary');
                            
                            // Store summary and show chat interface
                            currentSummary = fullSummary;
                            showChatInterface();
                        } else if (data.type === 'error') {
                            summaryBody.innerHTML = '<div class="empty-state">Failed to generate summary: ' + escapeHtml(data.content) + '</div>';
                        }
                    } catch (e) {
                        console.error('Error parsing SSE data:', e);
                    }
                }
            }
        }
    } catch (error) {
        console.error('Error streaming summary:', error);
        summaryBody.innerHTML = '<div class="empty-state">Error generating summary</div>';
    }
}

// Load existing summary
async function loadSummary(email) {
    // Since we already have the summary in the summarize response, we could cache it
    // For now, just regenerate it (it will be cached on the server)
    generateSummary(email);
}

// Display summary
function displaySummary(email, summary, modelUsed, cached) {
    const summaryContent = document.getElementById('summary-content');
    summaryContent.innerHTML = `
        <div class="summary-header">
            <h3>${escapeHtml(email.subject || 'No Subject')}</h3>
            <div class="summary-meta">
                ${escapeHtml(email.from || 'Unknown')} • ${formatDate(email.date)}
                ${modelUsed ? `• ${modelUsed}` : ''}
                ${cached ? ' • (Cached)' : ''}
            </div>
        </div>
        <div class="summary-body">${escapeHtml(summary)}</div>
    `;
    
    // Store summary and show chat interface
    currentSummary = summary;
    showChatInterface();
}

// Show all summaries
async function showAllSummaries() {
    const modal = document.getElementById('summaries-modal');
    const summariesList = document.getElementById('all-summaries-list');
    
    modal.classList.add('show');
    summariesList.innerHTML = '<div class="loading"><span class="loading-spinner"></span> Loading summaries...</div>';
    
    try {
        const response = await fetch('/api/summaries');
        const data = await response.json();
        
        if (data.success) {
            displayAllSummaries(data.summaries);
        } else {
            summariesList.innerHTML = '<div class="empty-state">Failed to load summaries</div>';
        }
    } catch (error) {
        console.error('Error loading summaries:', error);
        summariesList.innerHTML = '<div class="empty-state">Error loading summaries</div>';
    }
}

// Display all summaries
function displayAllSummaries(summaries) {
    const summariesList = document.getElementById('all-summaries-list');
    
    if (summaries.length === 0) {
        summariesList.innerHTML = '<div class="empty-state">No summaries found</div>';
        return;
    }
    
    summariesList.innerHTML = summaries.map(summary => `
        <div class="summary-list-item" data-id="${summary.id}">
            <h4>${escapeHtml(summary.subject || 'No Subject')}</h4>
            <div class="summary-list-meta">
                ${escapeHtml(summary.sender || 'Unknown')} • ${formatDate(summary.email_date)}
                • ${summary.model_used} • ${formatDate(summary.created_at)}
            </div>
            <div class="summary-list-text">${escapeHtml(summary.summary)}</div>
            <button class="delete-summary-btn" onclick="deleteSummary(${summary.id})">Delete</button>
        </div>
    `).join('');
}

// Delete summary
async function deleteSummary(id) {
    if (!confirm('Delete this summary?')) return;
    
    try {
        const response = await fetch(`/api/summaries/${id}`, { method: 'DELETE' });
        const data = await response.json();
        
        if (data.success) {
            showAllSummaries(); // Reload
            loadEmails(); // Update email status
        }
    } catch (error) {
        console.error('Error deleting summary:', error);
    }
}

// Clear all summaries
async function clearAllSummaries() {
    if (!confirm('Delete all summaries? This cannot be undone.')) return;
    
    try {
        const response = await fetch('/api/clear-all', { method: 'POST' });
        const data = await response.json();
        
        if (data.success) {
            document.getElementById('summaries-modal').classList.remove('show');
            loadEmails(); // Update email status
            
            // Clear the summary panel if an email was selected
            if (selectedEmail) {
                document.getElementById('summary-content').innerHTML = `
                    <div class="empty-state">
                        <p>All summaries deleted. Select an email to generate a new summary.</p>
                    </div>
                `;
            }
        }
    } catch (error) {
        console.error('Error clearing summaries:', error);
    }
}

// Utility functions
function escapeHtml(text) {
    if (!text) return '';
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

function formatDate(dateStr) {
    if (!dateStr) return 'Unknown date';
    try {
        const date = new Date(dateStr);
        return date.toLocaleString();
    } catch {
        return dateStr;
    }
}

// Show chat interface
function showChatInterface() {
    const chatContainer = document.getElementById('chat-container');
    chatContainer.style.display = 'block';
    
    // Show export button
    document.getElementById('export-email').style.display = 'inline-block';
    
    // Clear previous chat history when switching emails
    chatHistory = [];
    document.getElementById('chat-messages').innerHTML = '';
    document.getElementById('chat-input').value = '';
    document.getElementById('chat-input').focus();
}

function showChatInterfaceFor(tabName) {
    if (tabName === 'calendar') {
        const chatContainer = document.getElementById('calendar-chat-container');
        chatContainer.style.display = 'block';
        chatHistoryCalendar = [];
        document.getElementById('calendar-chat-messages').innerHTML = '';
        document.getElementById('calendar-chat-input').value = '';
        document.getElementById('calendar-chat-input').focus();
    } else if (tabName === 'messages') {
        const chatContainer = document.getElementById('messages-chat-container');
        chatContainer.style.display = 'block';
        chatHistoryMessages = [];
        document.getElementById('messages-chat-messages').innerHTML = '';
        document.getElementById('messages-chat-input').value = '';
        document.getElementById('messages-chat-input').focus();
    }
}

function buildGenericChatContext(baseContext, history) {
    if (!history.length) return baseContext;
    const historyText = history.slice(-4).map(msg => {
        const label = msg.role.toLowerCase() === 'user' ? 'Q' : 'A';
        return `${label}: ${msg.content}`;
    }).join('\n');
    return `${baseContext}\n\nPrevious conversation:\n${historyText}`;
}

// Send chat message
async function sendChatMessage() {
    const input = document.getElementById('chat-input');
    const question = input.value.trim();
    
    if (!question || !selectedEmail) return;
    
    // Add user message to chat
    addChatMessage(question, 'user');
    chatHistory.push({ role: 'User', content: question });
    
    // Clear input
    input.value = '';
    
    // Show loading message
    const loadingId = Date.now();
    addChatMessage('Thinking...', 'assistant loading', loadingId);
    
    try {
        const response = await fetch('/api/chat-stream', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                email_id: selectedEmail.id,
                email_body: selectedEmail.body,
                summary: currentSummary,
                question: question,
                chat_history: chatHistory,
                model: selectedModel
            })
        });
        
        // Remove loading message
        const loadingMsg = document.querySelector(`[data-message-id="${loadingId}"]`);
        if (loadingMsg) loadingMsg.remove();
        
        // Stream response
        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        let fullResponse = '';
        const responseId = Date.now() + 1;
        
        // Add empty message container for streaming
        addChatMessage('', 'assistant', responseId);
        const messageEl = document.querySelector(`[data-message-id="${responseId}"]`);
        
        while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            
            const chunk = decoder.decode(value);
            const lines = chunk.split('\n');
            
            for (const line of lines) {
                if (line.startsWith('data: ')) {
                    try {
                        const data = JSON.parse(line.slice(6));
                        
                        if (data.type === 'chunk') {
                            fullResponse += data.content;
                            messageEl.textContent = fullResponse;
                            // Auto-scroll to bottom
                            const chatMessages = document.getElementById('chat-messages');
                            chatMessages.scrollTop = chatMessages.scrollHeight;
                        } else if (data.type === 'done') {
                            // Add to chat history
                            chatHistory.push({ role: 'Assistant', content: fullResponse });
                        } else if (data.type === 'error') {
                            messageEl.textContent = 'Error: ' + data.content;
                            messageEl.classList.add('error');
                        }
                    } catch (e) {
                        console.error('Error parsing chat SSE data:', e);
                    }
                }
            }
        }
    } catch (error) {
        console.error('Error sending chat message:', error);
        // Remove loading message and show error
        const loadingMsg = document.querySelector(`[data-message-id="${loadingId}"]`);
        if (loadingMsg) {
            loadingMsg.textContent = 'Error: Failed to get response';
            loadingMsg.classList.add('error');
        }
    }
}

async function sendCalendarChatMessage() {
    const input = document.getElementById('calendar-chat-input');
    const question = input.value.trim();
    const contextSelection = selectedReminder
        ? { kind: 'reminder', context: buildReminderContent(selectedReminder) }
        : (selectedEvent ? { kind: 'calendar', context: buildCalendarContent(selectedEvent) } : null);

    if (!question || !contextSelection) return;

    addChatMessageTo('calendar-chat-messages', question, 'user');
    chatHistoryCalendar.push({ role: 'User', content: question });
    input.value = '';

    const loadingId = Date.now();
    addChatMessageTo('calendar-chat-messages', 'Thinking...', 'assistant loading', loadingId);

    const context = buildGenericChatContext(contextSelection.context, chatHistoryCalendar);

    try {
        const response = await fetch('/api/chat-generic-stream', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                kind: contextSelection.kind,
                context: context,
                question: question,
                model: selectedModel
            })
        });

        const loadingMsg = document.querySelector(`[data-message-id="${loadingId}"]`);
        if (loadingMsg) loadingMsg.remove();

        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        let fullResponse = '';
        const responseId = Date.now() + 1;

        addChatMessageTo('calendar-chat-messages', '', 'assistant', responseId);
        const messageEl = document.querySelector(`[data-message-id="${responseId}"]`);

        while (true) {
            const { done, value } = await reader.read();
            if (done) break;

            const chunk = decoder.decode(value);
            const lines = chunk.split('\n');

            for (const line of lines) {
                if (line.startsWith('data: ')) {
                    try {
                        const data = JSON.parse(line.slice(6));

                        if (data.type === 'chunk') {
                            fullResponse += data.content;
                            messageEl.textContent = fullResponse;
                            const chatMessages = document.getElementById('calendar-chat-messages');
                            chatMessages.scrollTop = chatMessages.scrollHeight;
                        } else if (data.type === 'done') {
                            chatHistoryCalendar.push({ role: 'Assistant', content: fullResponse });
                        } else if (data.type === 'error') {
                            messageEl.textContent = 'Error: ' + data.content;
                            messageEl.classList.add('error');
                        }
                    } catch (e) {
                        console.error('Error parsing chat SSE data:', e);
                    }
                }
            }
        }
    } catch (error) {
        console.error('Error sending calendar chat message:', error);
        const loadingMsg = document.querySelector(`[data-message-id="${loadingId}"]`);
        if (loadingMsg) {
            loadingMsg.textContent = 'Error: Failed to get response';
            loadingMsg.classList.add('error');
        }
    }
}

async function sendMessagesChatMessage() {
    const input = document.getElementById('messages-chat-input');
    const question = input.value.trim();

    if (!question || !selectedThread) return;

    addChatMessageTo('messages-chat-messages', question, 'user');
    chatHistoryMessages.push({ role: 'User', content: question });
    input.value = '';

    const loadingId = Date.now();
    addChatMessageTo('messages-chat-messages', 'Thinking...', 'assistant loading', loadingId);

    const context = buildGenericChatContext(buildMessagesContent(selectedThread), chatHistoryMessages);

    try {
        const response = await fetch('/api/chat-generic-stream', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                kind: 'messages',
                context: context,
                question: question,
                model: selectedModel
            })
        });

        const loadingMsg = document.querySelector(`[data-message-id="${loadingId}"]`);
        if (loadingMsg) loadingMsg.remove();

        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        let fullResponse = '';
        const responseId = Date.now() + 1;

        addChatMessageTo('messages-chat-messages', '', 'assistant', responseId);
        const messageEl = document.querySelector(`[data-message-id="${responseId}"]`);

        while (true) {
            const { done, value } = await reader.read();
            if (done) break;

            const chunk = decoder.decode(value);
            const lines = chunk.split('\n');

            for (const line of lines) {
                if (line.startsWith('data: ')) {
                    try {
                        const data = JSON.parse(line.slice(6));

                        if (data.type === 'chunk') {
                            fullResponse += data.content;
                            messageEl.textContent = fullResponse;
                            const chatMessages = document.getElementById('messages-chat-messages');
                            chatMessages.scrollTop = chatMessages.scrollHeight;
                        } else if (data.type === 'done') {
                            chatHistoryMessages.push({ role: 'Assistant', content: fullResponse });
                        } else if (data.type === 'error') {
                            messageEl.textContent = 'Error: ' + data.content;
                            messageEl.classList.add('error');
                        }
                    } catch (e) {
                        console.error('Error parsing chat SSE data:', e);
                    }
                }
            }
        }
    } catch (error) {
        console.error('Error sending messages chat message:', error);
        const loadingMsg = document.querySelector(`[data-message-id="${loadingId}"]`);
        if (loadingMsg) {
            loadingMsg.textContent = 'Error: Failed to get response';
            loadingMsg.classList.add('error');
        }
    }
}

// Add message to chat UI
function addChatMessage(content, className, messageId = null) {
    addChatMessageTo('chat-messages', content, className, messageId);
}

function addChatMessageTo(containerId, content, className, messageId = null) {
    const chatMessages = document.getElementById(containerId);
    const messageDiv = document.createElement('div');
    messageDiv.className = `chat-message ${className}`;
    messageDiv.textContent = content;

    if (messageId) {
        messageDiv.setAttribute('data-message-id', messageId);
    }

    chatMessages.appendChild(messageDiv);
    chatMessages.scrollTop = chatMessages.scrollHeight;
}

// Export email content
function exportEmail() {
    if (!selectedEmail) return;

    // Format the export content
    let exportContent = '=== EMAIL EXPORT ===\n\n';
    exportContent += `Date: ${formatDate(selectedEmail.date)}\n`;
    exportContent += `From: ${selectedEmail.from || 'Unknown'}\n`;
    exportContent += `Subject: ${selectedEmail.subject || 'No Subject'}\n`;
    exportContent += '\n--- ORIGINAL EMAIL ---\n\n';
    exportContent += selectedEmail.body || 'No content';

    if (currentSummary) {
        exportContent += '\n\n--- AI SUMMARY ---\n\n';
        exportContent += currentSummary;
    }

    if (chatHistory.length > 0) {
        exportContent += '\n\n--- CHAT CONVERSATION ---\n\n';
        chatHistory.forEach(msg => {
            exportContent += `${msg.role}: ${msg.content}\n\n`;
        });
    }

    exportContent += '\n=== END OF EXPORT ===\n';
    exportContent += `Exported on: ${new Date().toLocaleString()}\n`;
    exportContent += `Model used: ${selectedModel || 'Default'}\n`;

    // Create and download the file
    const blob = new Blob([exportContent], { type: 'text/plain' });
    const url = window.URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;

    // Create filename with date and subject
    const date = new Date();
    const dateStr = date.toISOString().split('T')[0];
    const safeSubject = (selectedEmail.subject || 'email').replace(/[^a-z0-9]/gi, '_').substring(0, 50);
    a.download = `email_${dateStr}_${safeSubject}.txt`;

    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    window.URL.revokeObjectURL(url);
}

// Daily Digest Functions
async function generateDailyDigest() {
    const modal = document.getElementById('digest-modal');
    const content = document.getElementById('digest-content');
    const btn = document.getElementById('generate-digest-btn');
    const exportBtn = document.getElementById('export-digest');
    const timestamp = document.getElementById('digest-timestamp');

    // Show modal and loading state
    modal.classList.add('show');
    btn.disabled = true;
    btn.textContent = 'Generating...';
    exportBtn.style.display = 'none';

    content.innerHTML = `
        <div class="digest-loading">
            <span class="loading-spinner"></span>
            <span class="digest-phase">Gathering your data...</span>
        </div>
    `;

    let fullDigest = '';
    let modelUsed = '';

    try {
        const response = await fetch('/api/digest', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ model: selectedModel })
        });

        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        let startedContent = false;

        while (true) {
            const { done, value } = await reader.read();
            if (done) break;

            const chunk = decoder.decode(value);
            const lines = chunk.split('\n');

            for (const line of lines) {
                if (line.startsWith('data: ')) {
                    try {
                        const data = JSON.parse(line.slice(6));

                        if (data.type === 'status') {
                            const phaseEl = content.querySelector('.digest-phase');
                            if (phaseEl) {
                                phaseEl.textContent = data.message;
                            }
                        } else if (data.type === 'chunk') {
                            if (!startedContent) {
                                content.innerHTML = '<div class="digest-body"></div>';
                                startedContent = true;
                            }
                            fullDigest += data.content;
                            content.querySelector('.digest-body').innerHTML =
                                formatDigestContent(fullDigest) + '<span class="streaming-indicator"></span>';
                        } else if (data.type === 'model') {
                            modelUsed = data.content;
                        } else if (data.type === 'done') {
                            content.querySelector('.digest-body').innerHTML = formatDigestContent(fullDigest);
                            timestamp.textContent = `Generated ${new Date().toLocaleString()} • ${modelUsed}`;
                            exportBtn.style.display = 'inline-block';
                            currentDigest = fullDigest;
                        } else if (data.type === 'error') {
                            content.innerHTML = `<div class="empty-state">Error: ${escapeHtml(data.content)}</div>`;
                        }
                    } catch (e) {
                        console.error('Error parsing digest SSE:', e);
                    }
                }
            }
        }
    } catch (error) {
        console.error('Error generating digest:', error);
        content.innerHTML = '<div class="empty-state">Failed to generate digest. Please try again.</div>';
    } finally {
        btn.disabled = false;
        btn.textContent = 'Generate Daily Digest';
    }
}

function formatDigestContent(text) {
    let formatted = escapeHtml(text);

    // Bold headers (**)
    formatted = formatted.replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>');

    // Markdown headers
    formatted = formatted.replace(/^### (.+)$/gm, '<h4>$1</h4>');
    formatted = formatted.replace(/^## (.+)$/gm, '<h3>$1</h3>');

    // List items
    formatted = formatted.replace(/^- (.+)$/gm, '<li>$1</li>');

    // Wrap consecutive <li> in <ul>
    formatted = formatted.replace(/(<li>.*<\/li>\n?)+/g, (match) => '<ul>' + match + '</ul>');

    // Numbered items
    formatted = formatted.replace(/^\d+\. (.+)$/gm, '<li>$1</li>');

    // Line breaks to paragraphs
    formatted = formatted.replace(/\n\n/g, '</p><p>');
    formatted = '<p>' + formatted + '</p>';

    // Clean up empty paragraphs
    formatted = formatted.replace(/<p>\s*<\/p>/g, '');

    return formatted;
}

function exportDigest() {
    if (!currentDigest) return;

    let exportContent = '=== DAILY DIGEST ===\n';
    exportContent += `Generated: ${new Date().toLocaleString()}\n`;
    exportContent += `Model: ${selectedModel || 'Default'}\n`;
    exportContent += '\n' + '='.repeat(50) + '\n\n';
    exportContent += currentDigest;
    exportContent += '\n\n' + '='.repeat(50) + '\n';
    exportContent += '=== END OF DIGEST ===\n';

    const blob = new Blob([exportContent], { type: 'text/plain' });
    const url = window.URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;

    const dateStr = new Date().toISOString().split('T')[0];
    a.download = `daily_digest_${dateStr}.txt`;

    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    window.URL.revokeObjectURL(url);
}
