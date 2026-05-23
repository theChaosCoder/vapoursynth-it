# Zig-Port von VapourSynth-IT (Namespace `zit`)

> Inverse-Telecine-Plugin (Pulldown-Removal) für VapourSynth, ursprünglich
> Avisynth-Plugin `IT.dll` (thejam79 2002, minamina 2003), 2014 nach
> VapourSynth portiert von msg7086. Diese Arbeit portiert die C++-Variante
> nach **Zig**, mit lauffähigen Binaries für **Linux, macOS, Windows
> (64-Bit)** und reproduzierbaren Tests.

- Upstream-Referenz: <https://github.com/HomeOfVapourSynthEvolution/VapourSynth-IT>
  (Commit `6fc9be8`, lokal entpackt unter `/tmp/vs-it-ref/`).
- Original Avisynth-Quelle: `Avisynth_IT_YV12/src/` (lokal vorhanden).
- Ziel-Repository: <https://github.com/theChaosCoder/vapoursynth-it>
  (existiert bereits, privat, default-Branch leer).
- Lizenz: GPL-2.0-or-later (vom Original übernommen).
- Build-Toolchain: Zig 0.16.0 (lokal installiert).

---

## 1. Scope & Designentscheidungen

| Punkt | Entscheidung | Begründung |
| --- | --- | --- |
| **Sprache** | Zig 0.16.0 | Native Cross-Compile (Linux/macOS/Windows), gute C-ABI, Tests integriert. |
| **VapourSynth API** | **API 4** (R55+) | Aktueller Standard. C++-Upstream nutzt noch API 3 — wir migrieren. |
| **Plugin-Namespace** | `zit` | Vom User vorgegeben (Aufruf: `core.zit.IT(clip, ...)`). |
| **Funktionsname** | `IT` | Identisch zum Upstream, transparenter Drop-In. |
| **Eingangsformat** | YUV420P8 (wie Upstream) | 1:1-Verhalten; bit-genaue Verifikation gegen C++-Referenz. |
| **Parameter** | `fps`, `threshold`, `pthreshold` (gleiche Defaults: 24 / 20 / 75) | Wie Upstream. `ref`, `blend`, `diMode` bleiben weggelassen (Upstream-Stand). |
| **Algorithm-Basis** | Reiner C-Pfad (`__C` in `vs_it_c.cpp`) | Plattform-unabhängig, kein Inline-Asm/Intrinsics nötig. SIMD später optional via Zig `@Vector`. |
| **Bit-Identität** | Ziel: bit-genau zur Upstream-C-Variante | Pixel-Daten md5-Vergleich gegen `--c`-Build der C++-Version. |
| **Threading** | Anfangs `fmSerial` (oder API-4-Äquivalent) | Upstream nutzt `fmParallel` mit gemeinsamem Frame-State → Race-Condition. Serial = korrekt; Parallel mit Locking ggf. später. |
| **Build** | `zig build` als single source of truth | Erzeugt `.so`, `.dylib`, `.dll` für x86_64. ARM64 als Bonus möglich. |
| **Tests** | Zig-Unit-Tests + Python/VapourSynth-Integrationstests gegen Golden-Frames | Algorithmus-Primitive isoliert; End-to-End gegen Referenzklipp. |
| **CI** | GitHub Actions Matrix (Linux/macOS/Windows), erst manuell aktiviert | User-Wunsch: „CI später aktivieren". Workflow-Datei mit `workflow_dispatch` only. |

### Bewusst nicht portiert (Upstream-Stand übernommen)

- `blend`, `ref`, `diMode` Parameter (Upstream entfernt; nur diMode 3 bleibt fix codiert).
- YUY2-Pfad (im Upstream nicht portiert).
- MMX-/SSE-Code (`vs_it_mmx.cpp`, `vs_it_sse.cpp`). Nur C-Pfad ist Referenz.

### Bekannte Bugs im Upstream (zu fixen)

1. `fmParallel` + gemeinsamer `m_frameInfo[]` → Race. **Fix:** Serial.
2. `freeNode` ist im `itFree` auskommentiert wegen Deadlock. **Fix:** Korrekte Reihenfolge in API-4-Lifecycle (freeNode beim `frameFree`/Destroy in der richtigen Phase).
3. Manuelle `_aligned_malloc`/`free` pro Frame. **Fix:** Re-use per-Filterinstanz oder per Frame Context allokieren, mit Zig-Allocator.

---

## 2. Analyse: Was ist vorhanden, was fehlt

### Vorhanden

- Original Avisynth IT_YV12 0.1.03 Quellen (`Avisynth_IT_YV12/src/`).
- VapourSynth-IT Quellen (upstream Tarball, lokal entpackt; 2479 LoC C/C++).
- Zig 0.16.0 Toolchain.
- `gh` CLI authentifiziert als `theChaosCoder` (mit `repo`, `workflow` Scopes).
- Zielrepo existiert (privat, leer).

### Zu beschaffen / generieren

- **VapourSynth-Header** (`VapourSynth4.h`, `VSHelper4.h`, `VSScript4.h`):
  vom offiziellen [vapoursynth/vapoursynth](https://github.com/vapoursynth/vapoursynth)
  Repo. Werden unter `vendor/vapoursynth/` eingecheckt (BSD-Lizenz-kompatibel).
- **Referenz-Build der C++-Version** für Golden-Frames: einmalig mit `--c`
  bauen, generierte md5-Listen einchecken.
- **Testklipps**: synthetisch erzeugt (über `core.std.BlankClip` +
  Telecine-Pattern), keine externen Assets. So bleibt das Repo klein und
  reproduzierbar.
- **CI-Workflow** (.github/workflows/ci.yml) — initial nur `workflow_dispatch`,
  später Trigger ergänzen.

### Algorithmische Oberfläche (zu portierende Funktionen)

Aus `vs_it_c.cpp` / `vs_it_process.cpp` / `vs_it.cpp`:

| Funktion | Aufgabe | LoC |
| --- | --- | --- |
| `IT::IT` (Konstruktor) | State-Arrays, AdjPara, fps-Anpassung | ~30 |
| `GetFramePre`, `GetFrame`, `GetFrameSub`, `MakeOutput` | VS-Lifecycle | ~120 |
| `EvalIV_YV12` | Interlace-Voting pro Frame | ~70 |
| `MakeDEmap_YV12` | Differenz-Edge-Map | ~30 |
| `MakeMotionMap_YV12` | Motion-Detection prev↔curr | ~60 |
| `MakeMotionMap2Max_YV12` | Motion prev/next/max | ~50 |
| `MakeSimpleBlurMap_YV12` | Blur-Map für Deint | ~40 |
| `ChooseBest`, `CompCP` | Match-Auswahl C/P/N | ~110 |
| `Decide`, `SetFT` | 5er-Block-Decimation (24fps Pulldown) | ~180 |
| `CopyCPNField`, `DeintOneField_YV12` | Frame-Output | ~170 |
| `DrawPrevFrame`, `CheckSceneChange` | Szenenwechsel-Handling | ~60 |
| **Σ Kernlogik** | | **~920 LoC** C++ → ca. 800–900 LoC Zig erwartet |

Plus ca. 100 LoC API-Glue (Plugin-Init, Filter-Create, Property-Getter).

---

## 3. Projekt-Layout (geplant)

```
.
├── build.zig                # Cross-Compile-Targets, Test-Steps
├── build.zig.zon            # Dependencies (keine externen erwartet)
├── src/
│   ├── plugin.zig           # VS-Plugin-Init, Filter-Registration
│   ├── filter.zig           # IT-Instance + GetFrame-Lifecycle
│   ├── algo/
│   │   ├── eval_iv.zig      # EvalIV_YV12
│   │   ├── motion.zig       # MakeMotionMap / MakeMotionMap2Max / MakeSimpleBlurMap
│   │   ├── edge.zig         # MakeDEmap_YV12
│   │   ├── decide.zig       # ChooseBest / Decide / CompCP / SetFT
│   │   ├── output.zig       # CopyCPNField / DeintOneField / DrawPrevFrame
│   │   └── scene.zig        # CheckSceneChange
│   ├── frame_state.zig      # CFrameInfo / CTFblockInfo Zig-Pendants
│   └── vs.zig               # @cImport(VapourSynth4.h) + dünne Wrapper
├── tests/
│   ├── unit/                # In-Source-Tests via `zig build test`
│   └── integration/
│       ├── conftest.py
│       ├── test_golden.py   # Verarbeitet Referenzklipp, vergleicht md5
│       └── fixtures/
│           └── golden_hashes.txt
├── vendor/
│   └── vapoursynth/         # VapourSynth4.h, VSHelper4.h (BSD)
├── scripts/
│   ├── make_reference.sh    # baut C++-Upstream mit --c und erzeugt Golden-Hashes
│   └── gen_testclip.py      # synthetischer Telecine-Klipp
├── .github/workflows/
│   └── ci.yml               # workflow_dispatch only initial
├── README.md
├── LICENSE                  # GPL-2.0 (vom Upstream)
└── PLAN.md                  # dieses Dokument
```

---

## 4. Phased TODO

> Reihenfolge ist absichtlich: erst Infrastruktur, dann „dümmster" End-to-End-
> Durchstich (Identity-Filter), dann Algorithmus stückweise, mit
> Golden-Frame-Verifikation als Schutznetz.

### Phase 0 — Bootstrap & Repo

- [ ] Lokales Git-Repo in `` initialisieren
- [ ] `LICENSE` aus Upstream übernehmen (GPL-2.0)
- [ ] `README.md` mit Status-Hinweis „Work in progress, Zig port" anlegen
- [ ] `.gitignore` (zig-out/, zig-cache/, .zig-cache/, build/, *.so, *.dll, *.dylib, __pycache__)
- [ ] `PLAN.md` (diese Datei) einchecken
- [ ] VapourSynth-Header (`VapourSynth4.h`, `VSHelper4.h`) nach `vendor/vapoursynth/` legen
- [ ] Avisynth-Original-Quellen `Avisynth_IT_YV12/` nach `reference/avisynth/` verschieben (als Read-only-Doku)
- [ ] Upstream-Referenz-Quellen nach `reference/vapoursynth-cpp/` (für Side-by-Side-Vergleiche während des Ports)
- [ ] `git remote add origin https://github.com/theChaosCoder/vapoursynth-it.git`
- [ ] Initial-Commit, Push auf neuen Branch `main`

### Phase 1 — Build-System & Skeleton

- [ ] `build.zig`: shared-library Target `zit` (Linux .so, macOS .dylib, Windows .dll), Linux/macOS PIC
- [ ] `build.zig`: cross-compile Steps für `x86_64-windows-gnu`, `x86_64-macos`, `x86_64-linux-gnu` (alle aus Linux-Host)
- [ ] `build.zig`: `test`-Step für Zig-Unit-Tests
- [ ] `src/vs.zig`: `@cImport` der VapourSynth-Header, Wrapper-Typen
- [ ] `src/plugin.zig`: `VapourSynthPluginInit2` Export, registriert `IT` im Namespace `zit` mit Argsig `clip:vnode;fps:int:opt;threshold:int:opt;pthreshold:int:opt;`
- [ ] `src/filter.zig`: Identity-Filter (Input → Output 1:1) — Smoke-Test
- [ ] Verifizieren: `vspipe -i -` lädt das Plugin auf Linux, `core.zit.IT(clip)` läuft ohne Crash und liefert unveränderte Frames
- [ ] Verifizieren: gleicher Smoke-Test gegen Windows-DLL via Wine oder unter Windows-VM (manuell, vor CI-Aktivierung)

### Phase 2 — Algorithmus-Port (mit Tests pro Schritt)

> Jede Funktion bekommt: Zig-Implementierung + Zig-Unit-Test gegen
> hand-konstruiertes Mini-Pixel-Array + End-to-End-md5-Match.

- [ ] `frame_state.zig`: `CFrameInfo`, `CTFblockInfo`, Allokation/Init wie Upstream
- [ ] `algo/edge.zig`: `makeDeMap` + Unit-Test (4×4 Block, bekannte Ausgabe)
- [ ] `algo/motion.zig`: `makeMotionMap`, `makeMotionMap2Max`, `makeSimpleBlurMap` + Tests
- [ ] `algo/eval_iv.zig`: `evalIv` + Test
- [ ] `algo/decide.zig`: `chooseBest`, `compCp`, `decide`, `setFt` + Tests (zustands-basiert, Block-Level)
- [ ] `algo/scene.zig`: `checkSceneChange` + Test
- [ ] `algo/output.zig`: `copyCPNField`, `deintOneField`, `drawPrevFrame` + Tests
- [ ] `filter.zig`: vollständiges `getFrame`-Lifecycle, inkl. `requestFrameFilter` für die 5er-Blöcke bei fps=24
- [ ] Sauberes Frame-State-Reset zwischen Aufrufen (kein Cross-Frame-Leak)
- [ ] Korrekte Behandlung der Edge-Cases am Clip-Anfang/-Ende (`clipFrame`)

### Phase 3 — Verifikation (Golden-Frame-Tests)

- [x] `scripts/gen_testclip.py`: 5 synthetische Fixtures (flat color, mod-16 width, telecine, interlaced stripes)
- [x] `reference/vapoursynth-cpp-api4/`: mechanischer API3→API4-Port des Upstream-Plugins (algorithmus unverändert). `scripts/build_upstream_api4.sh` baut `libit.so`.
- [x] `scripts/regen_golden.py`: erzeugt Golden-MD5s aus dem Zig-Build → `tests/integration/fixtures/golden_hashes.txt`
- [x] `scripts/compare_upstream.py`: direkter Vergleich Zig ↔ Upstream-API4-Port
- [x] `tests/integration/test_filter.py`: 25 Tests — Property/Invariant + Golden-Hash + Error-Paths
- [x] `tests/integration/test_upstream_compare.py`: 10 Tests — bit-exakt Zig ↔ Upstream über das gesamte Param-Grid (198 Frames, 0 mismatched)
- [x] Tests für `fps=24` und `fps=30`
- [x] Tests für verschiedene Auflösungen (128×96, 176×96, 720×480)
- [x] Tests für threshold / pthreshold Variation
- [ ] Tests an Clip-Grenzen (erstes/letztes 5er-Block) — implizit über Fixtures abgedeckt, könnte expliziter werden
- [ ] `--c` vs `--sse` Build-Vergleich des Upstream — übersprungen, da wir nur den `--c`-Pfad als Ground Truth nutzen

### Phase 4 — Cross-Compile & Distribution

- [ ] `zig build -Dtarget=x86_64-linux-gnu` → `libzit.so` produziert
- [ ] `zig build -Dtarget=x86_64-macos` → `libzit.dylib` produziert (mit `-undefined dynamic_lookup`-Äquivalent)
- [ ] `zig build -Dtarget=x86_64-windows-gnu` → `zit.dll` produziert
- [ ] Optional: `aarch64-macos`, `aarch64-linux-gnu` Targets
- [ ] Smoke-Test der Linux-`.so` lokal
- [ ] Smoke-Test der Windows-`.dll` (Wine oder Windows-Host)
- [ ] Smoke-Test der macOS-`.dylib` (auf macOS-Host, ggf. später)
- [ ] Release-Skript: `zig build release` packt alle drei in `dist/zit-<version>-<os>.zip`

### Phase 5 — CI (inaktiv, vorbereitet)

- [ ] `.github/workflows/ci.yml` mit Jobs:
  - `lint`: `zig fmt --check`
  - `unit`: `zig build test` auf Ubuntu
  - `cross-build`: Matrix Linux/macOS/Windows, alle aus Linux-Runner via Zig
  - `integration`: Ubuntu + VapourSynth aus apt, lädt Zig-Plugin, läuft pytest
- [ ] Trigger initial nur `workflow_dispatch:` (so dass kein PR/Push CI startet)
- [ ] Notiz in README: „CI activation pending"
- [ ] Wenn alles grün: später `pull_request` und `push: [main]` Trigger ergänzen (separater Commit, vom User explizit anzustoßen)

### Phase 6 — Doku & Release

- [ ] README mit Build-Anleitung, Beispiel, Unterschieden zum C++-Upstream
- [ ] CHANGELOG mit „v0.1.0 — initial Zig port"
- [ ] Klarstellung im README: gleiche GPL-2.0 Lizenz, gleicher Kredit an thejam79/minamina/msg7086
- [ ] Repo public-fähig prüfen (keine geheimen Pfade, keine Tokens)
- [ ] Tag `v0.1.0`, GitHub Release mit drei Binaries

---

## 5. Offene Punkte (Default-Annahmen, vom User bei Bedarf zu korrigieren)

| Frage | Default-Annahme |
| --- | --- |
| Repository öffentlich machen? | Bleibt vorerst privat, später `gh repo edit --visibility public` |
| Avisynth-Original mit ins Repo? | Ja, unter `reference/avisynth/` (read-only Doku) |
| Bit-exact zur Upstream-C-Variante als hartes Ziel? | Ja. Falls Upstream-Bugs Bit-Identität verhindern: dokumentieren, Test als "differs intentionally" markieren. |
| Threading parallelisieren? | Erstmal `fmSerial` (korrekt). Parallel optional in späterer Version. |
| Zig-Version langfristig pinnen? | Ja, `0.16.0` über `minimum_zig_version` in `build.zig.zon`. |
| ARM64-Targets im ersten Release? | Nice-to-have, kein Blocker. |

---

## 6. Risiken

- **Bit-Identität evtl. nicht erreichbar**: Falls Upstream `--sse` und `--c`
  bereits abweichen, ist „bit-genau" nur gegen einen Pfad sinnvoll.
  Mitigation: gegen `--c` testen, in Doku festhalten.
- **VapourSynth-API-4-Migration**: Funktionsnamen geändert (`vsapi->` →
  meist gleiche Semantik, andere Signatur). Mitigation: dünne `vs.zig`-
  Wrapperschicht absorbiert API-Unterschiede.
- **Windows-Build ohne Windows-Host testen**: Zig cross-compiled, aber das
  fertige `.dll` muss in VapourSynth-Windows laden. Mitigation: Wine
  lokal, später CI auf `windows-latest`.
- **macOS-Codesigning**: dylib für non-developer-tools muss ggf. signiert
  werden. Mitigation: nur als Hinweis im README, kein Blocker.
- **Performance**: reiner C-Pfad ist ~30 % langsamer als SSE2 (laut
  Upstream-Changelog). Mitigation: später `@Vector(16, u8)` einbauen.

---

## 7. Definition of Done für „v0.1.0"

1. `zig build test` grün.
2. Drei Binaries (`.so`, `.dylib`, `.dll`) lokal erzeugt.
3. Integrationstest: ≥3 Test-Clips, je `fps=24` und `fps=30`, alle Frames
   md5-identisch zur Upstream-C-Referenz.
4. README dokumentiert Build, Aufruf (`core.zit.IT(...)`), Limitierungen.
5. Repo `theChaosCoder/vapoursynth-it` enthält Quellcode, Plan, CI-Skeleton
   (inaktiv), Release v0.1.0 mit drei Binaries.
