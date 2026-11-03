# Applications in the fat world

What `Genera-8-3-fat.ilod.4` (the fat image's default world, version 3)
holds, against the application checklist, as of Nov 2 2026 (core build 42).
How it was built: [NOTES.md](NOTES.md#the-fat-world-version-3-nov-2-2026).
The image of Nov 3 boots `Genera-8-3-fat-init.ilod.1`, the same world with
the color screen made at login
([NOTES.md](NOTES.md#the-color-screen-at-login-nov-3-2026)).

## Works on the MiSTer

- Genera's own tools: Zmacs, Listener, Debugger, Inspector, Flavor Examiner,
  Peek, Document Examiner, Frame-Up, Zmail, Converse, Terminal, File System
  Operations, Notifications, Font Editor (each opens; Zmacs edits and saves)
- CL-HTTP 60.57: `(http:enable-http-service)` after login; a browser on the
  LAN gets its documentation pages and images
- TeX 2.9 (plain format): `TeX file` writes a DVI; the DVI Previewer
  (Select `\`) shows it
- Color, on the Univision screen (`(color:make-mister-color-screen)`): the
  Images system shows Symbolics' 8-bit sample images (`images:mandelbrot;`,
  `images:8bit;`), Color Demo's patterns; S-Colorize opens
- Statice: a Statice file system, XLDB, with the tutorial's bank database;
  `(load "xl1200:>lispm>bank.lisp")`, then `(bank-accounts)`
- Concordia's lock server: the XL1200 serves the locks Concordia takes before
  saving (a save from Concordia itself not yet tried)
- Joshua 237.3 and Jericho 237.0 with their examples
- CLIM 66.3 demos (the launcher)
- Ethernet: ping, FTP, HTTP on the LAN

## Works in the emulator, not yet tried on the MiSTer

- Screamer 3.12: `(screamer:all-values (screamer:an-integer-between 1 5))`
- Soar 5.2.2: `(soar-load "sys:contributed;soar;lib;default;default.soar")`,
  a task's file the same way, then `(run)`; the waterjug task solves

## Loads, not yet used

Symbolics C, Fortran and Pascal; Conversion Tools; Joshua Metering; DBFS
Utilities; Concordia with Graphic Editor, Bitmap Editor and PostScript;
Metering; Hacks; NFS Server, X Server, Mailer, Domain Name Server, Print
Spooler, DNA; Color Editor, FFT, Fourier Fractals, Graphics Library and
Toolkit, S-Convert, S-Compositor; LaTeX, SliTeX, YTeX, BibTeX, INITeX,
VIRTeX, TANGLE, WEAVE, DVItype, POOLtype, TFtoPL, PLtoTF; HTTP Base Client,
W3P, W4, W4 Examples, CL-HTTP-CLIM, HTML Parser.

## Blocked or limited

- Illustrate 425: loads, but its frame never appears (it stalls with no
  window selected; Select `L` gets the Listener back)
- Macsyma 421.45 and NS 36: start, then ask for their license passwords
- 24-bit images (the Mandrill, Cézanne): reducing them to the board's 8 bits
  stops on an undefined `COLOR:IMAGE-PROCESS-MACRO-INTERNAL`
- Fourier Fractals computes images, but they show without a color map

## Elsewhere on the disk

- Flavors Statice 441: its own world, `FEP7:>Genera-8-3-flavors-statice.ilod`
  (it can't share a world with Statice)
- The S-Graphics programs (S-Paint, S-Dynamics, S-Geometry, S-Render,
  S-Record): the Genera 8.1.1 animation world, `animation-mac-6-2-color.ilod`,
  which makes the color screen at boot and holds Craig Reynolds' Boids
  (`(boids:demo)` in S-Geometry's command pane)

## Not included

HTTP Proxy and Lambda-IR (only in CL-HTTP's later 67.87 release),
CParaOPS5 (C, not Lisp), the FrameThrower.
