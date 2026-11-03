# Testing the fat world's applications

Log in first: `Login Lisp-Machine`. Any program named below also starts
with `Select Activity NAME` (Help after `Select Activity ` lists all 51).
Type `(` and `)` with `[` and `]`.

Marks: **MiSTer** seen working on the core, **emulator** only in the
emulator, **untried**, **known problem**.

## Genera's own tools

- Listener: Select L; `(+ 1 2)`. MiSTer
- Zmacs: Select E; `c-X c-F XL1200:>lispm>test.lisp`, type, `c-X c-S`. MiSTer
- Document Examiner: Select D; type a topic at its prompt. MiSTer
- Debugger: `(car 1)`; Abort leaves it. MiSTer
- Inspector (Select I), Peek (P), Zmail (M), Converse (C), Terminal (T),
  Notifications (N), Frame-Up (Q), Flavor Examiner (X), File System
  Operations (F): each opens. MiSTer
- Font Editor: `Select Activity Font Editor`. MiSTer
- Namespace Editor, Keyboard Control, Select Key Selector (also Select `=`),
  Bitmap editor, Graphic Editor, Stipple editor: by name. untried
- Speed: `Load File FEP7:>gabriel-benchmarks.ibin`, then
  `(gabriel::run-series)`. MiSTer (Oct 2026)

## Languages

- Symbolics C: `Select Activity C`; `,printf("hello\n");` then End. untried
- Fortran, Pascal: loaded; their guides are in the Document Examiner. untried

## Color and graphics

Make the color screen first, once per boot: `(setq cs
(color:make-mister-color-screen))`. On the Nov 3 image, login does it. The
core's Display option shows it (Pause on the next core build).

- Color Demo patterns: `(setq w (tv:make-window 'tv:window :superior cs
  :expose-p t :left 0 :top 0 :width 1152 :height 880))`, then
  `(color::test-colors w)`, `(color::full-field-color-bars w)`,
  `(color::smpte-color-bars w)`. MiSTer
- A Listener on the color screen: `(tv:make-window 'tv:lisp-listener
  :superior cs :expose-p t)`. MiSTer
- Color Demo menu: `(color::demo)`. untried
- Images: `Load Images` from `IMAGES:8BIT;` or `IMAGES:MANDELBROT;`, then
  View Image. The 8-bit samples MiSTer; 24-bit ones (`IMAGES:PAINT;MANDRILL`)
  known problem (undefined `COLOR:IMAGE-PROCESS-MACRO-INTERNAL`)
- S-Colorize: by name. MiSTer (opens)
- S-Compositor, S-Convert: by name. untried here
- Color Editor: `(color::color-editor)`. untried
- Fourier Fractals: known problem (images show without a color map)
- CLIM demos: `(clim-demo::start-demo)` opens the launcher (CAD, navigation,
  puzzle, address book, Thinkadot, plotting, editors, polyhedron, browser).
  MiSTer (launcher); each demo untried
- CLIM Lisp Listener, Browser: by name. untried

## Reasoning and search

- Joshua and Jericho: the grandparent, Tweety and circuit diagnosis
  examples answer. MiSTer. `Select Activity Jericho`: untried
- Joshua's demo programs: Blocks World, Cryptarithmetic Solver, Factory
  Simulator, Hardware Troubleshooter, Modelling Tutor, N Queens, by name.
  untried
- Screamer: `(screamer:all-values (screamer:an-integer-between 1 5))` gives
  `(1 2 3 4 5)`. emulator
- Soar: `(soar-load "sys:contributed;soar;lib;default;default.soar")`, a
  task file the same way (waterjug), then `(run)` without touching the
  keyboard. emulator

## Databases and documents

- Statice: `(in-package "STATICE-USER")`, `(load
  "xl1200:>lispm>bank.lisp")`, `(bank-accounts)`, `(make-new-account "Dave"
  10)`, `(transfer-between-accounts "Alice" "Dave" 5)`. MiSTer
- Statice browser: `Select Activity Statice`, then pick it. untried
- Concordia: `Select Activity Symbolics Concordia`; saving a record is the
  open test (its lock server answers). untried
- TeX: `TeX File XL1200:>lispm>test.tex`, then the DVI Previewer (Select
  `\`). MiSTer. LaTeX, SliTeX, YTeX, BibTeX: untried
- Illustrate (Interactive Illustrator): known problem, the frame never
  appears; Select L gets the Listener back

## Network

- Web: `(http:enable-http-service)`, then `http://192.168.50.92/` from a
  browser. MiSTer
- FTP: `ftp 192.168.50.92` from the Mac answers `220 FTP service ready`.
  MiSTer (over WiFi)
- X11 Server: by name, then an X client from the Mac at display
  `192.168.50.92:0`. untried
- NFS Server, Mailer, Store-and-Forward Mailer, Domain Name Server, Print
  Spooler, DNA: services that need configuring. untried

## Licensed

- Macsyma, NS: by name; known problem, they stop at their license passwords

## Fun

- Hacks: `(hacks:demo)` for Life, Qix, Munching Squares, Worm and the rest.
  untried here; the sound ones are silent (the core has no audio)

## The disk's other worlds

At the FEP prompt after `Hello`, in place of `Boot`:

- Animation world: `Load World FEP7:>animation-mac-6-2-y2k.ilod`, `Start`;
  S-Paint, S-Geometry, S-Dynamics and the other S-Graphics programs open from
  their Select keys. MiSTer
- Flavors Statice: `Load World FEP7:>Genera-8-3-flavors-statice.ilod`,
  `Start`. untried
