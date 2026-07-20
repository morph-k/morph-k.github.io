---
layout: post
title:  "cross-compiling a Go GUI app for riscv64, and why this one actually works"
date:   2026-07-20
categories: go gio riscv nix cross-compilation qemu macos
---

I have now written two posts that end with the same conclusion: you cannot cross-compile this, so stand up a machine that can execute the target code. [Building SBCL for RISC-V]({% post_url 2025-05-06-SBCL-development-on-riscv-architecture %}) needed a QEMU RISC-V VM. [Building Nyxt]({% post_url 2026-07-20-compiling-nyxt-podman-nix %}) needed Podman, and then a NixOS VM. Both times the wall was the same one, and it is not a toolchain limitation: SBCL produces executables with `save-lisp-and-die`, which per the [SBCL manual](https://www.sbcl.org/manual/#Saving-a-Core-Image) dumps *the currently running Lisp image*. If the build step runs the artifact, the artifact's architecture must be the architecture you are running on. No compiler flag escapes that.

That is a claim about build systems, not about Lisp, and a claim like that is worth testing against a case that should come out the other way. So I picked [lensm](https://github.com/loov/lensm), a Go program that visualizes Go assembly, and cross-compiled it for riscv64.

Go inverts the SBCL situation exactly. `go build` writes an ELF file and never executes it. So the target machine should be needed only to *run* lensm, not to produce it. That distinction is worth money here: there is no riscv64 hardware attached to an Apple Silicon Mac, so a native build means emulating the entire Go compiler under QEMU's TCG interpreter. Cross-compiling skips that entirely and the emulator only has to run the finished program.

It worked. But "Go cross-compiles trivially" turned out to be false for this program in an instructive way, and the most interesting failure was not a compiler failure at all.

## terminology

**Build platform / host platform / target platform.** nixpkgs uses the GNU convention: the *build* platform runs the compiler, the *host* platform runs the resulting binary, and the *target* platform is what that binary itself emits code for (only meaningful for compilers). Here build is `aarch64-linux` and host is `riscv64-linux`. I will say "builder" and "guest" below to stay readable.

**Sysroot.** The target's headers and libraries, laid out as the target's filesystem would be, so a cross-compiler can resolve `#include <X11/Xlib.h>` against riscv64 X11 rather than the build machine's.

**cgo.** Go's C interop. A package using it declares its C dependencies in `#cgo` comment directives, which is where Gio hides its entire Linux windowing story.

**Gio.** The immediate-mode GUI toolkit lensm draws with, `gioui.org`.

## the GOARCH switch is not enough

Go's reputation for painless cross-compilation comes from pure-Go programs, where `GOOS`/`GOARCH` is genuinely the whole story. lensm is not one:

```console
$ GOOS=linux GOARCH=riscv64 CGO_ENABLED=0 go build -o /dev/null .
package loov.dev/lensm
	imports gioui.org/app
	imports gioui.org/internal/vk: build constraints exclude all Go files in /Users/morph/go/pkg/mod/gioui.org@v0.10.1/internal/vk
```

That error is easy to misread as "this package does not support riscv64." It is not. Every file in `internal/vk` is a cgo file, and Go excludes files that `import "C"` when cgo is disabled, so with `CGO_ENABLED=0` the package has no files left and the constraint set collapses. The four files there are `vulkan.go`, `vulkan_android.go`, `vulkan_wayland.go`, `vulkan_x11.go`, and `vulkan.go` opens with `//go:build linux || freebsd` — Linux is precisely what it is *for*.

So Gio has no pure-Go path on Linux. It reaches X11, Wayland, EGL and Vulkan through cgo, which means cross-compiling lensm needs a complete riscv64 sysroot, not a GOARCH switch. The Go compiler is the easy half.

## where the build has to happen

Not on the Mac. The [nix.dev cross-compilation tutorial](https://nix.dev/tutorials/cross-compilation.html) states it plainly — "It's only possible to cross compile between `aarch64-darwin` and `x86_64-darwin`" — and I already hit this from the other direction in the Nyxt post. Darwin to Linux is outside what nixpkgs supports, regardless of the eventual target.

That leaves a slightly odd-looking three-machine pipeline:

```
macOS (aarch64-darwin)   drives, holds no compiler
  └─ NixOS UTM VM (aarch64-linux)   cross-compiles → riscv64
       └─ Ubuntu 24.04 QEMU VM (riscv64)   runs the result
```

The middle box is the same `utm-builder` VM the Nyxt post ended with, reused unchanged. Both it and the Mac are aarch64, so there is no emulation anywhere in the build — the only emulated thing in the whole pipeline is the final program.

## the pkg-config list, extracted by failing

`pkgsCross.riscv64` on the builder supplies the cross toolchain (`riscv64-unknown-linux-gnu-gcc`, Go 1.26.4) and cross-built libraries. Working out *which* libraries took a few rounds of letting the build tell me. Gio declares them across several files; the union is:

```
#cgo linux pkg-config: egl wayland-egl
#cgo linux pkg-config: wayland-client
#cgo linux pkg-config: wayland-client wayland-cursor
#cgo linux pkg-config: x11 xkbcommon xkbcommon-x11 x11-xcb xcursor xfixes
```

Two of those do not map to the package you would guess.

**`vulkan-loader` ships the shared object but not the headers.** `internal/vk` `#include`s `<vulkan/vulkan.h>`, so the build dies with:

```
fatal error: vulkan/vulkan.h: No such file or directory
```

`vulkan-headers` is a separate nixpkgs package and both are required.

**`x11-xcb` has a `Requires:` on `xcb`.** pkg-config resolves transitively and reports the dependency, not the thing you asked for, which makes the error read as though something unrelated is missing:

```
Package 'xcb', required by 'x11-xcb', not found
```

Adding `libxcb` fixes it. Also worth noting if you are copying older expressions: nixpkgs now warns that `xorg.libX11` has been renamed to `libx11`.

## a path-MTU blackhole that looked like flaky mirrors

This one cost more time than the entire cross-compile, and it is the part I would most want someone else to read.

Nix evaluation on the builder VM started failing at fetch time. Two different errors, from two different fetchers:

```
error: unable to download 'https://api.github.com/...':
  SSL routines::unexpected eof while reading
```

```
go: module lookup disabled ... net/http: TLS handshake timeout
```

Meanwhile `channels.nixos.org` worked perfectly. Every instinct says "GitHub is having a bad day, the Go proxy is rate-limiting me, retry later." I retried for a while.

The pattern that actually mattered was not *which host* but *how big the response*. Small requests completed; anything past the first few KB hung and then died. The TLS handshake to `api.github.com` failing with `unexpected eof` rather than a certificate or DNS error is the same signature — the handshake got far enough to exchange bytes and then stopped mid-flight.

That is a path-MTU blackhole. Something on the path cannot carry a 1500-byte frame, and the ICMP "fragmentation needed" message that would tell the sender to shrink never comes back, so the connection does not fail — it simply stalls forever on the first full-size packet. TLS makes it look host-specific because the point at which you hit a full-size packet depends on how much the peer sends.

Lowering the MTU on the guest's interface fixed it immediately:

```bash
ip link set enp0s1 mtu 1400   # Go module proxy started working
ip link set enp0s1 mtu 1280   # GitHub started working
```

1400 was enough for `proxy.golang.org` but not for `api.github.com`, which is itself a nice demonstration that the failure threshold is per-path. 1280 is the IPv6 minimum MTU and a safe floor. Persisted in the NixOS config:

```nix
networking.interfaces.enp0s1.mtu = 1280;
```

I have not traced exactly which hop in the UTM/vmnet path drops the ICMP, so "the ICMP never returns" is my inference from the symptom rather than something I captured. What I did observe is the size correlation and that the MTU change fixed it.

The lasting consequence is in the flake: the nixpkgs input is the channel tarball rather than `github:nixos/nixpkgs`, because that was the one that worked while I was still diagnosing.

```nix
inputs.nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.xz";
```

The tarball ships nixpkgs' own `flake.nix`, so it is a drop-in input. Anything that needs GitHub or the Go module proxy is silently broken on a blackholed path, and nothing in the error text points at the network configuration.

## buildGoModule, with three non-defaults

```nix
pkgs.buildGoModule {
  pname = "lensm";
  src = self;
  vendorHash = "sha256-gtlCOzHQopEry8KkKMb2xT3x/UMMU4zFy6czfqIoVLg=";
  subPackages = ["."];
  env.CGO_ENABLED = 1;
  doCheck = false;
  # ...
}
```

`env.CGO_ENABLED = 1` for the reason above; cgo is not optional for this program.

`doCheck = false` because lensm's tests are ordinary Go tests, and the test binaries are riscv64. The builder cannot run them. This is the one place where the SBCL problem reappears in miniature: *checking* requires execution even when *building* does not, so the check phase is the part of a Go build that genuinely cannot cross-compile.

`subPackages = ["."]` is the surprise. lensm vendors a slice of the Go toolchain under `internal/go/src` so it can decode object files. Those are real `main` packages, and without restricting the build, `$out/bin` picks up stray `go`, `gen` and `asmcheck` binaries alongside `lensm`.

## two outputs, because /nix/store does not exist on Ubuntu

The Nix-built binary is correct and unrunnable on the guest:

```console
$ file dist/lensm-riscv64-nixstore
ELF 64-bit LSB executable, UCB RISC-V, RVC, double-float ABI, version 1 (SYSV),
dynamically linked, interpreter /nix/store/37lxg0k99syg6n63mv0bavs41zbivfgq-glibc-riscv64-unknown-linux-gnu-2.42-67/lib/ld-linux-riscv64-lp64d.so.1,
for GNU/Linux 4.15.0, not stripped
```

Stock Ubuntu has no `/nix`, so the kernel cannot even start it. The options are to copy the whole Nix closure to the guest, install Nix on the guest, or repoint the interpreter. The third is viable here because every library lensm actually needs is a plain SONAME that Ubuntu ships via apt:

```
libc.so.6              libEGL.so.1            libX11.so.6
libdl.so.2             libwayland-client.so.0 libX11-xcb.so.1
libm.so.6              libwayland-cursor.so.0 libxcb.so.1
libpthread.so.0        libwayland-egl.so.1    libXcursor.so.1
libresolv.so.2         libxkbcommon.so.0      libXfixes.so.3
                       libxkbcommon-x11.so.0
```

That is `readelf -d`, which lists the 17 `NEEDED` entries the binary itself records — not `ldd`, which walks the whole transitive closure. The difference is not cosmetic. `libffi` shows up in `ldd` output, so it looked like a dependency and sat in `buildInputs` for a while; `readelf -d` shows it is not `NEEDED` by lensm at all, only pulled in beneath wayland and xkbcommon. Removing it from `buildInputs` entirely still builds clean, and the resulting binary re-verified in the guest with no `not found` lines. If you are assembling a library list by reading `ldd`, you will over-specify it and never find out.

So a second derivation just rewrites the header:

```nix
patchelf \
  --set-interpreter /lib/ld-linux-riscv64-lp64d.so.1 \
  --remove-rpath \
  $out/bin/lensm
```

The obvious risk is glibc symbol versioning. Nix's cross glibc here is 2.42; if the binary references a symbol version newer than the guest's glibc provides, it links against the guest loader and then fails at runtime with `version GLIBC_2.xx not found`. That is a measurable property rather than a thing to hope about, so I measured it:

```console
$ readelf -V lensm | grep -oE 'GLIBC_[0-9.]+' | sort -uV | tail -1
GLIBC_2.34
```

The binary was *built* against 2.42 but only *requires* up to 2.34, because symbol versions are stamped per symbol at the version that symbol last changed. The floor and ceiling both clear:

- glibc gained riscv64 support in [2.27](https://lwn.net/Articles/746327/), for `rv64imafdc lp64d` among others, requiring linux 4.15 — which is exactly the `for GNU/Linux 4.15.0` in the `file` output above.
- Ubuntu 24.04 ships `libc6` at `2.39-0ubuntu8.7` on riscv64, per the [noble-updates ports archive](https://ports.ubuntu.com/ubuntu-ports/dists/noble-updates/main/binary-riscv64/) — which is what the guest actually reported: `ldd (Ubuntu GLIBC 2.39-0ubuntu8.7) 2.39`. The release pocket has `2.39-0ubuntu8`; only the Ubuntu revision differs, and the upstream 2.39 that the comparison rests on is the same either way.

2.34 sits comfortably between. In the guest, `ldd` on the patched binary reported no `not found` lines, which is the confirmation rather than the prediction. This check needs redoing if the nixpkgs pin moves and the ceiling rises.

## verifying in two stages

Standing up a riscv64 VM is an hour of work. Finding out afterwards that the binary is broken is a bad way to spend it, so the first check ran under qemu-user on the builder — same architecture emulation, no kernel, no disk image, no boot.

lensm has an `mcp` subcommand that runs a headless JSON-RPC server over stdin/stdout, which makes it drivable without any windowing system at all. That is a convenient property: the GUI program can be exercised as a pure function. I pointed it at the only riscv64 binary I had handy, which was itself, and asked it to disassemble `main.main`:

```
main.go:20
  MOV   16(X27), X6
  ADDI  $-368, X2, X7
  BLTU  X6, X7, 3(PC)
```

That is the standard Go stack-growth prologue in riscv64 registers — `X27` is `g`, so this loads the stack guard, computes the new stack pointer, and branches to `morestack` if it would underflow. Seeing real riscv64 register names come out of a program that was itself riscv64, running under emulation, was the point at which I believed the cross-compile.

Only then did the VM go up, and the GUI ran there against a headless X server: `Xvfb` at 1400x900, with Gio mapping a window that `xwininfo` reported as `0x200001 "lensm" 1400x900`. The interface came up for real — `-filter 'main\.'` narrowing to `134 / 14386` functions, Go assembly in the left pane beside native RISC-V on the right (`AUIPC X5,0X1DA`, `JAL X5,-278232`, `SD X1,0(X2)`, `BEQZ X12,16`), with lensm's control-flow arrows drawn between branch targets.

![lensm running natively on riscv64 under Xvfb, Go assembly beside native RISC-V]({{ site.baseurl }}/images/2026-07-20-lensm-riscv64.png)

The screenshot also settles the prologue reading above. The instruction immediately after that `BLTU` is `JAL X5, runtime.morestack_`, so the branch really is the stack-growth check rather than something I inferred from register numbers alone.

## riscv64 QEMU on macOS, versus the same thing on Linux

My earlier RISC-V post assumed a Linux host, and two of its steps do not survive the move to macOS.

**The u-boot path does not exist.** That post passes `-kernel /usr/lib/u-boot/qemu-riscv64_smode/uboot.elf`, which is a file Ubuntu's `u-boot-qemu` package installs. There is no such package on Darwin. The fix is that the package does not need to be installed, only unpacked, and it is architecture-independent:

```console
$ curl -s https://ports.ubuntu.com/ubuntu-ports/dists/noble-updates/main/binary-riscv64/Packages.gz \
    | gunzip | awk '/^Package: u-boot-qemu$/,/^$/' \
    | grep -E '^(Package|Architecture|Version|Filename):'
Package: u-boot-qemu
Architecture: all
Version: 2025.10-0ubuntu0.24.04.2
Filename: pool/main/u/u-boot/u-boot-qemu_2025.10-0ubuntu0.24.04.2_all.deb
```

Note `noble-updates` rather than `noble`: the release pocket still has 2024.01, and the field order differs between the two, which is why this pulls named fields instead of a fixed `grep -A3` window.

`Architecture: all` means the .deb contains no compiled code for any particular machine, so extracting it on macOS is legitimate rather than a hack:

```bash
curl -LO https://ports.ubuntu.com/ubuntu-ports/pool/main/u/u-boot/u-boot-qemu_2025.10-0ubuntu0.24.04.2_all.deb
ar x u-boot-qemu_2025.10-0ubuntu0.24.04.2_all.deb
tar xf data.tar.*
# ./usr/lib/u-boot/qemu-riscv64_smode/uboot.elf
```

**The first-boot password prompt cannot be scripted.** The preinstalled image forces an interactive password change on the serial console, which is fine when you are typing at it and useless in a script. A cloud-init NoCloud seed ISO carrying the SSH key and the apt package list avoids the console entirely, and `hdiutil` can build one without any Linux ISO tooling — the volume label `CIDATA` is what cloud-init looks for:

```bash
hdiutil makehybrid -o seed.iso -iso -joliet -default-volume-name CIDATA seed
```

attached as a second virtio drive. The image itself is now `ubuntu-24.04.4-preinstalled-server-riscv64.img.xz` (the older post used 24.04.2). Otherwise the invocation is the familiar one:

```bash
qemu-system-riscv64 \
  -machine virt -nographic -m 4096 -smp 4 \
  -kernel ./usr/lib/u-boot/qemu-riscv64_smode/uboot.elf \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -device virtio-net-device,netdev=net0 \
  -drive file=ubuntu-24.04.4-preinstalled-server-riscv64.img,if=virtio,format=raw
```

## a DISPLAY that exists and answers nothing

I wanted the window on my actual screen, not in a screenshot, so the plan was X11 forwarding to XQuartz. Instead `xdpyinfo` hung. Not "cannot open display" — hung, indefinitely, with no output.

The cause was that XQuartz was half-installed: `/opt/X11` present, `XQuartz.app` missing. macOS registers a launchd socket for `:0` and sets `DISPLAY` to point at it, and launchd will happily accept a connection on that socket in order to start the server on demand. With no server to start, the connection is accepted and then simply never answered. So `DISPLAY` is set, the socket is present, a connect() succeeds, and nothing behind it will ever speak the X protocol.

Worth remembering as a shape: an endpoint that accepts connections is not evidence that anything is listening in the sense you care about. A refused connection would have been far more informative. I left it there and used Xvfb, so the GUI has been verified running and rendering, but not interactively driven from the host — that is still open.

## what this says about cross-compilation

The two prior posts and this one now cover both cases, and the dividing line is sharper than "which language."

SBCL cannot cross-produce an application because its final step *is* an execution: `save-lisp-and-die` dumps a live process. Go can, because `go build` only ever writes bytes. That is not a maturity difference or a tooling gap — it is structural, and no amount of toolchain work moves a project from one side to the other.

What cross-compilation buys you is precisely the cost of emulation, so it matters most exactly where the architecture gap is widest. In the Nyxt case, the container was aarch64 on aarch64 and emulation cost nothing, so the "you must execute the target" requirement was cheap to satisfy. Here the target is riscv64 with no hardware in reach, and satisfying it natively would have meant running the Go compiler itself under TCG. Cross-compiling shrank the emulated surface from "the whole toolchain" to "one program, once, at the end."

And notably, the target machine never disappeared. It moved. In the SBCL case the VM was part of the build; here it is part of the *test*. `doCheck = false` is that migration made explicit — the build crosses, the check does not, and pretending otherwise just moves a failure later.

## resources

- [lensm](https://github.com/loov/lensm)
- [Gio](https://gioui.org/)
- [nix.dev: Cross compilation](https://nix.dev/tutorials/cross-compilation.html)
- [SBCL manual: Saving a Core Image](https://www.sbcl.org/manual/#Saving-a-Core-Image)
- [GNU C Library 2.27 released](https://lwn.net/Articles/746327/), the release that added the riscv64 port
- [Ubuntu noble riscv64 package index](https://ports.ubuntu.com/ubuntu-ports/dists/noble/main/binary-riscv64/)
- [cloud-init NoCloud datasource](https://cloudinit.readthedocs.io/en/latest/reference/datasources/nocloud.html)
- [QEMU RISC-V platform documentation](https://wiki.qemu.org/Documentation/Platforms/RISCV)
- [Common lisp disassembly through SBCL on RISC-V architecture]({% post_url 2025-05-06-SBCL-development-on-riscv-architecture %})
- [compiling nyxt with podman and nix, and why cross-compilation can't help]({% post_url 2026-07-20-compiling-nyxt-podman-nix %})
