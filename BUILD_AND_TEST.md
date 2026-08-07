# Build and Test Instructions

## Quick Start

### 0. Build macOS Desktop App

Run the macOS build script:
```bash
chmod +x ./build_macos_app.sh
./build_macos_app.sh --release --open
```

If full Xcode is installed but your machine still points to Command Line Tools, use:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./build_macos_app.sh --release --open
```

Note: CocoaPods is required for Flutter macOS plugin builds.

### 1. Build and Install (Windows)

Run the provided batch script:
```bash
./build_and_install.bat
```

Or manually:
```bash
flutter clean
flutter pub get
flutter build apk --release
adb install --user 0 -r build/app/outputs/flutter-apk/app-release.apk
```

### 2. Test the Screenshare Fix

#### Test Case 1: Mobile-to-Web Video Call (PRIMARY)
1. Start the mobile app (with fixes)
2. Open web client in browser
3. Initiate video call from mobile to web
4. Once connected, tap screenshare button on mobile
5. **Expected**: Web user sees screenshare immediately (not frozen)
6. Stop screenshare on mobile
7. **Expected**: Web user sees camera feed again

#### Test Case 2: Web-to-Mobile Video Call
1. Start video call from web to mobile
2. Start screenshare on web
3. **Expected**: Mobile user sees screenshare
4. Stop screenshare on web
5. **Expected**: Mobile user sees camera feed

#### Test Case 3: Audio Call with Screenshare
1. Start audio call between mobile and web
2. Start screenshare on mobile
3. **Expected**: Video appears showing screenshare
4. Stop screenshare
5. **Expected**: Returns to audio-only call

---

## Debug Logs to Monitor

### On Mobile (Flutter logs)

**When starting screenshare:**
```
🖥️ Starting screen share...
🖥️ Replaced existing video track with screen share
🔄 Triggering renegotiation: screen-share-started
✅ Renegotiation offer sent: screen-share-started
✅ Screen sharing started
```

**When stopping screenshare:**
```
🖥️ Stopping screen share...
🖥️ Restored original video track
🔄 Triggering renegotiation: screen-share-stopped
✅ Renegotiation offer sent: screen-share-stopped
✅ Screen sharing stopped
```

**When receiving remote screenshare:**
```
🎥 Received remote track: video, streams: 1
🎥 Stream ID: [stream-id]
🖥️ Detected remote screen share stream: [stream-id]
```

### View Logs

```bash
# Real-time logs
adb logcat | grep -E "flutter|WebRTC"

# Or use Flutter
flutter logs
```

---

## Troubleshooting

### Issue: Screenshare still freezes on web

**Check:**
1. Web client is receiving renegotiation offers
2. Web client is handling `renegotiate: true` flag
3. Web client is updating SDP on renegotiation
4. Network connectivity is stable

**Debug:**
```bash
# Check mobile logs for renegotiation
adb logcat | grep "Triggering renegotiation"

# Should see:
# 🔄 Triggering renegotiation: screen-share-started
```

### Issue: ICE connection fails during renegotiation

**Check:**
1. ICE servers are configured correctly
2. TURN server credentials are valid
3. Firewall allows WebRTC traffic

**Debug:**
```bash
# Monitor ICE state
adb logcat | grep "ICE connection state"
```

### Issue: App crashes when starting screenshare

**Check:**
1. Android permissions for screen capture
2. Foreground service is starting correctly
3. Media projection permission granted

**Debug:**
```bash
# Check for permission errors
adb logcat | grep -E "Permission|MediaProjection"
```

---

## Performance Testing

### Monitor Renegotiation Latency

Time between:
1. User taps screenshare button
2. Remote user sees screenshare

**Expected**: 200-500ms

### Monitor Memory Usage

```bash
# Check memory before/after screenshare
adb shell dumpsys meminfo com.example.flutter_messenger_v2
```

**Expected**: No significant memory leaks after multiple screenshare toggles

### Monitor Network Traffic

Use Chrome DevTools (for web client) or Wireshark to monitor:
- SDP offer/answer exchanges
- ICE candidate exchanges
- Media stream changes

---

## Regression Testing

Ensure existing functionality still works:

- [ ] Regular video calls (no screenshare)
- [ ] Regular audio calls
- [ ] Call accept/reject
- [ ] Call end
- [ ] Mute/unmute audio
- [ ] Enable/disable video
- [ ] Multiple calls in sequence
- [ ] Network reconnection

---

## Web Client Verification

The web client must handle these signals:

### 1. Renegotiation Offer
```javascript
socket.on('signal', (data) => {
  if (data.signal.renegotiate === true) {
    // Auto-accept renegotiation
    await peerConnection.setRemoteDescription(
      new RTCSessionDescription({
        type: 'offer',
        sdp: data.signal.sdp
      })
    );
    
    const answer = await peerConnection.createAnswer();
    await peerConnection.setLocalDescription(answer);
    
    socket.emit('signal', {
      room: roomId,
      signal: {
        type: 'answer',
        sdp: answer.sdp,
        renegotiate: true
      }
    });
  }
});
```

### 2. Track Changes
```javascript
peerConnection.ontrack = (event) => {
  console.log('Received track:', event.track.kind);
  console.log('Stream ID:', event.streams[0].id);
  
  // Update video element
  remoteVideo.srcObject = event.streams[0];
};
```

### 3. Screen Share Signals (Optional)
```javascript
socket.on('screen_share_started', (data) => {
  console.log('Remote started screenshare');
  // Update UI to show screenshare indicator
});

socket.on('screen_share_stopped', (data) => {
  console.log('Remote stopped screenshare');
  // Update UI to remove screenshare indicator
});
```

---

## Success Criteria

✅ **Fix is successful if:**
1. Web user sees mobile screenshare without freezing
2. Screenshare can be started/stopped multiple times
3. Camera feed resumes correctly after screenshare stops
4. No ICE connection failures during renegotiation
5. No memory leaks after multiple operations
6. Existing call functionality remains intact

---

## Next Steps After Testing

1. Test with multiple web browsers (Chrome, Firefox, Safari)
2. Test with different network conditions (WiFi, 4G, 5G)
3. Test with multiple participants (if supported)
4. Monitor production logs for any issues
5. Gather user feedback on screenshare quality

---

## Support

If issues persist:
1. Check `SCREENSHARE_ANALYSIS.md` for detailed technical analysis
2. Check `SCREENSHARE_FIX_SUMMARY.md` for implementation details
3. Review web client code for proper renegotiation handling
4. Verify ICE server configuration
5. Check network/firewall settings
