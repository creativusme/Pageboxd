# Pageboxd

Il diario delle tue edizioni fisiche: un "Letterboxd per libri" nativo per iOS 17+, 100% offline.

## Compilare da Windows (senza Mac)

Le app iOS si compilano solo con Xcode su macOS. Il repository include una pipeline
**GitHub Actions** che compila l'app su un Mac nel cloud di GitHub, gratis.

1. Crea un account su <https://github.com> e un nuovo repository (es. `pageboxd`).
   Con un repository **pubblico** i minuti macOS sono illimitati; con uno privato hai
   una quota mensile gratuita più ridotta.
2. Da questa cartella, in PowerShell:
   ```
   git init
   git add .
   git commit -m "Pageboxd"
   git branch -M main
   git remote add origin https://github.com/<tuo-utente>/pageboxd.git
   git push -u origin main
   ```
3. Su GitHub apri **Actions › Build Pageboxd**: la build parte a ogni push (circa 10 minuti).
4. A build finita, in fondo alla pagina del run trovi gli **Artifacts**:
   - `Pageboxd-ipa` → contiene `Pageboxd.ipa` da installare sull'iPhone
   - `Pageboxd-simulator` → contiene `Pageboxd-simulator.zip` da caricare su appetize.io
   - `build-logs` (solo se la build fallisce) → contiene l'errore del compilatore

### appetize.io

Carica **`Pageboxd-simulator.zip`** così com'è (dentro c'è `Pageboxd.app` compilata per
simulatore). L'errore *"no app folder found"* compare se carichi il codice sorgente o
un `.ipa` per iPhone: appetize accetta solo una `.app` per simulatore zippata.
Sul simulatore la fotocamera non esiste: usa "Inserisci ISBN manualmente" o la ricerca.

### Sideload sull'iPhone (Sideloadly / AltStore)

Installa `Pageboxd.ipa` con il tuo Apple ID gratuito. La firma dura 7 giorni.

## Non perdere mai i dati

| Situazione | Dati |
|---|---|
| Refresh/reinstallazione **sopra** l'app esistente, stesso Apple ID | ✅ restano |
| Firma scaduta (l'app non si apre) → reinstalli sopra | ✅ restano |
| App **cancellata** dall'iPhone, o Apple ID diverso (bundle ID diverso) | ❌ sandbox persa → ripristina dal backup |

Per questo l'app ha il **backup automatico** in una cartella esterna:

1. **Impostazioni › Backup automatico › Scegli cartella di backup** → scegli una cartella
   in **iCloud Drive** (es. crea `iCloud Drive/Pageboxd`).
2. Da quel momento, a ogni modifica e quando chiudi l'app, Pageboxd copia `library.json` e le
   foto in `Pageboxd Backup/`. La versione precedente resta in `library.previous.json`.
3. Dopo una reinstallazione "pulita": **Libreria › Ripristina da backup** (o Impostazioni) →
   scegli la stessa cartella → **Ripristina**. Libri, letture, recensioni e foto tornano tutti.

Inoltre una copia di `library.json` più la cartella `covers/` è sempre visibile in
**File › Sul mio iPhone › Pageboxd**. Questa copia però viene cancellata insieme all'app,
quindi la cartella iCloud Drive resta la protezione vera.

Consigli per il sideload:
- Non cancellare l'app prima di reinstallarla: installa sempre **sopra** quella esistente.
- Usa sempre lo stesso Apple ID in Sideloadly/AltStore e non attivare opzioni che
  cambiano il bundle ID (`com.pageboxd.journal`).

## Struttura

```
project.yml                        Specifica XcodeGen (il .xcodeproj viene generato in CI)
.github/workflows/build.yml        Build .ipa + zip per simulatore
Pageboxd/
├── PageboxdApp.swift              App, TabView, backup automatico, errore database
├── PrivacyInfo.xcprivacy          Privacy manifest
├── Models/                        BookItem, ReadingLog, enum
├── Services/
│   ├── Metadata/
│   │   ├── BookMetadata.swift         Modello, ISBN (10/13), riconoscimento lingua
│   │   ├── CatalogSources.swift       SBN, Open Library, Apple Books, Google Books
│   │   └── BookMetadataFetcher.swift  Ricerca parallela, unione e ordinamento risultati
│   ├── AuthorService.swift        Autori: Wikipedia (it/en) + Open Library
│   ├── BackupManager.swift        Backup/ripristino in cartella esterna (iCloud Drive)
│   ├── ImageStorageManager.swift  Resize 1080px, JPEG 0.75, Documents/covers
│   ├── BarcodeScannerView.swift   Scanner con tutte le lenti
│   ├── CSVExporter.swift          Export CSV
│   └── Haptics.swift
├── Utilities/Extensions.swift
└── Views/                         Library, Watchlist, AddBook, Authors, Stats, Settings, Components
```

## Cataloghi

| Fonte | Punti di forza |
|---|---|
| **SBN – Biblioteche italiane** | Praticamente tutti i libri pubblicati in Italia, anche i più vecchi (ISBN-10) |
| **Open Library** | Catalogo internazionale, edizioni nella lingua cercata, autori |
| **Apple Books** | Copertine e trame, titoli italiani |
| **Google Books** | Facoltativo: senza chiave Google lo blocca spesso. Chiave gratuita in Impostazioni › Cataloghi online |
| **Wikipedia** | Biografia e foto degli autori (in italiano, poi in inglese) |

La lingua della ricerca viene riconosciuta sul dispositivo: "vita di pi" cerca l'edizione italiana,
"life of pi" quella inglese.
