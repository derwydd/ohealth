# Prompt: OHealth iPhone companion

Paste this to the coding agent on the Mac. Build only the iOS app. The Linux app already listens.

---

Build a SwiftUI iPhone app named OHealth that reads the current user's HealthKit data and sends it to a paired Linux OHealth window on the same local network. Do not build a Linux app, a server, or an iCloud sync. HealthKit is on-device only.

## Discovery

Browse Bonjour for `_ohealth._tcp` in the local domain (`NWBrowser` or `NetServiceBrowser`). Each result is one computer. The TXT record has `v=1` and `fp` set to the SHA-256 fingerprint of the server certificate as 64 hex characters. Resolve the host and port from the service. Do not ask the user to type an IP address.

## TLS

Connect with TLS 1.2 or later. The server uses a self-signed certificate. Do not install or trust that certificate for the whole phone. Pin it for this connection:

1. After the handshake, SHA-256 the peer certificate's DER bytes.
2. Show that fingerprint in groups of two hex digits separated by colons.
3. Compare it to the TXT `fp` value, ignoring case and colons.
4. Before sending the pairing code, require the user to confirm the fingerprint matches the Certificate line in OHealth Settings on the computer. Cancel if they do not match or if the user rejects it.
5. Store the accepted fingerprint in the Keychain with the service name. Later connections to that service must present the same fingerprint. A mismatch is a failed connection, not a silent retry against a different certificate.

## Framing

One JSON object per message. Encode it as UTF-8. Prefix it with a 4-byte big-endian length. Reject a frame larger than 8,000,000 bytes. The computer answers with one frame for each frame the phone sends. An error reply looks like `{"type":"error","error":"..."}`. Show `error` to the user.

## Pairing

Settings on the computer has "Listen for an iPhone". When it is on and no phone is paired, it shows a 6-digit pairing code and the certificate fingerprint.

The phone UI:

- List discovered computers by their Bonjour name (`OHealth (hostname)`).
- After the user picks one and confirms the fingerprint, ask for the 6-digit code.
- Send:

```json
{"type":"pair","code":"482913","device":"Jason's iPhone"}
```

`device` is the phone's name, at most 64 characters.

A successful reply is:

```json
{"type":"paired","token":"<64 hex characters>","person":"Jason Brock","device":"Jason's iPhone"}
```

Store `token` in the Keychain. Store the Bonjour name beside it. Never put the token in logs, analytics, or a file outside the Keychain. The code works once. After this reply the computer clears the code and shows "Paired with {device}". Later syncs send the token, not the code. If pairing fails, show the error and let the user try the code again. If the computer says sync is turned off, say so.

Provide a way to forget the pairing, which deletes the token and fingerprint for that computer.

## Sync

Use `HKAnchoredObjectQuery` (or the async equivalent) so each sync sends only samples newer than the last anchor. Persist one anchor per HealthKit type. On first sync, send history. Batch at most 2000 samples per `sync` message, then send another message if more remain.

```json
{
  "type": "sync",
  "token": "<token from pairing>",
  "samples": [
    {
      "id": "HealthKit sample UUID",
      "day": "2026-09-26",
      "field": "steps",
      "op": "sum",
      "value": 1200,
      "unit": "count",
      "at": "2026-09-26T15:04:00Z"
    }
  ]
}
```

`day` is the sample start date in the phone's local calendar, `YYYY-MM-DD`. `at` is the sample start as ISO-8601. `id` is the HealthKit UUID string and must stay the same if the same sample is sent again. A successful reply is `{"type":"synced","saved":1,"days":1}`. `saved` counts samples the computer kept. Unknown fields are ignored.

Send these types only, already converted to the units below. Set `op` exactly as listed.

| HealthKit type | field | op | unit | value |
|---|---|---|---|---|
| Step count | steps | sum | count | count |
| Active energy burned | activeKcal | sum | kcal | kilocalories |
| Apple exercise time | exerciseMin | sum | min | minutes |
| Distance walking + running | distanceKm | sum | km | kilometers |
| Sleep analysis, asleep stages only (not in bed, not awake) | sleepHours | sleep | h | hours |
| Resting heart rate | restingHr | avg | count/min | beats per minute |
| Heart rate | heartRate | avg | count/min | beats per minute |
| Heart rate variability SDNN | hrv | avg | ms | milliseconds |
| Oxygen saturation | spo2 | avg | % | percent, 95 not 0.95 |
| Respiratory rate | respiratory | avg | count/min | breaths per minute |
| Body mass | weightKg | last | kg | kilograms |

Request read permission for those types and explain why. If the user denies a type, skip it and keep syncing the others. Do not send workouts, ECG, medical records, documents, or anything else.

## When to sync

Add a button to sync now, and sync when the app becomes active if a token is stored and a matching service is visible. If the service is missing, say the computer is not listening. Do not poll forever in the background. A manual sync is enough for the first version. Background delivery can wait.

## App shape

- One screen lists computers found on the network.
- Pairing is a code field plus the certificate fingerprint.
- After pairing, the screen shows the computer name, the person name from the paired reply, the last sync time, and Sync now.
- Keep the interface native SwiftUI. No accounts, no Apple ID login, no analytics, and no third-party health SDK.
- The deployment target can be a current iOS. Use HealthKit and the Network framework.

The computer saves samples for whichever person is open in the Linux window. Say that on the sync screen so the user opens the right person before syncing.
