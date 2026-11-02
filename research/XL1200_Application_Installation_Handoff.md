# XL1200 application installation handoff

Prepared 2026-10-31 for a native Ivory / Symbolics XL1200 FPGA core.

## Objective and recommended worlds

Use the original media in `Symbolics_XL1200_Master.zip` to produce useful native application worlds. The strongest path is:

1. **Genera 8.3 applications world:** the development environment, native languages, CLIM, Joshua, Concordia, Statice, CL-HTTP and its web tools, Illustrate/TeX after compatibility testing, and the 8.3 Color tools.
2. **Genera 8.1.1 graphics world:** derive from the recovered `animation-mac-6-2.ilod.1`, retaining its already-loaded S-Graphics and FrameThrower versions. Add Boids here.
3. **Experimental native worlds:** independent copies for Macsyma and NS binary recovery; a separate Flavors Statice world if that older API is wanted.

The files, system manifests and saved-world objects have been inspected. Native application load/start/save tests on the FPGA core remain to be performed. A native payload inventory is stronger evidence than a product name in a manual, but it is not a recorded runtime test.

## 1. Inputs and where applications live

Locate these basenames after unpacking the master ZIP; retain their original archive bytes.

| Input | Useful contents | Extraction / installation route |
|---|---|---|
| `bolix_cd.iso.gz` | Native Genera 8.3 world; ordinary system sources; C/Fortran/Pascal; CLIM 52; Statice runtime; Color tools and drivers | Decompress to ISO. Restore its distribution tape images from within Genera, or use its source tree with correct logical translations. |
| `MacIvory_Virginal_9GB.img.7z` | Physical-machine disk containing native application files and the full animation world | Extract the FEP world and LMFS files with the supplied recovery helpers. Its Macintosh partition map is not an XL disk layout. |
| `symbolics_native_lmfs_recovery.tar.gz` | Already-recovered, byte-preserved native files from that physical disk | Convenience alternative to repeating extraction. Contains `lmfs_recovered/` plus pathname, file-byte-size, hash and version inventories. |
| `animation-mac-6-2.ilod.1.gz` | Full native Genera 8.1.1 graphics world | Decompress, place on the XL's FEP filesystem, boot and adapt its site/display configuration. |
| `Illustrate.tar.gz` | Original multipart native Illustrate distribution tape | Join its numbered pieces, then `Restore Distribution :Use Disk Yes`. |
| `TeX.tar.gz` | Original multipart TeX-family tape plus loose pool files | Join numbered pieces; restore tape; separately copy the two pool files. |
| `sys.sct-e97efaabf6aef64e6e63a457e1be7651256628d9.tar.gz` | Later Genera sources; Macsyma/NS donors; original native CL-HTTP distributions under `contributed/cl-http/distributions/` | Restore the embedded CL-HTTP reels, or selectively use source/compiled donors. Keep the newer SYS tree separate from the working 8.3 tree. |
| `clim2-6af41f1a6457ddcafbbde47939b432fe78453fdb.tar.gz` | Franz CLIM sources retaining Genera backends | Source-port donor; the top-level build is for Allegro CL. |
| `joshua-dist-4078b32ac8e87887ff8ab5bced38b0d48991672a.tar.gz` | Additional Joshua source distribution | Secondary source/reference donor; prefer the recovered native 237.3 files for the first installation. |
| `boids.lisp` | Craig Reynolds's original native Boids implementation | Compile/load in the compatible graphics world, supply a local bird model and use record mode. |
| N-World/Mirai ZIPs and `nichimen.tar` | Later Windows/Allegro applications, saved worlds, patches and limited extension source | Behavioral/introspection references for reverse engineering. No direct native Ivory installation route is established. |
| `genera_native_recovery_audit.zip` | Extraction tools and detailed static validation | Consult its README and `factory_recovery/` manifests before changing filenames, file-byte sizes or source versions. |

The additional XL1201 filesystem snapshots and I333 FEP distribution are bootstrap/reference material, not additional applications.

## 2. Base Genera applications and loadable tools

Use the full `WORLDS/GENERA_8_3.ILOD` development world as the 8.3 starting point. The small MacIvory/UX delivery worlds omit development functionality.

### Already provided by the development environment

The ordinary native world provides Zmacs, Dynamic Lisp Listener, the source debugger, Inspector, Flavor Examiner, Peek, Frame-Up, Document Examiner, Zmail, Converse, Terminal, and filesystem/site tools. Restore their source/documentation/font data so navigation and help work after boot. A saved world does not contain every external documentation record or source file.

These activities are useful individual acceptance targets: edit/compile a Lisp function in Zmacs; inspect and debug it; open Frame-Up; browse a document record; inspect processes in Peek; open and save a local Zmail mailbox. Remote messaging/mail needs a configured peer/service in addition to the application.

### Additional systems from the CD / native tree

| Application or family | Native payload / entry point | Installation detail |
|---|---|---|
| **Symbolics C** | Native system 437 is present; `Load System C` | Restore `8_3_FPC_DIST.TAPE`. Preserve compiler-tools, grammar/parser, runtime, headers and syntax-editor dependencies. Create writable `SYS:C;TMP;` as the C guide specifies. |
| **Symbolics Fortran** | Native system 431; `Load System Fortran` | Same FPC distribution; use its matching runtime and compiler-tool components. |
| **Symbolics Pascal** | Native compiler system 430; `Load System Pascal` | The runtime is a separately versioned system, present in generation 431. Also needed for rebuilding the WEB/Pascal TeX implementation. |
| **CLIM and its demos** | Native 52.7 on the recovered tree / base-CD family, and native 66.3 in the physical-disk recovery | See the dedicated CLIM instructions below. |
| **Hacks / demonstration facility** | `Load System Hacks`; `(hacks:demo)` opens the older menu | Preserve `SYS:SITE;*.DEMO` and the demo fonts. Several demos intentionally restrict themselves to the local console. |
| **Metering** | Native 439; `Load System Metering` | Performance, allocation and paging tools. Useful for core validation as well as application profiling. |
| **Conversion-Tools** | Native 430; `Load System Conversion-Tools` | Source converters for dialect/object/UI transitions. Use individual transformations deliberately when porting. |
| **FED font editor** | Native IBIN and source in `SYS:UNSUPPORTED;` | Load `SYS:UNSUPPORTED;FED-SYSDCL.LISP`, then `Load System FED` if no site registration exists. |
| **Graphic Editor / Bitmap Editor / PostScript** | Native dependencies accompanying Concordia | Useful drawing and output tools; let Concordia's component declarations select the matching versions. |
| **X Server** | Native 424; `Load System X-Server` | Runs X client displays on the XL console. Requires its C-runtime component and X server fonts. |
| **X Remote Screen** | Native 440 | Displays Genera on an external X server. Configure the namespace service and remote fonts/key mapping. A CLIM application can still choose the physical console unless its port/frame manager is selected appropriately. |
| **NFS Client / Server, IP-TCP** | Native client 436, server 435, IP-TCP 446 | File-transfer and network infrastructure; `NFS-Server` includes the client. Preserve RPC and namespace definitions. |
| **Mailer / Domain Name Server / Print** | `Load System Mailer`, `Domain-Name-Server`, `Print` | Server applications need spool/data directories and service configuration. They are distinct from the interactive Zmail client and ordinary hardcopy commands. |
| **DBFS-Utilities** | Native Statice backup/restore tools | Load the corresponding Statice runtime first. |
| **FireWall application framework** | Source under `SYS:UNSUPPORTED;FIREWALL;` | Optional older application-shell code. It changes menus, boot screens and error handling; evaluate in a separate development world before adopting its initialization. |
| **Mac-Dex / HyperCard-MacIvory examples** | Lisp-side systems on the CD | Require a classic Macintosh frontend and embedding/RPC setup to be useful. Low priority for a standalone XL console. |

The numbered native versions in this table are observed component-directory versions. Full executable closure was specifically audited for the layered applications in section 3, not freshly re-audited for every optional tool listed here.

### Demos actually available

The Hacks system registers: **Abacus, Birds, Crock, Digital Crock, Escher, Goedel, Hollerith Editor, Lexiphage, Life, Munching Squares, Munching Tunes, Qix, Rotate, Splines, TV-Bug, Worm and Zowie**, plus its aggregate menu. The Birds demo is a separate display hack; Boids is the 3D program discussed later. Sound-oriented demos exercise the console's audio facilities. Local-screen restrictions in the `.DEMO` files can explain why a demo is absent or disabled over X.

The native CLIM demo set includes **CAD drawing, navigation, the sliding puzzle, address book, Thinkadot, plotting, color editor, graphics editor, bitmap editor, rotating polyhedron, browser, Peek frame, CLIM listener, custom output records and general graphics demonstrations**. Preserve their data and support modules rather than selecting only the visually interesting Lisp filenames.

## 3. Recovered native layered applications

These are the best additions to a clean 8.3 development world.

| Application | Verified native version | Available code | Route and special requirements |
|---|---:|---|---|
| **Joshua** | 237.3 | 20/20 core IBINs, all three native patches, core sources, examples/data | Register `JOSHUA:` correctly. Its physical files are under recovered `sys/code/`, `sys/examples/`, `sys/data/`, not necessarily `sys/joshua/`. Load the 237 native set. |
| **Jericho / Joshua demos** | Matching recovered example set | All 12 declared compiled example/test modules and corresponding source basenames are present | `Load System Jericho` after Joshua. Includes planning, widget factory, model tutor, truth-maintenance, cryptarithmetic and family-relation examples; retain the chess font and Demosthenes demo substrate. |
| **Joshua-Metering** | 206 | Native two-module set and source | Requires ordinary Metering plus Joshua; useful for diagnosing rule-system performance. |
| **Concordia** | 439.1 | 23/23 core IBINs, patch, native dependencies and sources | Retain Image-Substrate 435, Graphic-Editor 435, Bitmap-Editor 436, PostScript 431, Concordia-Doc 429 and Lock-Simple 432. Configure file locking before testing save. |
| **Statice Runtime** | 460.4 | 45/45 core IBINs and four patches, plus local/server/UFS source material | Load before developer tools. Configure writable database storage and services; a loaded runtime alone does not create a usable database. |
| **Statice Development** | 460.1 | Four core IBINs and patch, corresponding sources | `Load System Statice`; it includes the matching browser. Define/store/query a small persistent schema as the acceptance test. |
| **Statice Browser** | 460.0 | Native browser IBIN and source | Check interactive browsing after database creation; retain the matching runtime/development components. |
| **DNA** | 434.0 | 20/20 native binaries and exact corresponding source versions | DECnet/Digital Network Architecture software. Load `DNA`, then configure its addresses/namespace and a peer if communications are to be tested. |
| **CLIM** | 66.3 | 107 core IBINs, three core patches, eight Genera backend modules, seven CLX modules, four PostScript modules and 20 demo modules | Prefer this recovered native set for the newer installed CLIM. Core implementation source for 66 is absent; the CD has the older native 52 implementation source. |
| **Older CLIM** | 52.7 | Native base/patch set; implementation source on the CD | Useful source baseline and alternate world. Do not combine component sets from 52, 66 and the donor's 72. |
| **Flavors Statice** | 441 family | Older runtime/development material in recovered tree | Build a separate world. Flavors and CLOS Statice clients cannot coexist in one running world. |

### CLIM: load the display port as well as the core

After selecting a consistent released native version and its component map, the ordinary Genera sequence is:

```text
Load System CLIM
Load System Genera-CLIM
Load System CLIM-Demo
Load System CLIM-Doc
```

The original manual gives `(clim-demo::start-demo)` as the demo launcher. Add `CLX-CLIM` for an X port and `PostScript-CLIM` for that output backend. Loading only CLIM can produce `Cannot find port type: :GENERA`. Avoid upgrading an already-populated incompatible CLIM world in place; start from the clean base when changing major implementations. The manual specifically forbids loading CLIM 2 over a loaded CLIM 1.0/1.1.

### Concordia: locking and documentation state

Concordia can open its editor successfully and then fail to save because the file host does not implement `LOCK-SIMPLE`. Configure a lock service or a surrogate lock server and the site's `LOCK-SIMPLE-SERVER` property. Check actual save/reopen, not only activity startup.

For authoring that cross-references Symbolics documentation or uses patchable documentation systems, the documented setup includes `(sage:load-doc-database-for-writer)` after loading Concordia. This reconstructs writer-side documentation indexes and needs the corresponding documentation files. It is unnecessary for some isolated documents. Nineteen Concordia/Graphic Editor illustration files were absent from the recovered manifest; this is separate from executable completeness.

### Source rebuilds

Prefer the matching native released binary sets for the first installation. Several installed source revisions are newer than those recorded in their baseline component manifests: Joshua's matcher 218/object-model 94 are replaced by 220/95; Concordia patch 29 by 30; Statice defining-forms 14 by 15; six Statice runtime sources also differ. Some application patches survive only as binaries.

Use a new local SCT system version for a rebuild. A previously syntax-checked example is:

```text
Compile System Joshua :Version Newest :Condition Always :Load Everything :Copy Compile No
Load System Joshua :Version Latest
```

Review which released patches are already incorporated. Joshua patch 237.3 calls for recompiling object-type definitions after its object-model fix. Compile under native Genera to produce the IMach/IBIN target.

The later `sys.sct` donor is not a drop-in OS upgrade: its Concordia 444 expects a newer NSAGE environment, and its Statice 466 tree lacks 21 of 22 declared server implementation modules. The recovered native 460 tree is the stronger complete server starting point. The Franz CLIM repository requires adapting its Allegro-oriented build to the historical Genera definitions; preserve the useful Genera backend source without adopting its top-level build unchanged.

## 4. Native 8.3 Color applications on the CD

The base CD contains real native application code for more than display support. The recovered Color-Distribution 21 component manifest lists these IMach inputs:

| Application / system | Component version | Purpose / special requirements |
|---|---:|---|
| **Color** | 426 | Display/framebuffer, palette and image foundation. Configure the device implemented by the core. |
| **S-Colorize / Colorize-Tables** | 23 | Color-table and color-correction tools. |
| **S-Compositor / Compositor** | 15 | Image compositing and image-processing workflow. |
| **S-Convert / Convert** | 12 | Image-format conversion; device-specific conversion paths may need their historical devices or file equivalents. |
| **Fourier Fractals / FFractals** | 21 | Procedural image generation. Uses the FFT subsystem. |
| **FFT** | 11 | Numerical image/transform library supporting the graphics tools. |
| **S-Record / Record** | 70 | Frame/sequence recording and external video-device control. Controller-dependent operations need the corresponding emulated device or a new file-output backend. |
| **Images / Color Editor / Color demos** | Select from matching native manifests | Image viewing/manipulation, palette editing and display demonstrations. |
| **FrameThrower** | 13 | Native display hardware support. |
| **FrameThrower XL Interface** | 13 | XL-side interface; use with the matching driver generation. |
| **FrameThrower Utilities / Diagnostics** | 8 / 7 | Bring-up, configuration and hardware tests. |
| **Abekas-Exabyte-Support** | 6 | Historical video/tape interchange support. |
| **Field-Mouse / GLIB** | 5 / 13 | Supporting UI/library components, not additional standalone end-user programs. |

### Two easy-to-miss Color installation issues

**Restore the CD's top-level application directories.** `Compositor`, `Colorize-Tables`, `Convert`, `FFractals` and `Record` resolve through the `GRAPHICS:` logical host to `<application>;CODE;SYSDCL.LISP`. The CD stores these outside `/SYS`. Copying only the `/SYS` directory loses the actual utility code even though their `.SYSTEM` registration files remain. Preserve image/sample directories too.

**Inspect the IMach component map even when an outer directory looks 3600-specific.** The recovered Color-Distribution top-level system directory lists a `:3600` entry, but the released component manifest explicitly contains `:IMACH` inputs. Individual `Load System` operations are a useful way to diagnose this old packaging rather than infer that the entire collection is inapplicable.

The distribution can be restored from `DISTRIBUTION/8_3_COLOR_DIST.TAPE`. `Color-Distribution` is the aggregate system; direct systems include `Color`, `Colorize-Tables`, `Compositor`, `Convert`, `FFractals`, `FFT` and `Record`.

The CD also includes `COLOR_FROM_GENERA_8_3.ILOD`, an incremental Color world. Retain its exact Genera 8.3 parent. This is a different image from the full animation world below. The CD's `/PAINT` and `/RENDER` directories contain example pictures/documentation, not complete standalone S-Paint/S-Render installers.

### FrameThrower assets particularly relevant to the FPGA core

The physical disk preserves `SYS:COLOR;FRAMETHROWER;MICROLOAD-74.IBIN.1` and FEP0 `I328-FRAMETHROWER.SYNC.1`. The microload payload is 1,873,240 octets (936,620 16-bit file units). Retain these auxiliary assets when collecting the driver. Only part of the FrameThrower implementation survives as Lisp source; the recovered subtree has 37 IBINs and 9 Lisp files, largely declarations/sync programs.

Bring up simple framebuffer access, color patterns and driver initialization before attributing high-level graphics failures to missing application code. Status-register waits and microload/sync handling are concrete dependencies on the core's device implementation.

## 5. S-Graphics: boot the already-loaded native world

`animation-mac-6-2.ilod.1` is a full, generation-zero native Ivory world: **Genera 8.1.1 / System 436.39**, with no incremental parent. Its standalone uncompressed length is 101,016,320 bytes and SHA256 is:

```text
579b6c6c628789fd4c4a9ada177b4ef2bd57b4d8eb7bfe1d4171dd8586b27931
```

Its saved live system state identifies:

| Application / support | Loaded version | What the agent can do |
|---|---:|---|
| **S-Geometry** | 18.5 | Modeling, scene/object/camera editing; validate with a small saved scene. |
| **S-Dynamics** | 18.1 | Animation and procedural motion; validate a short sequence. |
| **S-Render** | 33.0 | Render a tiny scene to an image before attempting a production-size job. |
| **PaintAmation / S-Paint functionality** | 8.10 | Paint functions are present as native compiled objects. The actual loaded SCT name is PaintAmation. |
| **S-RenderMan** | 8.0 | RenderMan-related integration. A separate Renderman-Interface 10.0 also appears; this does not establish a standalone Pixar renderer. |
| **S-Record / S-Compositor / S-Convert** | 68.7 / 12.0 / 9.9 | Older recording, compositing and conversion tools already loaded in this world. |
| **Colorize-Tables / Fourier Fractals / FFT** | 20.3 / 18.0 / 8.0 | Matching color-correction and procedural-image tools already loaded. |
| **Color** | 422.21 | Older color support paired with this world. |
| **FrameThrower** | 10.52 | Already-loaded older driver. |
| **FrameThrower XL Interface** | 10.1 | Already-loaded XL interface, despite the disk archive's MacIvory provenance. |
| **FrameThrower Utilities / Diagnostics** | 6.27 / 5.5 | Matching older support. |
| **Ivory Color Support** | 10.1 | Native architecture support. |

Boot and derive this world using the XL FEP, then repair site, paths and display/device configuration. The source-disk recovery validated world word order against an independently known native CD world. The recovered `.ilod` already has the correct standalone byte order.

Do not attempt to install this world into the 8.3 world with `Load File`. There are no recovered standalone S-Geometry/S-Dynamics/S-Render implementation trees that make that an ordinary SCT install. Transplanting their loaded objects into 8.3 would require resolving function, Flavors, package, data-layout and runtime dependencies. Preserve the working old world as the first deliverable.

Likewise, do not overlay the 8.3 FrameThrower 13/XL13 tree onto its 10.52/10.1 stack as a routine update. Use this image's own consistent components first. Its saved display/namespace state may refer to a previous site; that configuration is distinct from the application's native-code availability.

## 6. Illustrate 425.0

The original tape contains 492 catalogued files:41 native IBINs,42 Lisp files overall,24 demo files and 340 font files. Its documented baseline is Genera 8.0; 8.3 compatibility should be tested before integrating it into the main world.

On the staging host:

```sh
tar -xzf Illustrate.tar.gz
cat Illustrate-for-Genera-8-0/ill.dist.[0-9][0-9] > ill.dist
```

There are 10 parts (`00` through `09`); the assembled tape is 4,801,662 bytes. Present it to Genera as an **8-bit binary file** and use:

```text
Restore Distribution :Use Disk Yes
```

Supply its pathname at the dummy-tape prompt. Restore native Ivory binaries, sources, fonts and demonstrations, then:

```text
Load System Illustrate
```

Use `Illustrate` as the system name; the original site declaration specifically says that the convenience name `ill` does not work in Genera. Define an `ILL:` translation to the restored application tree. Registration is `SYS:SITE;ILLUSTRATE.SYSTEM.23`; the definition is `ILL:CODE;ILLUSTRATE.LISP.40`.

Retain `ILL:CODE;GENERA-WELCOME.IBIN.425`: the system declaration marks it `:lisp-load-only`, so a source rebuild must retain that supplied module. Preserve the font-family data. The declaration uses ordinary Genera window/font support and does not declare another layered application as a prerequisite. Test editing, save/reopen and output; rebuild selectively if newer Genera private interfaces differ.

## 7. TeX family 425.0 / TeX-SCT 425.1

The tape contains 1,799 unique catalogue paths and 42 native IBINs. It supplies **Plain TeX, LaTeX, SliTeX, YTeX, BibTeX, a DVI previewer, INITeX, VIRTeX, TANGLE, WEAVE, DVITYPE, POOLTYPE, TFtoPL and PLtoTF**, with prebuilt formats and 80/240/300 dpi fonts. These are the historical supplied macro packages.

On the staging host:

```sh
tar -xzf TeX.tar.gz
cat TeX-for-Genera-8-0/tex.dist.[0-9][0-9] > tex.dist
```

There are 29 parts (`00` through `28`); the joined tape is 15,203,527 bytes. Restore through `Restore Distribution :Use Disk Yes` as 8-bit binary. Files principally target `SYS:TEX;`, with registrations under `SYS:SITE;`.

**Separately copy these loose files, which are not in the distribution-tape catalogue:**

```text
TeX-for-Genera-8-0/initex.pool  -> SYS:TEX;INITEX.POOL
TeX-for-Genera-8-0/virtex.pool  -> SYS:TEX;VIRTEX.POOL
```

Their original generated Pascal code names exactly those pool paths. Use the appropriate text-file translation for those text files. Keep prebuilt `.FMT` files, macro sources and font metrics. Restore 80 dpi fonts for the previewer.

Load desired top-level systems individually:

```text
Load System TeX
Load System LaTeX
Load System BibTeX
```

The top-level systems load DVI support and Zmacs major modes. The original README documents the `LaTeX` CP command, `LaTeX File` in Zmacs and the DVI previewer's Select-backslash binding.

### Avoid accidentally downgrading the compiler runtime

The tape bundles Pascal/Compiler-Tools/Syntax-Editor runtime generation 411; the recovered 8.3 system has generation 431. INITeX and VIRTeX depend on `pascal-runtime` by name, while their old component manifests record 411 as the build dependency.

Recommended first experiment: restore application/font files while keeping the working 8.3 runtime 431, then test. If it fails, rebuild against the 8.3 compiler or isolate the application in its older environment. This is an engineering inference from its declarations, not a completed 8.3 compatibility test.

Ordinary native loading needs the Pascal runtime. Rebuilding WEB programs additionally needs **TANGLE and the full Symbolics Pascal compiler**; the TeX-SCT compilation method explicitly loads Pascal. Regenerating formats needs INITeX, macro inputs, metrics and the pool files. Printing has LGP-specific integration, including an `lgp2-specials` module: test preview/DVI output separately from historical printer support.

Both tape formats contain metadata and compressed payloads. Use Genera's original restorer rather than treating the joined `.dist` file as a TAR archive or implementing an ad hoc unpacker.

## 8. Original Boids: source adaptation on the graphics world

This source targets Zetalisp/Flavors and the native `3D:` and `DYNA:` APIs. Preserve its file attributes/package declaration. There is no preinstalled Boids SCT system in the recovered world.

Concrete setup and repair work:

1. Replace the absent model **`W:>cwr>Boids>Very-low-res-boid`** with a compatible local S-Geometry bird/arrow template.
2. `MAKE-FLOCK` defaults to **`:flock-recording-mode :playback`**. Explicitly choose **`:record`** for a fresh simulation. This records in memory; `:record-to-file` additionally needs local output paths.
3. After construction, initialize positions/headings/speeds with `INITIALIZE-FLOCK` / `:INITIALIZE-MEMBERS` before piloting.
4. Use an active S-Dynamics sequence/script and its normal **one-based frame lifecycle**. Recording indexes `(1- DYNA:*CURRENT-FRAME-NUMBER*)`; starting at frame zero produces a negative index.
5. Inspect `FLOCK-TEST` before using it: its numeric-repeat exit condition can stop immediately. Repair that helper or use the normal animation lifecycle.
6. Diagnose the bare `3d:` reader token and historical control characters under the native reader; preserve originals and keep repairs in a local copy.

Compile/load after the graphics suite works; test a small flock and replay before scaling up. Add a local SCT definition for repeatable builds.

## 9. CL-HTTP, web clients, crawler, proxy and information retrieval

The master already contains substantial web software inside the pinned `sys.sct` archive. Its `contributed/cl-http/` tree has 531 files, including 251 Lisp files and 224 VBINs, plus these original distributions:

| Original file under `contributed/cl-http/distributions/` | Bytes | Installation role |
|---|---:|---|
| `lispm-60-57.reel-1.~1~` | 6,347,694 | Preferred native Genera 8.3 baseline. |
| `sources-60-57.tar.gz.~1~` | 4,282,251 | Matching sources, examples, documentation and web assets. |
| `lispm-67-87-pre.reel-1.~1~` | 6,351,692 | Newer distribution with native and VLM binaries. |
| `sources-67-87a-pre.tar.gz.~1~` | 8,857,058 | Newer original source distribution. |

The **60.57 reel** was written on native MacIvory Genera 8.3. Its framed records reach physical EOF correctly; all **149 unique native IBIN payloads** parse successfully, containing 5,022 I-machine functions. All expected native core binaries from its ten component manifests are present at their specified versions. It contains 360 unique payload files overall.

The **67.87-pre reel** has 714 unique payload files, including 215 IBINs and 215 VBINs. Its per-file `:COMPRESSION :SYMBOLICS` requires the original distribution decompressor, which is present in native Genera 8.3. These compressed IBIN payloads were inventoried but not decoded in this audit. Its assembly host was Genera 8.5 VLM; use 60.57 first on the 8.3 core.

### Available applications and exact system names

| SCT system | Native 60.57 distribution | Newer 67.87-pre distribution | Purpose |
|---|---:|---:|---|
| **CL-HTTP** | 60.57 | 67.87 | Web server, dynamic HTML, authentication and logging. |
| **HTTP-BASE-CLIENT** | 35.3 | 48.11 | HTTP client. |
| **CL-HTTP-CLIM** | 48.1 | 52.0 | CLIM interface to the server. |
| **W3P** | 2.2 | 7.0 | Web presentation system. |
| **W4** | 32.2 | 39.3 | Constraint-guided web crawler. |
| **W4-EXAMPLES** | 5.0 | 11.0 | Search, link-map and web-archive examples. |
| **HTML-PARSER / DTD-COMPILER** | 3.7 / 4.1 | Use separately verified matching set | HTML parsing and DTD processing. |
| **HTTP-CLIENT-SUBSTRATE** | Part of older client arrangement | 1.17 | Shared newer client support. |
| **HTTP-PROXY** | Not in this baseline | 3.0 | Proxy server support. |
| **LAMBDA-IR** | Not in this baseline | 20.0 | Full-text information retrieval and LambdaVista modules. |
| **SHOWABLE-PROCEDURES / BTREE** | 36.3 / 34.0 | 36.3 / 34.0 | Documentation and binary-tree support libraries. |

### Restore and configure

Before restoration, configure local logical translations for **HTTP, BTREE, SPT and HTML-PARSER**. The original translations refer to obsolete MIT/White House hosts. Keep the journal directories as well as the implementation directories: `BTREE:BTREE;`, `BTREE:JOURNAL;`, `SPT:SPT;`, `SPT:JOURNAL;`, `HTML-PARSER:HTML-PARSER;` and `HTML-PARSER:JOURNAL;`.

The later `site/http.translations.~56~` supplies a useful layout model mapping HTTP into `SYS:CONTRIBUTED;CL-HTTP;`. Apply that locally without importing the donor's entire SYS tree. Server and crawler definitions live at `HTTP:LISPM;SERVER;SYSDCL` and `HTTP:LISPM;W4;SYSDCL`.

Present the original reel as an 8-bit binary disk image and run:

```text
Restore Distribution :Menu Yes :Use Disk Yes
```

Supply `lispm-60-57.reel-1.~1~` at the distribution-image prompt; select and restore the desired native systems. Then, for example:

```text
Load System CL-HTTP :Version 60
Load System HTTP-BASE-CLIENT :Version 35
Load System W4 :Version 32
Load System HTML-PARSER :Version 3
Load System DTD-COMPILER :Version 4
```

SCT should bring in dependencies: CL-HTTP uses Showable Procedures, BTREE and W3P; client 35 uses CL-HTTP and Image-Substrate; W4 32 uses CL-HTTP and the client; DTD-Compiler uses HTML-Parser. Load `CL-HTTP-CLIM :Version 48` only after the matching CLIM 2 environment exists; its definition tests the `CLIM-2` feature.

Adapt the supplied configuration and URL exports, create writable `HTTP:LOGS;` and `HTTP:PW;` paths, then use the supplied startup pattern:

```lisp
(load "HTTP:EXAMPLES;CONFIGURATION")
(load "HTTP:EXAMPLES;EXPORTS")
(http:enable-http-service)
```

**Restore the matching source archive's example files and web assets before loading the complete supplied exports file.** It loads documentation, access-control, W3P and VRML example support beyond the reel's small example subset. A small local export file is a simpler first test. The Genera configuration selects port 80; host naming and TCP/IP must work. Arrange service enabling through an appropriate startup initialization when saving the configured world.

### Newer builds and scope

The loose source tree reaches **CL-HTTP 67.91, W3P 7.1 and Lambda-IR 21.0**. All core source module names and numbered patch files exist for the nine audited systems. Source revisions sometimes differ from released component maps: 25 of the server's 34 baseline source revisions are newer. Create a new local SCT version for a source rebuild instead of combining arbitrary newest files with every old patch.

For newer versions, client and proxy depend on HTTP-Client-Substrate; W4 also uses it. Load CL-HTTP before Lambda-IR's web-facing examples. Source availability makes repair realistic, but retain coherent 60 and 67 installations separately. The source archives' MCL-specific chat, HTML editor, home-page and graphics examples are additional porting material, not already established native XL applications.

Original 60.57 reel SHA256:

```text
bef531686429eddb84cc4ebc17108d226537abeb990068bc153c99415a48fa87
```

## 10. Experimental native binary recovery: Macsyma and NS

These donors are compiled `.VBIN` sets, not complete implementation source trees. Their saved I-machine function bodies make them valuable recovery candidates. The audit consumed every Macsyma/NS file to exact EOF and found 15,068 serialized I-machine functions, without the inspected native-host-code markers or VLM-only packed double-float opcode. The corresponding native and later I-function reader implementations match.

Actual runtime interfaces, object layouts, fixups, load-time forms and product activation remain separate questions. Run the experiments in a disposable native world and record the first actual incompatibility before designing a broad converter.

### Macsyma 421.45

- SCT system name: `Macsyma`.
- 166 core binaries and all 45 numbered patch binaries are present (211 VBINs total).
- Definition: `contributed/macsyma-421/defs/sysdcl.lisp.~382~`.
- Manifest: `contributed/macsyma-421/patch/macsyma-421/macsyma-421.component-dir.~4~`.
- Patch directory: `.../macsyma-421.patch-dir.~93~`.
- Site registration and translations are under `site/macsyma.system.~1~` and `site/macsyma.translations.~1~`.

**The extension/revision mapping is a real obstacle.** The manifest has both VLM and IMach maps. The supplied VLM files are version 1; the native map requests versions 4/5/7/8/9/10, and the definition selects `.ibin` under `#+imach`. Renaming `.vbin` files alone therefore does not even satisfy its native file selection.

Use a copied experimental definition/component map, or an explicit ordered load plan, that points to the preserved donor files. Do not falsify the original manifests. Resolve loader/runtime incompatibilities individually and use the native disassembler/debug metadata where necessary. The original definition has no declared dependency on Joshua, Concordia, CLIM or Statice. Test symbolic simplification, factoring, differentiation/integration and a save/reboot round trip after successful loading.

### NS hardware-design suite

NS here is the electrical-design suite, separate from the namespace service and NSAGE documentation system.

| Exact SCT system | Patch level | Core binaries | Dependency |
|---|---:|---:|---|
| Basic-NS |36.35|32|None declared|
| Schematic-NS |36.7|15|Basic-NS 36|
| VLSI-NS |36.29|23|Schematic-NS 36|
| PCB-NS |36.1|29|Schematic-NS 36|
| Gate-Array-NS |36.0|4|Schematic-NS 36|

All 103 released core binaries and 72 numbered patches are present. Released definitions are `contributed/ns/<system>/defsystem.lisp.~1~`; released component manifests are `<system>-36/<system>-36.component-dir.~3~`. Newer source definitions also exist, but the newer VLSI definition adds **`spice-delay-path`**, which is absent. Begin with the matching released version 1 definitions.

Unlike Macsyma, NS's VLM and IMach component maps use the same numeric file versions, all 1. The extension/platform/runtime selection still needs deliberate handling. Load Basic-NS, then Schematic-NS, then optional VLSI/PCB/Gate-Array systems. Preserve technology libraries/example data and verify create/edit/save/reopen before promising a complete design flow.

The original Open Genera distribution manual identifies both Macsyma and NS as requiring product keys; NS also has a `protection` module. Record an activation requirement separately from an instruction-set or loader problem.

## 11. Extraction and installation details that affect every package

### Native file identity

The recovered LMFS tree contains 6,758 active files and preserves original file versions. Its manifest maps every original pathname to a Unix-hosted filename, length and hash. Examples:

```text
Original LMFS: >sys>code>matcher.ibin.220
Recovered:    sys/code/matcher.ibin.~220~
Logical:      JOSHUA:CODE;MATCHER.IBIN.220
```

Retain numeric versions. SCT `.SYSTEM-DIR`, `.COMPONENT-DIR` and `.PATCH-DIR` files are operational inputs, not disposable index clutter. Preserve or register `SYS:SITE;` system stubs, but adapt site/namespace/translation files rather than replacing the core's configured site with the factory site's settings.

The recovered native IBIN files have **16-bit file bytes** in LMFS metadata; the supplied archive stores their octets faithfully. Use Genera's binary copy/import facilities and the inventory's file-byte-size information when reconstructing LMFS files. The concatenated tape images, by contrast, are 8-bit binary streams whose restorer recreates their contents and attributes.

### Text encoding and long names

Original LMFS text uses `0x8d` for newline, `0x89` for tab and `0x8c` for page break. Some Lisp/system files also carry Symbolics font escapes. Keep originals intact and use Genera's reader/import path. Separate normalized text copies are useful for modern tools; a universal UTF-8/ASCII cleanup would damage data or reader semantics.

Seventeen long filenames were recovered from each file's `NAME` property because the short catalogue field truncates at 30 characters. The supplied recovery already applies those corrections. If reproducing extraction, use its manifest/helper rather than the short directory field alone. CD ISO9660 spellings can also truncate names or substitute underscores; the distribution restorer is preferable to a simplistic recursive copy of the ISO's bare names.

### World extraction

The Macintosh FEP container needs 32-bit word reversal during extraction. The supplied recovered `.ILOD` and native file tree already have the correct standalone order; do not reverse them again. The independent base-world control was exactly equal to the CD's native 8.3 image:

```text
GENERA_8_3.ILOD: 56,834,560 bytes
SHA256 9bd7e04e681e2beb6975936ba550d577881705d034813e0a160f79d9c8bfde05
```

The recovery scripts are in `genera_native_recovery_audit.zip/factory_recovery/` and the convenience LMFS archive. Its README describes building hfsutils' `libhfs.so`, placing the original 9 GB image beside the scripts, running `lmfs_inventory.py --extract`, and extracting the world with `recover_fep_world.py --extract animation-mac-6-2`. These helpers are specifically validated against this source disk.

### Restore versus load versus save

For the CD, use the native restorer for `8_3_SOURCE_DIST_1.TAPE`, `8_3_SOURCE_DIST_2.TAPE`, `8_3_FPC_DIST.TAPE`, and `8_3_COLOR_DIST.TAPE` as appropriate. Restoring files and loading a system are separate steps. Let SCT's dependency/component declarations determine load order rather than loading every IBIN alphabetically.

Keep 8.1.1, 8.3 and later donor sources behind separate physical trees/translations. Numeric 'newest' across merged trees is not a compatibility policy. In particular, do not change the whole running OS's SYS mapping to the later `sys.sct` archive merely to expose one contributed application.

After installation, save **complete** deliverable worlds so they do not silently depend on a missing incremental ancestor:

```text
Save World Complete FEP0:>xl1200-apps-8-3.ilod
```

Keep the source/application filesystem, fonts, manuals, schemas, scene files and other external assets with the world. A complete memory image removes parent-world dependencies; it does not package the external filesystem.

## 12. Execution order and acceptance evidence

1. Establish the core's clean 8.3 boot, console, file I/O and paging; retain that baseline world.
2. Restore native sources/documentation/fonts and application files with their versions/byte sizes.
3. Configure SYS, JOSHUA, GRAPHICS, ILL and the HTTP-related translations as needed; register systems without importing obsolete site identity.
4. Load the native language tools, CLIM/backends/demos, Joshua, Concordia and CLOS Statice; check each before adding the next. Add optional networking/services only with their concrete configuration.
5. Bring up 8.3 Color drivers and simple display/image tools. Retain required microload/sync/data files.
6. Restore/test Illustrate and TeX, keeping old bundled runtimes isolated from the working 8.3 compiler runtime.
7. Restore native CL-HTTP 60.57, its matching assets and desired clients/crawler. Test a local page and request before trying the newer proxy/Lambda-IR package.
8. Separately boot/derive the 8.1.1 graphics world and test model, animate, render and paint operations. Then add Boids.
9. Attempt Macsyma and NS recovery in independent experimental worlds with the exact released manifests and patch sets.
10. Save complete successful worlds, reboot them, and rerun a small application operation. Reopen saved documents/databases/scenes to test persistent paths as well as memory state.

For each application record: input hash, selected native/system version, patches, logical translations, changed source/definition files, exact load error if any, startup result, one meaningful operation, save/reopen result, and final world name. Classify remaining failures as missing data, file metadata/translation, version/dependency mismatch, hardware interface, activation, or actual code incompatibility. This keeps a missing font or stale file version from becoming an unnecessary decompilation project.

## 13. Evidence and primary references

**Collection audits:** `genera_native_recovery_audit.zip/README.md`, `factory_recovery/README.md`, `layered_manifest_audit.json`, `concordia_dependency_audit.json`, `clim_dna_audit.json`, `animation_world_audit.json`, `world_inspection_notes.md`, `lmfs_inventory.json`, `lmfs_extraction_manifest.json`, `long_name_recovery.json`, `source_closure_audit.json`, and `macsyma_ns_binary_audit.json`.

**Original instructions/source inspected for this handoff:** Illustrate and TeX `RESTORING`/`README`; original `ILL:CODE;ILLUSTRATE.LISP.40`; `SYS:TEX;INITEX-SYS.LISP.17`, `VIRTEX-SYS.LISP.17`, `TEX-SCT.LISP`; native Color-Distribution 21 component manifest; native site registrations; native Hacks/CLIM/Jericho demo declarations; pinned Macsyma/NS definitions and patch/component maps; original Boids source; original CL-HTTP reels, ten native 60.57 component maps, configuration/exports and source archive.

- [Genera 8.3 XL installation guide](https://www.chai.uni-hamburg.de/~moeller/symbolics-info/documentation/Genera-8.3-Software-Installation-Guide-for-XL-Family-Machines.pdf)
- [Genera 8.3 release notes](https://www.chai.uni-hamburg.de/~moeller/symbolics-info/documentation/Genera-8.3-Release-Notes.pdf)
- [Site Operations](https://www.chai.uni-hamburg.de/~moeller/symbolics-info/documentation/Site-Operations.pdf)
- [Program Development Utilities](https://www.chai.uni-hamburg.de/~moeller/symbolics-info/documentation/Program-Development-Utilities.pdf)
- [CLIM 2.0 installation guide](https://www.chai.uni-hamburg.de/~moeller/symbolics-info/documentation/CLIM-2.0-Release-Notes-and-Installation-Guide.pdf)
- [Concordia manual](https://www.chai.uni-hamburg.de/~moeller/symbolics-info/documentation/Symbolics-Concordia.pdf)
- [Concordia Ivory release/install notes](https://www.chai.uni-hamburg.de/~moeller/symbolics-info/documentation/Concordia-7.3-Ivory-Release-Notes.pdf)
- [Symbolics C user guide](https://www.chai.uni-hamburg.de/~moeller/symbolics-info/documentation/Users-Guide-to-Symbolics-C.pdf)
- [Symbolics X Window System guide](https://www.chai.uni-hamburg.de/~moeller/symbolics-info/documentation/Symbolics-X-Window-System-Users-Guide.pdf)
- [Open Genera installation guide: contributed applications and keys](https://www.chai.uni-hamburg.de/~moeller/symbolics-info/documentation/Open-Genera-Installation-Guide.pdf)
- [Open Genera release notes: CL-HTTP/client/proxy/W4/Lambda-IR distribution](https://www.bitsavers.org/pdf/symbolics/software/genera_8/Open_Genera_Beta_II_Release_Notes.pdf)
- [Original physical-disk provenance](https://www.loper-os.org/?p=2943)
- [Original Illustrate archive](https://archive.org/download/Illustrate.tar/Illustrate.tar.gz)
- [Original TeX archive](https://archive.org/download/tex.tar/TeX.tar.gz)
- [Pinned sys.sct donor](https://github.com/krfantasy/sys.sct/tree/e97efaabf6aef64e6e63a457e1be7651256628d9)
- [Original CL-HTTP reels and source distributions](https://github.com/krfantasy/sys.sct/tree/e97efaabf6aef64e6e63a457e1be7651256628d9/contributed/cl-http/distributions)
- [Franz CLIM source](https://github.com/franzinc/clim2)
- [Original Boids source](https://www.red3d.com/cwr/code/boids.lisp)
- [Original Boids background](https://www.red3d.com/cwr/boids/)

