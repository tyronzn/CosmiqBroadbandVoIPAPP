# Push notifications for incoming calls

This app can receive incoming calls while it's closed, using **FCM push +
RFC 8599 SIP push** (the same mechanism PortaSIP/PortaPhone uses). The client
side is built in; it activates once the two external pieces below are in place.

## How it works

```
Caller dials you
  → PortaSIP sees an incoming call for your account
  → PortaSIP sends an FCM push to your phone (using the pn-* params we register)
  → the push wakes the app
  → the app re-registers SIP and shows a full-screen "Incoming call" screen
  → Accept answers the INVITE; Decline rejects it
```

Until these are configured, `PushService.available` stays `false`, no `pn-*`
params are sent in REGISTER, and the app behaves exactly as before (it only
receives calls while open/registered).

## 1. Firebase project (your side — ~10 min)

1. Create a free Firebase project at <https://console.firebase.google.com>.
2. Add an **Android app** with package name **`za.co.cosmiq.voip`**.
3. Download the generated **`google-services.json`** and drop it in
   **`android/app/google-services.json`** (replacing the placeholder).
   - This file is git-ignored — it holds your project keys.
   - When present, the Gradle `google-services` plugin auto-applies (see
     `android/app/build.gradle`); when absent, the app builds with push disabled.
4. In Firebase → Project settings → Cloud Messaging, note the **Sender ID** and
   create/copy the **FCM credentials** (a service-account key for HTTP v1, or the
   legacy server key) — Backspace needs these to send pushes.

## 2. Backspace / PortaSIP (the dependency)

Ask Backspace to **enable RFC 8599 push notifications** for your account/product
and register your Firebase FCM credentials in PortaSIP's push gateway, so
PortaSIP can deliver pushes to *this* app. Without this, PortaSIP has nothing to
push with.

The app registers with these Contact parameters (already implemented):

```
Contact: <sip:<ext>@<ip>:5060;pn-provider=fcm;pn-param=<sender-id>;pn-prm=<fcm-token>>
```

PortaSIP reads `pn-provider`/`pn-param`/`pn-prm` and pushes via FCM on an
incoming call.

## 3. The push payload

PortaSIP should send an FCM **data** message (high priority) containing at least
a `caller` field, e.g. `{ "type": "incoming_call", "caller": "0821234567" }`.
The app renders that on the full-screen call notification.

## Client pieces (already in the repo)

| Piece | Where |
|-------|-------|
| FCM init, token, full-screen call notification | `lib/services/push_service.dart` |
| Background handler registration | `lib/main.dart` |
| `pn-*` params in SIP REGISTER | `CosmiqSipManager.kt` (`buildRegister`) |
| Accept/Decline → wake SIP & answer | `lib/services/app_state.dart` |
| Permissions / desugaring / google-services plugin | `android/app/build.gradle`, `AndroidManifest.xml` |

## Notes / future work

- The current incoming-call UI is a **full-screen notification**
  (`flutter_local_notifications`). For a true native call screen + ringtone,
  swap in `flutter_callkit_incoming` (Android Telecom / iOS CallKit).
- iOS would use **APNs + PushKit + CallKit** (not covered here; this build is
  Android-only).
