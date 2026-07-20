---
layout: post
title:  "Asus USB WiFi"
date:   2021-07-05 14:23:25 -0400
categories: linux
---
Getting an ASUS USB-AC53 Nano working on Arch Linux

Inspired by [Wayne Khan Post for Ubuntu](https://web.archive.org/web/20201015122532/https://waynekhan.github.io/2020/05/30/asus-usb-ac53-nano-ubuntu.html)

I found it difficult to initially get the external Wi-Fi card working properly following Khan's post.
The major difference being that this arch AUR repo greatly simplified things.
Just make sure you have the base-devel package installed.

``` bash
yay install dkms
git clone https://aur.archlinux.org/packages/rtl88x2bu-dkms-git/
cd rtl88x2bu-dkms-git
makepkg -si
VER=$(sed -n 's/\PACKAGE_VERSION="\(.*\)"/\1/p' dkms.conf)
sudo rsync -rvhP ./ /usr/src/rtl88x2bu-${VER}
sudo dkms add -m rtl88x2bu -v ${VER}
sudo dkms build -m rtl88x2bu -v ${VER}
sudo dkms install -m rtl88x2bu -v ${VER}
sudo modprobe 88x2bu
```

You should now have Wi-Fi access on a machine that did not come with a Wi-Fi card builtin.

Important urls

[Arch AUR git repo](https://aur.archlinux.org/packages/rtl88x2bu-dkms-git/)
[Khan's Setup on Ubuntu](https://web.archive.org/web/20201015122532/https://waynekhan.github.io/2020/05/30/asus-usb-ac53-nano-ubuntu.html)