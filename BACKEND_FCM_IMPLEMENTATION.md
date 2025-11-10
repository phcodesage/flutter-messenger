# Backend FCM Implementation Guide

Your Flutter app is ready to receive push notifications, but your Flask backend needs to send them!

## 🔴 Current Issue

When the app is in the background:
- ✅ Socket.IO events are received (you can see them in logs)
- ❌ **No push notifications appear** (because backend isn't sending FCM notifications)

## ✅ Solution: Backend Must Send FCM Notifications

---

## Step 1: Install Firebase Admin SDK

On your Flask server:

```bash
pip install firebase-admin
```

---

## Step 2: Get Firebase Service Account Key

1. Go to [Firebase Console](https://console.firebase.google.com/)
2. Select your project: **flutter-messaging-ee4ea**
3. Click **Project Settings** (gear icon) → **Service Accounts**
4. Click **"Generate new private key"**
5. Download the JSON file
6. Rename it to `firebase-credentials.json`
7. Place it in your Flask project root directory
8. **IMPORTANT**: Add to `.gitignore`:
   ```
   firebase-credentials.json
   ```

---

## Step 3: Create Firebase Messaging Utility

Create `app/utils/firebase_messaging.py`:

```python
import firebase_admin
from firebase_admin import credentials, messaging
import os

# Initialize Firebase Admin SDK (only once)
if not firebase_admin._apps:
    cred_path = os.path.join(os.path.dirname(__file__), '../../firebase-credentials.json')
    cred = credentials.Certificate(cred_path)
    firebase_admin.initialize_app(cred)

def send_push_notification(fcm_token, title, body, data=None):
    """
    Send push notification to a device
    
    Args:
        fcm_token: FCM token of the device
        title: Notification title
        body: Notification body
        data: Additional data payload (dict)
    
    Returns:
        bool: True if successful, False otherwise
    """
    if not fcm_token:
        print("❌ No FCM token provided")
        return False
    
    try:
        message = messaging.Message(
            notification=messaging.Notification(
                title=title,
                body=body,
            ),
            data=data or {},
            token=fcm_token,
            android=messaging.AndroidConfig(
                priority='high',
                notification=messaging.AndroidNotification(
                    sound='default',
                    channel_id='chat_messages',
                    click_action='FLUTTER_NOTIFICATION_CLICK',
                ),
            ),
            apns=messaging.APNSConfig(
                payload=messaging.APNSPayload(
                    aps=messaging.Aps(
                        sound='default',
                        badge=1,
                        content_available=True,
                    ),
                ),
            ),
        )
        
        response = messaging.send(message)
        print(f"✅ Push notification sent: {response}")
        return True
        
    except Exception as e:
        print(f"❌ Error sending push notification: {str(e)}")
        return False

def send_message_notification(fcm_token, sender_name, message_content, sender_id):
    """Send notification for new message"""
    return send_push_notification(
        fcm_token=fcm_token,
        title=f"💬 {sender_name}",
        body=message_content[:100],  # Truncate long messages
        data={
            'type': 'message',
            'sender_id': str(sender_id),
            'sender_name': sender_name,
            'click_action': 'FLUTTER_NOTIFICATION_CLICK',
        }
    )

def send_doorbell_notification(fcm_token, sender_name, sender_id):
    """Send notification for doorbell ring"""
    return send_push_notification(
        fcm_token=fcm_token,
        title=f"🔔 {sender_name} is calling",
        body="Tap to open chat",
        data={
            'type': 'doorbell',
            'sender_id': str(sender_id),
            'sender_name': sender_name,
            'click_action': 'FLUTTER_NOTIFICATION_CLICK',
        }
    )

def send_color_change_notification(fcm_token, sender_name, sender_id, color):
    """Send notification for color change"""
    return send_push_notification(
        fcm_token=fcm_token,
        title=f"🎨 {sender_name}",
        body=f"Changed your chat color to {color}",
        data={
            'type': 'color_change',
            'sender_id': str(sender_id),
            'sender_name': sender_name,
            'color': color,
            'click_action': 'FLUTTER_NOTIFICATION_CLICK',
        }
    )
```

---

## Step 4: Update User Model

Add FCM token field to your User model in `app/models/user.py`:

```python
class User(db.Model, UserMixin):
    # ... existing fields ...
    fcm_token = db.Column(db.String(255), nullable=True)
    
    def update_fcm_token(self, token):
        """Update user's FCM token"""
        self.fcm_token = token
        db.session.commit()
        print(f"✅ FCM token updated for user {self.id}")
```

Don't forget to create a migration:

```bash
flask db migrate -m "Add fcm_token to User model"
flask db upgrade
```

---

## Step 5: Create FCM Token API Endpoint

Create or update `app/api/user.py`:

```python
from flask import Blueprint, request, jsonify
from flask_login import login_required, current_user
from app.models.user import User
from app import db

user_bp = Blueprint('user_api', __name__)

@user_bp.route('/fcm-token', methods=['POST'])
@login_required
def update_fcm_token():
    """Update user's FCM token"""
    data = request.get_json()
    fcm_token = data.get('fcm_token')
    
    if not fcm_token:
        return jsonify({'error': 'FCM token required'}), 400
    
    current_user.update_fcm_token(fcm_token)
    
    return jsonify({
        'success': True,
        'message': 'FCM token updated'
    }), 200

@user_bp.route('/fcm-token', methods=['DELETE'])
@login_required
def remove_fcm_token():
    """Remove user's FCM token (on logout)"""
    current_user.update_fcm_token(None)
    
    return jsonify({
        'success': True,
        'message': 'FCM token removed'
    }), 200
```

Register the blueprint in `app/__init__.py`:

```python
from app.api.user import user_bp
app.register_blueprint(user_bp, url_prefix='/api/user')
```

---

## Step 6: Update Socket.IO Event Handlers

Update `app/utils/socket_events.py` to send FCM notifications:

```python
from app.utils.firebase_messaging import (
    send_message_notification,
    send_doorbell_notification,
    send_color_change_notification
)
from app.models.user import User

@socketio.on('send_message')
def handle_send_message(data):
    user = get_authenticated_user()
    if not user:
        return
    
    recipient_id = data.get('recipient_id')
    content = data.get('content')
    message_type = data.get('message_type', 'text')
    
    # ... existing message handling code ...
    
    # ✅ Send push notification if recipient has FCM token
    recipient = User.query.get(recipient_id)
    if recipient and recipient.fcm_token:
        send_message_notification(
            fcm_token=recipient.fcm_token,
            sender_name=user.full_name or user.username,
            message_content=content,
            sender_id=user.id
        )
        print(f"📱 Push notification sent to user {recipient_id}")

@socketio.on('ring_doorbell')
def handle_ring_doorbell(data):
    user = get_authenticated_user()
    if not user:
        return
    
    recipient_id = data.get('recipient_id')
    
    # ... existing doorbell handling code ...
    
    # ✅ Send push notification
    recipient = User.query.get(recipient_id)
    if recipient and recipient.fcm_token:
        send_doorbell_notification(
            fcm_token=recipient.fcm_token,
            sender_name=user.full_name or user.username,
            sender_id=user.id
        )
        print(f"🔔 Doorbell notification sent to user {recipient_id}")

@socketio.on('change_color')
def handle_change_color(data):
    user = get_authenticated_user()
    if not user:
        return
    
    recipient_id = data.get('recipient_id')
    color = data.get('color')
    
    # ... existing color change handling code ...
    
    # ✅ Send push notification
    recipient = User.query.get(recipient_id)
    if recipient and recipient.fcm_token:
        send_color_change_notification(
            fcm_token=recipient.fcm_token,
            sender_name=user.full_name or user.username,
            sender_id=user.id,
            color=color
        )
        print(f"🎨 Color change notification sent to user {recipient_id}")
```

---

## Step 7: Test the Implementation

### 1. Restart Flask Server

```bash
flask run
```

### 2. Test Flow

1. **Login to Flutter app** → FCM token is sent to backend
2. **Put app in background** (press home button)
3. **Send message from web** → Should see notification!
4. **Tap notification** → App opens to chat

### 3. Check Logs

**Flask logs should show:**
```
✅ FCM token updated for user 3
📱 Push notification sent to user 3
✅ Push notification sent: projects/flutter-messaging-ee4ea/messages/...
```

**Flutter logs should show:**
```
📱 FCM Token: [token]
✅ FCM token sent to backend successfully
📨 Foreground message received: 💬 rech
```

---

## 🧪 Testing Checklist

- [ ] Flask server has `firebase-admin` installed
- [ ] `firebase-credentials.json` is in project root
- [ ] User model has `fcm_token` field
- [ ] `/api/user/fcm-token` endpoint works
- [ ] Socket.IO handlers send FCM notifications
- [ ] App in background receives notifications
- [ ] Tapping notification opens the app
- [ ] Notification shows sender name and message

---

## 🔧 Troubleshooting

### No notifications received:
1. Check if FCM token was saved in database
2. Check Flask logs for FCM errors
3. Verify `firebase-credentials.json` is correct
4. Make sure app has notification permissions

### Notifications not opening app:
1. Check `click_action` is set to `FLUTTER_NOTIFICATION_CLICK`
2. Verify notification handler is set up in Flutter

### FCM token not sent to backend:
1. Check network connectivity
2. Verify `/api/user/fcm-token` endpoint exists
3. Check if user is authenticated

---

## 📝 Summary

Your Flutter app is **100% ready** to receive notifications. Now you need to:

1. ✅ Install `firebase-admin` on Flask server
2. ✅ Add `firebase-credentials.json` to Flask project
3. ✅ Create `firebase_messaging.py` utility
4. ✅ Add `fcm_token` field to User model
5. ✅ Create `/api/user/fcm-token` endpoint
6. ✅ Update Socket.IO handlers to send FCM notifications

Once done, your app will show WhatsApp-style notifications even when in background! 🔔📱
