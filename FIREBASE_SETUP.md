# Firebase Cloud Messaging Setup Guide

This guide will help you complete the Firebase setup for push notifications in your Flutter Messenger app.

---

## ✅ What's Already Done

- ✅ Firebase dependencies added to `pubspec.yaml`
- ✅ `FirebaseMessagingService` created
- ✅ `FCMService` created for backend communication
- ✅ `main.dart` updated to initialize Firebase
- ✅ Notification handling implemented (foreground, background, terminated)

---

## 📋 What You Need to Do

### Step 1: Download Firebase Configuration Files

Since you already have a Firebase project, you need to download the configuration files:

#### For Android:

1. Go to [Firebase Console](https://console.firebase.google.com/)
2. Select your project
3. Click on **Project Settings** (gear icon)
4. Scroll down to **Your apps** section
5. If you haven't added an Android app yet:
   - Click **Add app** → **Android**
   - Enter package name: `com.example.flutter_messenger` (or your actual package name)
   - Click **Register app**
6. Download `google-services.json`
7. Place it in: `android/app/google-services.json`

#### For iOS (if supporting iOS):

1. In Firebase Console → **Project Settings** → **Your apps**
2. Click **Add app** → **iOS**
3. Enter bundle ID: `com.example.flutterMessenger`
4. Download `GoogleService-Info.plist`
5. Add it to your iOS project in Xcode

---

### Step 2: Update Firebase Options

You have two options:

#### Option A: Use FlutterFire CLI (Recommended)

```bash
# Install FlutterFire CLI
dart pub global activate flutterfire_cli

# Configure Firebase
flutterfire configure
```

This will automatically generate `lib/firebase_options.dart` with your Firebase configuration.

#### Option B: Manual Configuration

1. Go to Firebase Console → **Project Settings**
2. Scroll to **Your apps** → Select your Android/iOS app
3. Copy the configuration values
4. Update `lib/firebase_options.dart` with your actual values:

```dart
static const FirebaseOptions android = FirebaseOptions(
  apiKey: 'YOUR_ACTUAL_API_KEY',
  appId: 'YOUR_ACTUAL_APP_ID',
  messagingSenderId: 'YOUR_ACTUAL_SENDER_ID',
  projectId: 'YOUR_ACTUAL_PROJECT_ID',
  storageBucket: 'YOUR_ACTUAL_STORAGE_BUCKET',
);
```

---

### Step 3: Configure Android

#### 3.1 Update `android/build.gradle`:

```gradle
buildscript {
    dependencies {
        classpath 'com.android.tools.build:gradle:7.3.0'
        classpath 'org.jetbrains.kotlin:kotlin-gradle-plugin:1.7.10'
        classpath 'com.google.gms:google-services:4.4.0'  // ← Add this
    }
}
```

#### 3.2 Update `android/app/build.gradle`:

Add at the **bottom** of the file:

```gradle
apply plugin: 'com.google.gms.google-services'  // ← Add this line
```

Also add Firebase dependencies:

```gradle
dependencies {
    implementation platform('com.google.firebase:firebase-bom:32.7.0')
    implementation 'com.google.firebase:firebase-messaging'
}
```

#### 3.3 Update `android/app/src/main/AndroidManifest.xml`:

Add permissions and FCM service:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <!-- Add these permissions -->
    <uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.VIBRATE"/>
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
    
    <application>
        <!-- Your existing config -->
        
        <!-- Add FCM Service -->
        <service
            android:name="com.google.firebase.messaging.FirebaseMessagingService"
            android:exported="false">
            <intent-filter>
                <action android:name="com.google.firebase.MESSAGING_EVENT"/>
            </intent-filter>
        </service>
        
        <!-- Notification metadata -->
        <meta-data
            android:name="com.google.firebase.messaging.default_notification_icon"
            android:resource="@mipmap/ic_launcher" />
        
        <meta-data
            android:name="com.google.firebase.messaging.default_notification_color"
            android:resource="@android:color/holo_blue_dark" />
    </application>
</manifest>
```

---

### Step 4: Install Dependencies

Run in your terminal:

```bash
flutter pub get
```

---

### Step 5: Test FCM Token Generation

1. Run your app on a real device (emulator may not work reliably)
2. Check the console logs for:
   ```
   ✅ User granted notification permission
   📱 FCM Token: [your-fcm-token]
   ✅ FCM token sent to backend successfully
   ```

---

### Step 6: Backend Setup (Flask)

Your backend needs to:

1. **Add FCM token endpoint** (already created in your code)
2. **Install Firebase Admin SDK**:
   ```bash
   pip install firebase-admin
   ```

3. **Download Service Account Key**:
   - Firebase Console → **Project Settings** → **Service Accounts**
   - Click **Generate new private key**
   - Save as `firebase-credentials.json` in your Flask project root
   - **Add to `.gitignore`!**

4. **Initialize Firebase Admin in Flask** (create `app/utils/firebase_messaging.py`):

```python
import firebase_admin
from firebase_admin import credentials, messaging

cred = credentials.Certificate('firebase-credentials.json')
firebase_admin.initialize_app(cred)

def send_push_notification(fcm_token, title, body, data=None):
    message = messaging.Message(
        notification=messaging.Notification(title=title, body=body),
        data=data or {},
        token=fcm_token,
    )
    return messaging.send(message)
```

5. **Send notifications from Socket.IO events**:

```python
from app.utils.firebase_messaging import send_push_notification

@socketio.on('send_message')
def handle_send_message(data):
    # ... existing code ...
    
    # Send push notification
    recipient = User.query.get(recipient_id)
    if recipient and recipient.fcm_token:
        send_push_notification(
            fcm_token=recipient.fcm_token,
            title=f"New message from {user.full_name}",
            body=content,
            data={'type': 'message', 'sender_id': str(user.id)}
        )
```

---

## 🧪 Testing

### Test Notification Reception:

1. **Install app** on a real Android device
2. **Login** to the app
3. **Close the app** completely (swipe away from recent apps)
4. **Send a message** from another device/web
5. **Check device** - you should see a notification!

### Test Notification Tap:

1. **Receive a notification**
2. **Tap the notification**
3. **App should open** to the relevant chat

---

## 🔧 Troubleshooting

### No FCM Token Generated:
- Check if permissions were granted
- Make sure you're testing on a real device
- Check Firebase Console for any errors

### Notifications Not Received:
- Verify `google-services.json` is in the correct location
- Check if FCM token was sent to backend successfully
- Verify backend is sending notifications (check Flask logs)
- Make sure the app has notification permissions

### App Crashes on Startup:
- Make sure `google-services.json` is properly configured
- Check if all Firebase dependencies are added correctly
- Run `flutter clean` and `flutter pub get`

---

## 📝 Next Steps

After completing the setup:

1. ✅ Run `flutter pub get`
2. ✅ Add `google-services.json` to `android/app/`
3. ✅ Update `firebase_options.dart` with your config
4. ✅ Configure Android build files
5. ✅ Test on a real device
6. ✅ Set up backend to send notifications

---

## 🎉 Success Indicators

You'll know it's working when you see:

- ✅ `📱 FCM Token: [token]` in console
- ✅ `✅ FCM token sent to backend successfully`
- ✅ Notifications appear when app is closed
- ✅ Tapping notification opens the app

---

For more help, check the [Firebase documentation](https://firebase.google.com/docs/cloud-messaging/flutter/client).
