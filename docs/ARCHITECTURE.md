# Orbit Architecture

This document explains how the pieces fit together. The wire format itself is defined only in [PROTOCOL.md](PROTOCOL.md), and the look and feel only in [DESIGN.md](DESIGN.md); this file refers to them and does not redefine them. It describes the design both implementations follow; module and file names in `desktop/src` and `mobile/lib` may differ in detail.

## Components

```mermaid
flowchart TB
    subgraph Mobile["mobile/ (Flutter app)"]
        direction TB
        Screens["Screens<br/>Discovery · Pairing · Trackpad · Air · Keys · Media · Settings"]
        Gestures["Gesture engine<br/>touch to MOVE / CLICK / SCROLL / GESTURE"]
        Motion["Motion sensor<br/>gyro to AIM yaw/pitch"]
        Disc["Discovery<br/>mDNS browse + ORBIT?1 broadcast + manual IP"]
        PairC["Pairing client<br/>TCP, X25519, HKDF"]
        Store["Paired hosts store<br/>hostId, name, os, key"]
        Session["Host session<br/>session id, seq, PING/PONG, latency"]
        Codec["Packet codec<br/>ChaCha20-Poly1305"]
        Screens --> Gestures --> Session
        Screens --> Motion --> Session
        Screens --> Disc
        Screens --> PairC --> Store
        Store --> Session --> Codec
    end

    subgraph Desktop["desktop/ (Rust agent, binary orbit)"]
        direction TB
        Tray["Tray / menu bar + pairing dialog"]
        Adv["mDNS advertiser<br/>_orbit._tcp"]
        PairS["Pairing server<br/>TCP 47821"]
        Devices["Paired devices store<br/>deviceId, name, key"]
        Ctrl["Control receiver<br/>UDP 47821: decrypt, anti-replay"]
        Inject["Input injector<br/>CGEvent (macOS) / SendInput (Windows)"]
        PairS --> Tray
        PairS --> Devices --> Ctrl --> Inject
    end

    Disc -.->|"mDNS / broadcast"| Adv
    PairC <-->|"TCP JSON lines"| PairS
    Codec -->|"UDP packets"| Ctrl
    Ctrl -->|"PONG"| Codec
```

| Component | Responsibility |
|---|---|
| **Gesture engine** (mobile) | Turns raw multitouch into protocol messages: pointer acceleration, tap / double-tap / two-finger tap, scroll with inertia, tap-and-hold drag (BUTTON down/up), pinch (GESTURE zoom), three-finger swipes (overview or host switch). |
| **Motion sensor** (mobile) | Integrates the gyroscope into yaw / pitch relative to the calibrated center and sends AIM while the lens button is held. Smoothing happens on the host. |
| **Discovery** (mobile) | Browses `_orbit._tcp`, sends `ORBIT?1` broadcasts as a fallback, merges results by `hostId`. |
| **Pairing client / server** | One TCP connection per pairing. Ephemeral X25519, HKDF-SHA256 key and 6-digit code, user confirmation on the host. |
| **Host session** (mobile) | Owns the UDP socket for the active host, the random `session`, the monotonically increasing `seq`, the 1 s PING timer and the latency estimate shown in the host pill. |
| **Control receiver** (desktop) | Validates header, looks up the key by `deviceId`, decrypts, enforces the session / seq rule, answers PING with PONG, tracks liveness (3 s). |
| **Input injector** (desktop) | Maps messages to OS input: relative moves, buttons, clicks with click count, pixel scrolling with fractional accumulation, OS shortcuts for GESTURE, HID usage to native key codes, text typing, media keys, AIM mapping onto the virtual desktop with a 1€ filter. |

## Desktop agent: threading

The agent is a single process with a few long-lived threads that communicate over channels. No thread blocks another for longer than one packet.

```mermaid
flowchart LR
    Main["Main thread<br/>OS event loop, tray, native dialogs"]
    Mdns["mDNS thread<br/>advertise _orbit._tcp"]
    Tcp["Pairing thread<br/>TCP accept + one handler per connection"]
    Udp["Control thread<br/>UDP recv: broadcast replies, decrypt, PONG"]
    Inj["Injector<br/>OS input calls, held-input tracking"]
    Dog["Watchdog tick<br/>release input after 3 s of silence"]

    Tcp -->|"confirm request"| Main
    Main -->|"Allow / Deny"| Tcp
    Tcp -->|"new key"| Store[("Paired devices<br/>shared, persisted")]
    Store --> Udp
    Udp -->|"decoded messages"| Inj
    Dog --> Inj
```

- **Main thread.** macOS requires AppKit (the status item and the *Allow / Deny* alert) to run on the main thread, and Windows tray icons need a message loop, so the main thread runs the platform event loop and nothing else. Other threads ask it to show the pairing dialog and wait for the answer, with the 60 s timeout from the protocol.
- **mDNS thread.** Registers the service with TXT records `id`, `name`, `os`, `v`, and unregisters on exit.
- **Pairing thread.** Accepts TCP connections on 47821. Each pairing is handled in its own short-lived handler so a slow or malicious client cannot block another pairing. On *Allow* it writes the new `(deviceId, name, key)` to the store; re-pairing replaces the key.
- **Control thread.** One UDP socket on 47821. Plain `ORBIT?1` probes get the JSON `here` reply; every other payload must be a valid encrypted packet or it is dropped silently. Per device it keeps `last session`, `last seq` and `last seen`.
- **Injector.** Owns all OS input state: currently held buttons and keys, scroll fraction accumulators, the 1€ filter state for AIM. Keeping this in one place makes "release everything" on BYE or timeout trivial and race-free.
- **Watchdog.** A periodic tick (well under a second) checks `last seen`; a device silent for more than 3 s is marked disconnected and its held input is released.
- **Store.** The paired-devices table is shared between the pairing and control threads behind a lock and persisted to the user's configuration directory on every change.

## Mobile app: state flow

```mermaid
stateDiagram-v2
    [*] --> Discovery: no paired hosts
    [*] --> Connected: last active host known
    Discovery --> Pairing: tap a host bubble or enter IP
    Pairing --> Discovery: denied / timeout / cancel
    Pairing --> Connected: paired ok, key saved
    Connected --> Connected: three-finger swipe or host switcher (switch host)
    Connected --> Reconnecting: no PONG for 3 s
    Reconnecting --> Connected: PONG received
    Reconnecting --> Discovery: user picks another computer
    Connected --> Discovery: Add computer
```

- **App state** holds: the list of discovered hosts, the paired-hosts store, the active host, the current mode (Trackpad / Air / Keys / Media) and user settings (pointer speed, acceleration, scroll speed, natural scrolling, haptics, tap-to-click, theme).
- **Discovered vs paired.** A discovered host is just an address and a name. A paired host has a key. Hosts are matched by `hostId`, so a computer that changes its IP is still recognised as the same paired host when it is rediscovered.
- **Switching computers.** Three-finger swipe left / right (or the host switcher sheet) sends BYE to the current host, picks the previous / next paired host, starts a new random `session` with `seq = 1` and starts pinging. The host pill crossfades, and the medium haptic fires once the switch is made.
- **Sending.** Every user action becomes exactly one message. Moves and scrolls are sent as they happen (no batching) so latency stays at one network hop. The phone applies pointer acceleration and the natural-scrolling choice before sending; the host does not second-guess them.
- **Lifecycle.** When the control screen closes or the app goes to the background, the app sends BYE and stops pinging. On return it starts a new session.

## Sequence diagrams

### Discovery

```mermaid
sequenceDiagram
    autonumber
    participant P as Phone (Orbit app)
    participant N as LAN (multicast / broadcast)
    participant H as Host (orbit agent)

    H->>N: mDNS announce _orbit._tcp port 47821, TXT id, name, os, v=1
    P->>N: mDNS browse _orbit._tcp
    N-->>P: instance "Lev's MacBook" with TXT records
    Note over P: Bubble appears on the radar

    alt Multicast blocked by the router
        P->>N: UDP "ORBIT?1" to 255.255.255.255:47821
        N->>H: ORBIT?1
        H-->>P: {"t":"here","v":1,"id":"...","name":"...","os":"mac","port":47821}
    end

    opt Still nothing found
        Note over P: User types the IP manually
    end
```

### Pairing

```mermaid
sequenceDiagram
    autonumber
    actor U as User
    participant P as Phone
    participant H as Host
    participant D as Host dialog

    P->>H: TCP connect :47821
    P->>H: {"t":"hello","deviceId","name","platform","pub"}
    H->>P: {"t":"hello","hostId","name","os","pub"}
    Note over P,H: shared = X25519(priv, peerPub)<br/>key = HKDF(shared, "key" + deviceId + hostId, 32)<br/>code = HKDF(shared, "code" + deviceId + hostId, 4) mod 1000000
    P->>U: Shows code 482 913
    H->>D: "Allow iPhone to control this computer? Code 482 913"
    U->>D: Compares codes, clicks Allow
    alt Allowed
        D-->>H: Allow
        H->>P: {"t":"paired","ok":true}
        Note over P,H: Both persist (peerId, peerName, key)<br/>ephemeral keys are discarded
    else Denied or 60 s timeout
        H->>P: {"t":"paired","ok":false,"reason":"denied" or "timeout"}
    end
    H-->>P: close TCP
```

### Control

```mermaid
sequenceDiagram
    autonumber
    participant P as Phone
    participant H as Host
    participant OS as Operating system

    Note over P: New session = random u32, seq = 1
    loop Every touch event
        P->>H: UDP header + nonce + Enc(key, session, seq++, type, payload)
        H->>H: Decrypt with key for deviceId, check session / seq
        alt Valid
            H->>OS: Inject move / click / scroll / key / text / media
        else Bad tag, unknown device, old seq
            H->>H: Drop silently
        end
    end
    loop Every 1 s while the control screen is open
        P->>H: PING (seq n)
        H-->>P: PONG (echoSeq n, os)
        Note over P: Latency dot: mint, amber or red
    end
    alt User leaves or switches host
        P->>H: BYE
        H->>OS: Release held buttons and keys
    else Phone goes quiet for 3 s
        H->>OS: Release held buttons and keys
    end
```

## Cross-cutting decisions

- **UDP for control, TCP for pairing.** Pairing must be reliable and is rare. Control is frequent, small and latency-sensitive: a lost MOVE is better than a late one, so there are no retransmissions. State-changing messages that must not be lost in practice (button up) are protected by the 3 s liveness rule that releases held input.
- **Phone-side feel, host-side truth.** Acceleration, inertia and natural scrolling are computed on the phone so the feel is identical on every computer. Mapping to the screen (AIM to the virtual desktop, OS shortcuts for GESTURE, HID usage to key codes) is done on the host, which knows its own OS and display layout.
- **No server.** There is no relay, account or cloud. Discovery, pairing and control are all on the LAN.
- **Protocol first.** Both sides are written against [PROTOCOL.md](PROTOCOL.md); changes follow the rule in [CONTRIBUTING.md](../CONTRIBUTING.md#the-protocol-change-rule).
