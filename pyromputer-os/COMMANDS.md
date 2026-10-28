# Commands: what this shell has, and what it deliberately does not

This file records the comparison between the commands a minimal Linux userland
ships and the commands this project provides. It exists because the list was
worked out once, in conversation, and never written down -- so the next person
(or the next session) could not check it or build on it.

The reference set is **stated below** rather than assumed, so the coverage figure
can be recomputed instead of trusted. It is the applet set of a "kernel plus a
small userland" system: coreutils, util-linux, procps and the common shell
utilities.

## Coverage

| | count |
| --- | --- |
| commands in the reference set | 153 |
| provided by this project | 92 |
| **coverage** | **60%** |
| absent | 61 |

Built-in names in `usr/psh.lua`: 122. External commands in `usr/cmd/`: 11.

## Present

```
at awk base64 basename bg cat chgrp chmod chown cksum clear cp craftos crontab cut
date df dirname disown du ed egrep env expr false fg fgrep file find free gpasswd
grep groupadd groupdel groups head hostname id jobs kill last lastlog ln ls
man md5sum mkdir mktemp mount mv nproc passwd printenv ps realpath reboot rev
rm rmdir sed seq service sha256sum sleep sort stat su sudo tac tail tar tee
test top touch tput tr true tty umount uname uniq uptime useradd userdel
usermod users w wc who whoami xargs yes
```

## Absent, and why

Two absences are decisions rather than gaps, because the platform cannot support
the command. They are recorded instead of being faked:

* **`readlink`** -- CraftOS has no symbolic links. There is nothing to read, so
  every call would exit 1 and print nothing. A command that can never succeed is
  not worth shipping.
* **`timeout`** -- the scheduler is cooperative. A command that never calls
  `pullEvent` cannot be preempted, so a deadline could not be enforced against
  exactly the runaway command the tool exists for. `lib/interrupt.lua` documents
  the same limitation for Ctrl+C.

A third was a defect rather than an absence, found while doing this comparison and
since fixed:

* **stderr redirection used to be neither supported nor rejected.** `echo hi 2> f`
  wrote the literal text `hi 2` into `f` and exited 0; `echo hi > f 2>&1` exited 127
  with "command not found", and `2>/dev/null` silently discarded the wrong thing.
  `2>`, `2>>` and `2>&1` are now real, including the order in which they appear.
  See ROADMAP.md section 6.8.

The remaining absences are the interactive and system-management tools a
multi-user Linux box has and a single-console CraftOS computer does not need to
imitate: `vi`/`less`/`more`, the `mkfs`/`fsck`/`fdisk` family, `systemctl`,
`dmesg`, `nice`/`renice`, and the process-tree and paging utilities. Where a
CraftOS equivalent exists it is used instead of the Linux name -- disk images are
drives presented by the host, so `mount`/`umount` and `ls` speak in terms of
`/disk`, not block devices.

## Not a gap

Some commands look absent from the table but exist under another name, because
the platform's model is different rather than poorer:

* `shutdown`/`halt`/`poweroff` are not commands here: `reboot` restarts the
  machine, and powering it off is the host's business.
* `service`/`systemctl` are replaced by `service` plus the unit files in
  `lib/services.lua`, which is a smaller model of the same idea.
* `lsblk`/`blkid` are replaced by `disk`, which reports the drives the host has
  presented and which of them carry a package store.

## Not a command: CJK text

`cc_chinese` is a package rather than a command. Its glyphs live on a medium
carrying `cc_fonts.marker`, built with `python tools/fontdisk.py`; a CraftOS
computer holds 1 MB and the shell already uses about three quarters of it, so the
font can never live on the machine itself. The shipped glyphs are rasterised
from Noto Sans SC, which is under the SIL Open Font License 1.1; the licence
text and the attribution are in `THIRD_PARTY_LICENSES` at the repository root.
See ROADMAP.md section 6.3.
