---
layout: post
title:  "compiling nyxt with podman and nix, and why cross-compilation can't help"
date:   2026-07-20
categories: nix podman lisp nyxt containers macos sbcl
---

I wanted to build [Nyxt](https://github.com/atlas-engineer/nyxt) on my M-series Mac. Nyxt's download page offers a Docker route for macOS, so that seemed like the obvious path. It wasn't, and the detour turned out to be more interesting than the destination.

Short version: I got it building with Podman and a Nix toolchain. Along the way I hit a dead upstream dependency that breaks the build for everyone, and I convinced myself that Nix cross-compilation fundamentally cannot solve this particular problem.

## the docker route is a dead end

The "Get Nyxt via Docker!" button points at [deddu/nyxt-docker](https://github.com/deddu/nyxt-docker). That image installs a prebuilt `nyxt_2.2.4_amd64.deb`. Three problems: it's Nyxt 2.2.4 (the tree I'm working from is 4.0.0-pre-release), it's amd64 only, and it doesn't compile anything. The last commit is from 2022.

So if you actually want to *compile* current Nyxt, you're writing your own container.

## podman first

My Podman VM wouldn't start:

```
Error: unable to connect to "gvproxy" socket
```

The log pointed at a missing SSH identity file. Digging further, the VM's disk image was gone too. Only the config JSON survived, so `podman machine list` cheerfully reported a machine that had nothing behind it. Recreating it was the fix, and nothing was lost because there was nothing there:

```bash
podman machine rm -f podman-machine-default
podman machine init --memory 8192 --cpus 6 --disk-size 100
podman machine start
```

The memory bump matters. Nyxt's makefile passes SBCL `--dynamic-space-size 3072`, so a 2GB VM won't do.

## a dependency that no longer exists

Nyxt vendors its Lisp dependencies as 110 git submodules. One of them doesn't resolve:

```
fatal: repository 'https://github.com/pcostanza/closer-mop/' not found
```

`closer-mop` is a real and widely used library, but that GitHub repo is gone. Nyxt's `.gitmodules` on master still points there, so this breaks for anyone cloning today, not just me.

Finding a replacement was harder than expected. The [gitlab.common-lisp.net mirror](https://gitlab.common-lisp.net/closer/closer-mop) exists but its history stops in 2013. The `ocicl` mirror has squashed history. Neither contains the pinned commit `7b86f2a`.

[Software Heritage](https://archive.softwareheritage.org/) had it. Their archive crawls GitHub and keeps content after upstream deletes it, and because git objects are content-addressed you can verify exactly what you got:

```bash
curl -sL "https://archive.softwareheritage.org/api/1/vault/flat/\
swh:1:dir:a586e6df8e167a401cc5632a03cd040ee896aa81/raw/" -o cmop.tar.gz
tar xzf cmop.tar.gz --strip-components=1 -C _build/closer-mop
cd _build/closer-mop && git init -q . && git add -A && git write-tree
# a586e6df8e167a401cc5632a03cd040ee896aa81
```

The computed tree hash matches the tree of the pinned commit, so this is provably the right source rather than something that merely looks close.

Git still wanted `HEAD` at the pinned commit. Since Software Heritage also stores the commit metadata, the commit object can be rebuilt byte for byte, and it hashes back to the original SHA. That was satisfying in a way I did not expect from a dependency-resolution problem.

## the failure that wasn't what it looked like

The first `git submodule update --init --recursive` aborted partway through, at `closer-mop`. After I fixed that and re-ran it, `git submodule status` reported everything clean.

It was lying, sort of. 41 submodules had been cloned but never checked out. The gitlinks matched, which is all `git submodule status` checks, so the directories sat there containing nothing but `.git`. This surfaced thousands of lines into an SBCL build as:

```
Component ASDF/USER::CALISPEL not found, required by #<NASDF-SYSTEM "nyxt">
```

`git submodule update --init --recursive --force` fixed it. The lesson I'm taking: a clean `submodule status` means the recorded commits agree, not that the files are on disk.

## two small dependency papercuts

Debian trixie ships Python 3.13, which removed `distutils` per [PEP 632](https://peps.python.org/pep-0632/). The `node-gyp` bundled with one of Electron's native modules still imports it, so `npm install` dies. Installing `python3-setuptools` restores the import, because setuptools ships a `distutils-precedence.pth` that redirects it.

Then `cl-enchant` failed to load `libenchant-2`. Nyxt's developer manual lists enchant as optional (it's for spellchecking), but the library is `dlopen`ed at load time, so the build hard-fails without it. It also has to be the `-dev` package: CFFI asks for the unversioned `libenchant-2.so`, and Debian's runtime package ships only `libenchant-2.so.2`.

## switching to nix

Fighting distro packaging is exactly what Nix is for, so I moved the toolchain into a flake.

One wrinkle: my host is `aarch64-darwin` with no Linux builder configured, so it can't realize `aarch64-linux` derivations. Rather than set up a builder VM, I run Nix *inside* the container. The flake pins the toolchain, Podman provides the Linux kernel, and no builder VM is needed.

```nix
default = pkgs.mkShell {
  nativeBuildInputs = with pkgs; [
    sbcl nodejs_20 python3 gnumake gcc git pkg-config xclip
  ];
  buildInputs = ffiLibs ++ electronLibs;
  LD_LIBRARY_PATH = nixpkgs.lib.makeLibraryPath (ffiLibs ++ electronLibs);
};
```

That `nativeBuildInputs` / `buildInputs` split is load-bearing. `cffi-grovel` shells out to `pkg-config` for libfixposix's cflags, and nixpkgs' pkg-config setup hook only exposes `.pc` files from `buildInputs`. Put the libraries in the wrong list and grovelling fails.

The other gotcha: `nix develop` needs an explicit flake reference. With no argument it resolves the flake from the working directory, which is the bind-mounted repo, where `flake.nix` is untracked by git and therefore invisible to Nix. The error message is good about saying so.

That builds:

```bash
podman run --rm -v "$PWD":/nyxt -w /nyxt nyxt-nix
./nyxt --version   # Nyxt version 4
```

## so why not cross-compile?

This is where I'd expected to end up. The [nix.dev cross-compilation tutorial](https://nix.dev/tutorials/cross-compilation.html) is good, and `pkgsCross` makes targeting another platform look easy. If it worked, I could skip the container.

It doesn't work here, for three reasons of increasing severity.

First, the tutorial says so directly: "It's only possible to cross compile between `aarch64-darwin` and `x86_64-darwin`." macOS to Linux is outside what's supported.

Second, empirically, `pkgsCross.aarch64-multiplatform.sbcl` won't even evaluate from Darwin. It fails on a build-time dependency, `strace`, that isn't available on `aarch64-darwin` as the build platform. Interestingly, simpler cross targets do work; `pkgsCross.aarch64-multiplatform.hello` pulls a cross toolchain from the cache and starts building. So the wall isn't cross-compilation in general, it's this toolchain.

Third, and this is the one that actually settles it: even a perfect cross-compiled SBCL wouldn't help. SBCL doesn't link executables the way a C compiler does. It produces them with `save-lisp-and-die`, which per the [SBCL manual](https://www.sbcl.org/manual/#Saving-a-Core-Image) dumps *the currently running Lisp image* and combines it with the runtime. Building Nyxt means loading all of Nyxt into a live SBCL and then dumping that process.

To produce a Linux binary, you must execute a Linux SBCL. Cross-compilation is about generating code for a machine you aren't running on, and that's precisely the thing this build cannot do. No amount of toolchain configuration gets around it, because the compiler is not the thing producing the artifact; a running process is.

Which reframes the container. I'd been thinking of Podman as a workaround for not having a Linux machine. It isn't a workaround. It's the mechanism, because what this build needs is a Linux *execution* environment, and that's exactly what a container provides and what a cross-compiler does not.

The same reasoning applies to any language whose build step runs the artifact it's building. Cross-compilation works for compile-and-link toolchains. It doesn't work for image-dumping ones.

## but sbcl does cross-compile, sort of

I should be precise here, because "SBCL can't cross-compile" is not what I mean, and I've written a whole post arguing otherwise. Building SBCL for a new architecture is very much a cross-compilation process: a host SBCL runs `make-host-1` to produce a cross-compiler for the target.

What that process cannot do is escape needing a live target. When I [built SBCL for RISC-V]({% post_url 2025-05-06-SBCL-development-on-riscv-architecture %}), the actual driver was:

```bash
sh cross-make.sh -p 2222 sync ubuntu@localhost /home/ubuntu/sbcl \
  "GNUMAKE=gmake SBCL_ARCH=riscv64 CFLAGS='-fsigned-char'"
```

That `sync` and that port 2222 are the giveaway. The script rsyncs the tree into a QEMU RISC-V VM over SSH and runs the target-side build steps *inside the VM*. The cross-compiler gets you `make-host-1`. Everything after it needs a machine that can execute RISC-V code.

So the RISC-V work is prior art that corroborates the Nyxt conclusion rather than contradicting it. Cross-compiling the compiler: possible. Cross-dumping an application image: not. Both cases need a target execution environment, and the only thing that varies is what supplies it.

The interesting difference is cost. That post notes native SBCL compilation under QEMU RISC-V takes 3-4 hours, because every instruction is emulated. Here the container is aarch64-linux on aarch64 Apple Silicon, so the guest architecture matches the host and there's no emulation penalty at all. Same structural requirement, wildly different price.

## what's actually left

The binary is Linux, built for the container. Its interpreter is a `/nix/store` glibc, so it runs there and not on the host. To get it on screen I'd need XQuartz and X11 forwarding.

The more interesting direction is that nixpkgs has SBCL 2.6.5 for `aarch64-darwin` natively, and Electron ships macOS builds. So a native macOS Nyxt looks plausible without any container at all, which would sidestep the display problem entirely. Nyxt's own docs call macOS support "in development." That's the next thing I want to try.

## resources

- [Common lisp disassembly through SBCL on RISC-V architecture]({% post_url 2025-05-06-SBCL-development-on-riscv-architecture %}), my earlier post on cross-building SBCL, which needed a QEMU target for the same structural reason
- [Nyxt](https://github.com/atlas-engineer/nyxt) and its developer manual
- [deddu/nyxt-docker](https://github.com/deddu/nyxt-docker), the image linked from Nyxt's download page
- [nix.dev: Cross compilation](https://nix.dev/tutorials/cross-compilation.html)
- [SBCL manual: Saving a Core Image](https://www.sbcl.org/manual/#Saving-a-Core-Image)
- [Software Heritage](https://archive.softwareheritage.org/)
- [PEP 632](https://peps.python.org/pep-0632/), deprecating and removing distutils
