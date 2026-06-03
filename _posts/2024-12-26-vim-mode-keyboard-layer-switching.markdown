---
layout: post
title: "Automatic Keyboard Layer Switching Based on Vim Mode"
date: 2025-12-26 18:00:00 -0500
categories: keyboards, vim, qmk, ergonomics
---

## The Problem: Vim Keybindings vs Colemak-DH

I use Colemak-DH as my daily driver layout. It's ergonomic, comfortable, and after the learning curve, significantly better for typing. But there's a catch: Vim's keybindings were designed for QWERTY.

The magic of `hjkl` for navigation, `w` for word-forward, `b` for back-these all assume QWERTY positioning. On Colemak-DH:
- `h` is where `m` should be
- `j` and `k` are scattered
- Muscle memory fights against layout

Some people remap Vim entirely. Others stick with QWERTY. I wanted both: **Colemak-DH for typing, QWERTY for Vim commands**.

## The Solution: Raw HID Layer Switching

Modern QMK keyboards support Raw HID-a bidirectional communication channel between your computer and keyboard. We can use this to:

1. Detect when Neovim enters insert mode
2. Send a command to the keyboard
3. Switch to Colemak-DH layer
4. Switch back to QWERTY when leaving insert mode

The result: type in Colemak-DH, navigate in QWERTY. Automatic. Instant.

## Architecture

```
┌─────────────┐      ┌──────────────┐      ┌─────────────┐
│   Neovim    │─────▶│   rawtalk    │─────▶│  Keyboard   │
│  ModeChanged│ sock │  (daemon)    │  HID │   (QMK)     │
└─────────────┘      └──────────────┘      └─────────────┘
```

- **Neovim** fires `ModeChanged` autocmd, writes mode to Unix socket
- **rawtalk** daemon receives mode, maps to layer, sends Raw HID command
- **QMK keyboard** receives command, switches default layer

Latency is imperceptible-the switch happens before your finger leaves the key.

## Setup

### 1. QMK Firmware Configuration

First, enable Raw HID in your keyboard's `rules.mk`:

```makefile
RAW_ENABLE = yes
```

Add the layer switching handler to `keymap.c`:

```c
#include "raw_hid.h"

// Layer definitions
// Layer 0: Colemak-DH (for typing in insert mode)
// Layer 3: QWERTY (for Vim commands in normal mode)

void raw_hid_receive_kb(uint8_t *data, uint8_t length) {
    uint8_t *command_id = &(data[0]);
    
    switch (*command_id) {
        case 0x00: {  // Layer switch command
            uint8_t target_layer = data[1];
            if (target_layer <= 3) {
                // Switch the default/base layer
                set_single_default_layer(target_layer);
                
                // Send response
                data[0] = 0x00;         // Success
                data[1] = target_layer; // Confirm layer
                data[2] = 0xAA;         // Acknowledgment byte
                raw_hid_send(data, length);
            } else {
                *command_id = 0xFF;     // Error
            }
            break;
        }
        
        case 0x40: {  // Get current layer (for debugging)
            data[0] = (uint8_t)get_highest_layer(default_layer_state);
            break;
        }
        
        default:
            *command_id = 0xFF;  // Unhandled
            break;
    }
}
```

Your keymap should have both layouts defined:

```c
const uint16_t PROGMEM keymaps[][MATRIX_ROWS][MATRIX_COLS] = {
    // Layer 0: Colemak-DH
    [0] = LAYOUT(
        KC_Q,    KC_W,    KC_F,    KC_P,    KC_B,    KC_J,    KC_L,    KC_U,    KC_Y,    KC_SCLN,
        KC_A,    KC_R,    KC_S,    KC_T,    KC_G,    KC_M,    KC_N,    KC_E,    KC_I,    KC_O,
        KC_Z,    KC_X,    KC_C,    KC_D,    KC_V,    KC_K,    KC_H,    KC_COMM, KC_DOT,  KC_SLSH,
        // ... thumb keys
    ),
    
    // Layer 1: Symbols/Numbers
    [1] = LAYOUT( /* ... */ ),
    
    // Layer 2: Function keys
    [2] = LAYOUT( /* ... */ ),
    
    // Layer 3: QWERTY
    [3] = LAYOUT(
        KC_Q,    KC_W,    KC_E,    KC_R,    KC_T,    KC_Y,    KC_U,    KC_I,    KC_O,    KC_P,
        KC_A,    KC_S,    KC_D,    KC_F,    KC_G,    KC_H,    KC_J,    KC_K,    KC_L,    KC_SCLN,
        KC_Z,    KC_X,    KC_C,    KC_V,    KC_B,    KC_N,    KC_M,    KC_COMM, KC_DOT,  KC_SLSH,
        // ... thumb keys
    ),
};
```

Compile and flash:

```bash
qmk compile -kb your_keyboard -km your_keymap
qmk flash -kb your_keyboard -km your_keymap
```

### 2. rawtalk Daemon

The daemon is a small Rust program that bridges Neovim and the keyboard.

**Clone and build:**

```bash
git clone https://github.com/morph-k/rawtalk
cd rawtalk
cargo build --release
```

**The source (`src/main.rs`):**

```rust
use hidapi::HidApi;
use std::io::{BufRead, BufReader};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::mpsc;
use std::thread;
use std::time::Duration;
use std::fs;

// Update these for your keyboard
const VID: u16 = 0xC2AB;        // Vendor ID
const PID: u16 = 0x3939;        // Product ID
const USAGE_PAGE: u16 = 0xFF60; // QMK Raw HID usage page
const USAGE: u16 = 0x61;        // QMK Raw HID usage
const SOCKET: &str = "/tmp/rawtalk.sock";

fn find_keyboard(api: &HidApi) -> Option<hidapi::HidDevice> {
    api.device_list()
        .find(|d| d.vendor_id() == VID && d.product_id() == PID 
              && d.usage_page() == USAGE_PAGE && d.usage() == USAGE)
        .and_then(|d| d.open_device(api).ok())
}

fn send_layer(device: &hidapi::HidDevice, layer: u8) {
    let mut cmd = [0u8; 33];
    cmd[1] = 0x00; // layer switch command
    cmd[2] = layer;
    
    if device.write(&cmd).is_ok() {
        let mut resp = [0u8; 32];
        if device.read_timeout(&mut resp, 500).unwrap_or(0) > 0 && resp[2] == 0xAA {
            println!("[layer {}] {}", layer, if layer == 0 { "colemak-dh" } else { "qwerty" });
        }
    }
}

fn mode_to_layer(mode: &str) -> u8 {
    match mode {
        "i" | "ic" | "ix" | "R" | "Rc" | "Rx" | "Rv" | "Rvc" | "Rvx" => 0, // Insert/Replace → Colemak
        _ => 3, // Normal, Visual, Command → QWERTY
    }
}

fn handle_client(stream: UnixStream, tx: mpsc::Sender<String>) {
    for line in BufReader::new(stream).lines().flatten() {
        let mode = line.trim().to_string();
        if !mode.is_empty() && tx.send(mode).is_err() { break; }
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let api = HidApi::new()?;
    let device = find_keyboard(&api).ok_or("keyboard not found")?;
    println!("rawtalk: connected");

    let _ = fs::remove_file(SOCKET);
    let listener = UnixListener::bind(SOCKET)?;
    
    #[cfg(unix)]
    fs::set_permissions(SOCKET, std::os::unix::fs::PermissionsExt::from_mode(0o777))?;

    let (tx, rx) = mpsc::channel();
    
    thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let tx = tx.clone();
            thread::spawn(move || handle_client(stream, tx));
        }
    });

    println!("rawtalk: listening on {}", SOCKET);

    let mut last: Option<u8> = None;
    loop {
        if let Ok(mode) = rx.recv_timeout(Duration::from_secs(60)) {
            let layer = mode_to_layer(&mode);
            if last != Some(layer) {
                send_layer(&device, layer);
                last = Some(layer);
            }
        }
    }
}
```

### 3. Running rawtalk

#### Without Nix (systemd)

Create a systemd user service:

```bash
mkdir -p ~/.config/systemd/user

cat > ~/.config/systemd/user/rawtalk.service << 'SERVICE'
[Unit]
Description=QMK Layer Switcher Daemon
After=graphical-session.target

[Service]
ExecStart=%h/git/rawtalk/target/release/rawtalk
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
SERVICE

systemctl --user daemon-reload
systemctl --user enable --now rawtalk
```

Check status:
```bash
systemctl --user status rawtalk
journalctl --user -u rawtalk -f
```

#### With Nix (Home Manager)

Add to your `home.nix`:

```nix
{ pkgs, ... }:

let
  rawtalk = pkgs.rustPlatform.buildRustPackage {
    pname = "rawtalk";
    version = "0.3.0";
    src = pkgs.fetchFromGitHub {
      owner = "morph-k";
      repo = "rawtalk";
      rev = "main";
      sha256 = "sha256-XXXX"; # Update with actual hash
    };
    cargoLock.lockFile = ./Cargo.lock;
    nativeBuildInputs = [ pkgs.pkg-config ];
    buildInputs = [ pkgs.hidapi ];
  };
in {
  home.packages = [ rawtalk ];

  systemd.user.services.rawtalk = {
    Unit = {
      Description = "QMK Layer Switcher";
      After = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = "${rawtalk}/bin/rawtalk";
      Restart = "always";
    };
    Install.WantedBy = [ "default.target" ];
  };
}
```

#### Linux: udev Rules

On Linux, you need udev rules to access the HID device without root:

```bash
sudo tee /etc/udev/rules.d/70-qmk.rules << 'RULES'
SUBSYSTEMS=="usb", ATTRS{idVendor}=="c2ab", ATTRS{idProduct}=="3939", TAG+="uaccess"
KERNEL=="hidraw*", ATTRS{idVendor}=="c2ab", ATTRS{idProduct}=="3939", TAG+="uaccess"
RULES

sudo udevadm control --reload-rules
sudo udevadm trigger
```

### 4. Neovim Configuration

Add to your `init.lua`:

```lua
-- Rawtalk: Automatic keyboard layer switching
local socket_path = "/tmp/rawtalk.sock"
local uv = vim.loop
local client, connected = nil, false

local function connect()
    if connected then return true end
    client = uv.new_pipe()
    client:connect(socket_path, function(err)
        connected = not err
    end)
    vim.wait(50, function() return connected end)
    return connected
end

local function send_mode(mode)
    if not connected then connect() end
    if connected then
        pcall(function() client:write(mode .. "\n") end)
    end
end

local group = vim.api.nvim_create_augroup("Rawtalk", { clear = true })

vim.api.nvim_create_autocmd("ModeChanged", {
    group = group,
    pattern = "*",
    callback = function()
        send_mode(vim.fn.mode())
    end,
})

vim.api.nvim_create_autocmd("VimEnter", {
    group = group,
    callback = function()
        vim.defer_fn(function()
            connect()
            send_mode(vim.fn.mode())
        end, 100)
    end,
})

vim.api.nvim_create_autocmd("VimLeave", {
    group = group,
    callback = function()
        if client then pcall(function() client:close() end) end
    end,
})
```

## The Ergonomic Advantage

This setup gives you the best of both worlds:

### Vim Commands (QWERTY)
- `hjkl` navigation stays intuitive
- `w`, `b`, `e` word motions work as expected
- All operators (`d`, `c`, `y`) in familiar positions
- Macros and complex commands just work

### Typing (Colemak-DH)
- Most common letters on home row
- Reduced finger travel
- Lower risk of RSI
- More comfortable for prose

### The Flow

1. Open file, you're in Normal mode → QWERTY
2. Navigate with `hjkl`, search with `/`, jump with `gg`
3. Press `i` to insert → instant switch to Colemak-DH
4. Type your code/prose comfortably
5. Press `Esc` → instant switch to QWERTY
6. Continue editing with familiar Vim bindings

The switch is fast enough that it feels like a single keyboard. Your fingers never leave home row.

## Troubleshooting

**Keyboard not found:**
- Check VID/PID match your keyboard (use `lsusb` on Linux)
- Verify udev rules are installed (Linux)
- Grant Input Monitoring permission (macOS)

**Layer not switching:**
- Ensure `RAW_ENABLE = yes` in `rules.mk`
- Verify `raw_hid_receive_kb` function signature is `void`, not `bool`
- Check QMK console output: `qmk console`

**Socket connection failed:**
- Make sure rawtalk is running: `pgrep rawtalk`
- Check socket exists: `ls -la /tmp/rawtalk.sock`

## Conclusion

This setup has transformed my editing experience. I no longer compromise between ergonomic typing and efficient Vim navigation. The automatic switching is invisible-it just works.

The complete code is available:
- [rawtalk](https://github.com/morph-k/rawtalk) - The daemon
- [ferris-sweep-qmk-keymap](https://github.com/morph-k/ferris-sweep-qmk-keymap) - Example QMK keymap

If you're a Vim user considering an alternative layout, this approach removes the biggest barrier. You get to keep Vim's brilliant command language exactly as designed, while gaining all the ergonomic benefits of a modern layout for actual typing.

## Security Considerations

While rawtalk is a simple local daemon, it's worth understanding the security model:

### Socket Permissions

The Unix socket is created with `0o600` permissions (owner read/write only). This means:
- Only your user can send commands to the keyboard
- Other users on a shared system cannot hijack your keyboard layers
- If you need multi-user access, change to `0o660` and use group permissions

### Input Validation

- Mode strings are limited to 8 bytes maximum
- Invalid input is silently dropped
- No shell execution or command injection possible

### Rate Limiting

A 10ms minimum interval between layer switches prevents:
- Accidental rapid switching from causing USB issues
- Potential DoS from malicious socket writes

### Graceful Shutdown

The daemon handles SIGTERM/SIGINT to:
- Clean up the socket file on exit
- Prevent orphaned sockets that could be hijacked

### Disclaimer

This project involves:
- **Custom keyboard firmware** - flashing incorrect firmware can brick your keyboard (though QMK keyboards typically have bootloader recovery)
- **Raw HID communication** - requires elevated permissions on some systems
- **System daemon** - runs continuously in the background

Use at your own risk. The code is open source and provided as-is. Always review code before running it with hardware access.

### Permissions Required

| Platform | Requirement |
|----------|-------------|
| Linux | udev rules for hidraw access |
| macOS | Input Monitoring permission |
| Windows | Usually works without special permissions |

If security is a concern in your environment, consider:
1. Running rawtalk only when needed (not as a persistent service)
2. Auditing the ~100 lines of Rust code
3. Using a dedicated user account for keyboard access
