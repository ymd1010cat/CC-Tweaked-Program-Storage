pyroet-os/examples/ README
==========================

Installable sample packages. None of these is image payload: install.set never
lists them, so a freshly flashed computer does not have them. They exist so the
Installer UI has something to install and so the optional features (file
manager, network panel, browser) stay in the tree without costing image space.

Layout convention (DECISIONS.md 33.2): one package per directory,
examples/<name>.app/{manifest.lua,main.lua}. Install one by copying the
directory to /pkgs/<name>.app/ and using the Installer UI, or by pointing the
installer at a disk that carries it.

    net.app     caps net.rpv, fs.read, fs.write, input, terminal
                Network panel: adapter status, route/ARP view, probe a host.
                The image itself registers a bare net service; this app is the
                interactive view of it.

    files.app   caps fs.read, input, terminal
                Text file manager: browse, view, enter/leave directories.

    web.app     caps fs.read, http, input, terminal
                Text HTTP browser (enter opens, a edits the address, b back,
                r reload, q quit). NEEDS A HOST http TABLE: it calls
                api.http.get, and a stock pocket computer ROM usually has no
                http table, so it reports "browser unavailable: no http host"
                and quits cleanly. That is deliberate: the OS-owned download
                path (appstore, OTA) is RHTP over rpv and does not depend on a
                browser. Treat web.app as a demo for hosts that do provide
                http, not as the way to fetch software.

Testing note: the offline suite stages copies of these under /tests/ (see
tests/run-tests.ps1), so editing them is covered by t_files / t_net_app /
t_web rather than only by hand.

No non-ASCII bytes in this file.
