# Analiză și recomandări pentru refactor-ul aplicației e-CAD

> Sinteza conversației privind structura bazei de date, modelul de business și strategia de refactor pentru aplicația e-CAD.
> Data: mai 2026
> 
---

## Cuprins

1. [Context](#1-context)
2. [Arhitectura aplicației — descoperită incremental](#2-arhitectura-aplicației--descoperită-incremental)
3. [Modelul de date — analiză entități](#3-modelul-de-date--analiză-entități)
4. [Probleme identificate](#4-probleme-identificate)
5. [Modelul țintă propus](#5-modelul-țintă-propus)
6. [Strategia de refactor recomandată](#6-strategia-de-refactor-recomandată)
7. [Întrebări deschise](#7-întrebări-deschise)
8. [Materiale de cerut partenerului de dezvoltare](#8-materiale-de-cerut-partenerului-de-dezvoltare)

---

## 1. Context

### Despre aplicația e-CAD

Aplicație web de gestionare cadastrală dezvoltată pe Ruby on Rails, în două etape istorice:

- **Etapa 1 (2011–2015):** planuri parcelare + inventarierea terenurilor conform Legii 165/2013
- **Etapa 2 (după ~2015–2016):** integrare cu schema CGXML standardizată ANCPI pentru cadastru general

### Caracteristici operaționale (descoperite pe parcurs)

- **Single-instance, multi-tenant** prin `comuna_id` (toate primăriile într-o singură bază)
- **Multi-rol** cu sistem de permisiuni: primării + specialiști cadastru, cu flux colaborativ
- **Producție națională** — utilizată în mai multe zone din România
- **Release simultan** pentru toți utilizatorii (nu există feature flags per primărie)
- **Compatibilitate cgxml** obligatorie (export către ANCPI = cerință legală)

### Fluxul operațional (cele patru faze)

```
1. Inițializare         → configurare comună, sectoare cadastrale
2. Operațiuni ACTE      → import OCPI, creare TP-uri, plan parcelar, audit juridic
                          (zona primăriei)
3. Operațiuni IMOBILE   → proiect cadastru, măsurători, editare imobil, anexare scanate
                          (zona specialistului cadastru)
4. Livrabile            → export cgxml, PDF, registru cadastral
```

Două variante de flux: **Standard** (cu import OCPI integral, distribuție automată scanate) și **Express** (introducere manuală, -30% timp).

---

## 2. Arhitectura aplicației — descoperită incremental

### Două straturi de date paralele

| Caracteristică | Stratul RO (etapa 1) | Stratul CGXML (etapa 2) |
|---|---|---|
| Limbă/nomenclator | Română | Engleză (prefix `f_cg_*`) |
| Sursa | Modelată intern | Schema XML ANCPI (fixă) |
| Granularitate | Document juridic + parcele administrative | Imobil cadastral cu geometrie |
| Tabele principale | `act`, `parcela`, `proprietar` | `f_cg_land`, `f_cg_parcel`, `f_cg_building`, `f_cg_iu`, `f_cg_person`, `f_cg_deed`, `f_cg_registration` |

**Cele două straturi nu sunt redundante** — ele reprezintă **stadii temporale** ale aceluiași imobil:

- după faza ACTE → există ca `parcela` cu proprietari și acte (etapa RO)
- după faza Plan cadastral → există și ca `f_cg_land` cu geometrie (etapa cgxml)

**Punte de legătură:** `cg_proiect_item` — marchează preluarea parcelelor din etapa 1 în proiectul de cadastru general.

### Modelul TP-centric (etapa 1)

Unitatea atomică e **Titlul de Proprietate (TP)**, nu parcela:

```
1 TP ──< N proprietari (în indiviziune, cu cote)
   └──< N parcele (în diferite tarlale, cu folosințe diferite)
```

**Tarlaua** este un grup spațial transversal — apare în zeci de TP-uri, fiecare TP având 1-2 parcele în ea. **Planul parcelar** colectează toate parcelele dintr-o tarla, indiferent de TP-ul de proveniență, pentru stabilirea ordinii spațiale corecte.

### Modelul anexelor (acte succesorale)

Actele anexă (Certificat de Moștenitor — CM, Act de Partaj — AP) sunt **documente separate atașate la TP**, nu modificări ale TP-ului. TP-ul rămâne intact (e document juridic imutabil).

**Tabela `anexa_act`** cu `tip_anexa`:

- **CM (Certificat de Moștenitor):**
  - un singur proprietar decedat (`proprietar_id`)
  - moștenitori multipli cu cote (în `anexa_act_successors`)
  - `property_quota` = cota care se moștenește din decedat
  - cotele sunt **relative la decedat**, nu la TP

- **AP (Act de Partaj):**
  - moștenitori deja stabiliți
  - **alocare per-parcelă**: fie unei persoane, fie rămâne `Indiv.`
  - rupe indiviziunea pe parcele specifice

### Lanțul succesoral (cascadă de CM-uri)

Un TP poate avea **multiple anexe în arbore**, nu doar 1-2:

```
TP (1991)
├── CM₁ (1995, decedat=Ion) ── parent_anexa_id = NULL
│   └── CM₃ (2010, decedat=A, moștenitor din CM₁) ── parent_anexa_id = CM₁.id
│       └── CM₅ (2018, decedat=A₁, moștenitor din CM₃) ── parent_anexa_id = CM₃.id
├── CM₂ (2003, decedat=Maria) ── parent_anexa_id = NULL
└── AP (2015, partaj) ── parent_anexa_id = NULL
```

**`parent_anexa_id`** ca self-FK (NULL pentru anexe direct pe TP).

**Calculul cotelor curente** = parcurgere recursivă a arborelui, multiplicând cotele:
```
A₁₁ în 2018:  1/3 (Ion din TP) × 1/3 (A din CM₁) × 1/2 (A₁ din CM₃) × 1/1 (A₁₁ din CM₅) = 1/18
```

### „Operare" — proiecție pe starea curentă

Anexele au flag de operare. **„Operat" = efectele propagate în tabela `proprietar`**:

- `anexa_act` + `anexa_act_successor` = **istoricul documentar**
- `proprietar` = **starea curentă** (cine deține ce, după toate anexele operate)

Pattern de tip „event sourcing cu snapshot": evenimentele (anexele) se păstrează separat, starea curentă (`proprietar`) se materializează din ele.

### Tabela `proprietar` — cu două populații

```
proprietar
  ├─ act_id (TP-ul)
  ├─ tip: PF | PJ | SR | UAT
  ├─ nume, initiala_tata, prenume, cnp
  ├─ tip_act_ident (BI/CI/CD/PASS), serie, nr, file
  ├─ telefon, email, nationalitate
  ├─ initial          ─→ TRUE: proprietar originar din TP
  │                     FALSE: moștenitor propagat din CM operat
  ├─ decedat          ─→ flag manual (nu derivat din CM)
  ├─ adresa_attributes (nested has_one)
  └─ + ordine, cota, FK către anexa generatoare (de verificat)
```

**Tipuri speciale:**
- **PF** — Persoană Fizică (CNP)
- **PJ** — Persoană Juridică (CUI)
- **SR** — Statul Român
- **UAT** — Unitate Administrativ-Teritorială (drumuri, ape, păduri, islaz)

---

## 3. Modelul de date — analiză entități

### Entitățile descoperite

#### Stratul RO (etapa 1)

| Entitate | Rol |
|---|---|
| `comuna` | UAT (rădăcina ierarhiei) |
| `sat` | Localitate componentă |
| `sector_cadastral` | Subdiviziune teritorială |
| `tarla` | Grup spațial de parcele (cu interval de numere) |
| `act` | Titlul de Proprietate (TP) — document originar |
| `parcela` | Parcelă administrativă atașată la TP |
| `proprietar` | Ocurență persoană pe TP |
| `proiect_parcelar` | Plan parcelar pe tarla |
| `proiect_item` | Linie din plan parcelar (parcela + ordine) |
| `anexa_act` | Act anexă (CM/AP) atașat la TP |
| `anexa_act_successor` | Moștenitor pe anexă |

#### Stratul CGXML (etapa 2)

| Entitate | Rol |
|---|---|
| `f_cg_land` | Imobil cadastral cu geometrie |
| `f_cg_parcel` | Parcelă cgxml (subdiviziune imobil) |
| `f_cg_building` | Construcție |
| `f_cg_iu` | Unitate Individuală (apartament) |
| `f_cg_building_common_part` | Părți comune clădire |
| `f_cg_address` | Adresă structurată |
| `f_cg_person` | Persoană (proprietar cgxml) |
| `f_cg_deed` | Act juridic (carte funciară) |
| `f_cg_registration` | Înscriere CF |
| `f_cg_document` | Document scanat |
| `f_cg_contested` | Contestație |
| `cg_proiect` | Proiect de cadastru |
| `cg_proiect_item` | Asociere parcela ↔ imobil |
| `cgxml` | Fișier cgxml încărcat (atașament) |

#### Maparea proprietar (RO) ↔ f_cg_person (CGXML)

| Concept | `proprietar` | `f_cg_person` |
|---|---|---|
| Nume | `nume` | `last_name` |
| Prenume | `prenume` | `first_name` |
| Inițiala tată | `initiala_tata` | `father_initial` |
| Nume anterior | — | `previous_last_name` |
| CNP/CUI | `cnp` | `id_code` |
| Tip subiect | `tip` (PF/PJ/SR/UAT) | `is_physical` + `is_legal` |
| Decedat | `decedat` | `is_deceased` |
| Document identitate | `tip_act_ident`, `serie_act_ident`, `nr_act_ident` | `id_card_type`, `id_card_serial_no`, `id_card_number` |
| Naționalitate | `nationalitate` | `citizenship_country` |
| Adresă | `adresa_attributes` (nested) | `f_cg_address_id` (FK) |

**Concluzie:** `f_cg_person` ESTE deja entitatea de identitate. Nu trebuie inventată.

### Pagina „Căutare Proprietari" — dovada nevoii de unificare

Endpoint-ul `/comune/{id}/cautare_proprietari.json` deja face UNION între `proprietar` și `f_cg_person`, cu coloana `sursa` ('Acte' | 'Cadastru'). Asta arată că:
- aplicația **deja încearcă** să prezinte persoana ca entitate unică
- agregarea actuală e fragilă (matching exact pe CNP, eșuează pentru persoanele fără CNP)
- refactor-ul transformă acest workaround în soluție arhitecturală

### Rapoarte de calitate (zona ACTE)

**Raport „Erori T.P." (Sinteza T.P.):**
- **Identificator cadastral eronat** — parcela în afara limitelor de tarla (validare topologică)
- **Parcele identice** — aceeași parcelă pe mai multe TP-uri (potențial conflict)
- **Înregistrări identice** — duplicate exacte

> Implicație: tarlaua are limite de numere parcelă (`nr_parcela_min`, `nr_parcela_max`) — entitate distinctă, nu doar string pe parcelă.

**Raport „Statistica Proprietari":**
- Grupare după Nume / Prenume / Inițiala tată / Suprafață
- Navigare alfabetică A-Z (volum mare de date)
- **Dovadă concretă a problemei de identitate**: AGACHE DUMITRU apare cu ID-uri diferite pe TP-uri diferite (852087 vs 852077), AGACHE VASILE (852090 vs 102235)
- Variațiile diacritice (AMARIUTEI vs AMĂRIUȚEI) nu se grupează — necesită normalizare

---

## 4. Probleme identificate

### P1 — Critice (afectează corectitudinea datelor)

1. **Unificarea greșită a proprietarilor pe nume** (TP-uri vechi, fără CNP)
   - Asumarea inițială: doi proprietari cu nume identic = aceeași persoană
   - Cazuri reale care sparg modelul: omonimie în sat, schimbări de nume (căsătorie), erori de transcriere, moștenire transversală
   - Lecția: **identitatea persoanei pe document ≠ persoana fizică reală**

2. **Persoana nu poate exista fără atașare la act/imobil**
   - `proprietar.act_id` e NOT NULL
   - Imposibil să înregistrezi: moștenitori identificați înainte de CM, mandatari, contestatari, persoane pre-completate, import lot CNP

3. **Duplicare proprietari TP → imobil fără păstrarea legăturii**
   - La crearea imobilului din TP, proprietarii se duplichează în `f_cg_person`
   - Legătura înapoi (`source_deed_id` sau echivalent) e absentă sau neexploatată

### P2 — Importante (afectează utilizabilitatea)

4. **Tarla ca string pe parcelă** — fără entitate proprie cu interval de numere
5. **Roluri persoană limitate** — doar „proprietar"; lipsesc mandatar, moștenitor (în afara CM), contestatar
6. **Lipsa istoricului atașărilor** — nu se urmărește când s-a corectat un proprietar
7. **Validare CNP/CUI absentă** — se acceptă valori invalide (lipsă cifră de control)

### P3 — Datorie tehnică (afectează mentenanța)

8. **Cele două straturi (RO + cgxml)** cu nomenclator diferit — confuzie pentru dezvoltatori noi
9. **Convenții inconsistente** — snake_case + ID-uri mixte, RO + EN
10. **Lipsa indecșilor pe căutările frecvente** — căutare după nume pe TP-uri e probabil lentă
11. **Coloane neutilizate / migrări incomplete** — moștenire de la migrațiile vechi

### P4 — De evaluat (depinde de scopul refactor-ului)

12. **Trecere la full-text search** (PostgreSQL `tsvector`) pe `proprietar` cu unaccent
13. **Soft-delete uniform** pentru toate entitățile (nu doar `anulat` pe acte)
14. **Audit log centralizat** (cine, când, ce a modificat)
15. **API REST/GraphQL** pentru integrări externe (OCPI, eTerra)

---

## 5. Modelul țintă propus

### Principiul central

**Persoana ca entitate decuplată de atașări**, cu CNP ca cheie naturală UNIQUE.

### Structura propusă

```
person  (= f_cg_person, redenumit eventual)
  ├─ id
  ├─ id_code (CNP/CUI) — UNIQUE NOT NULL  [pentru cele identificate]
  ├─ tip: PF | PJ | SR | UAT
  ├─ canonical_nume, canonical_prenume, canonical_initiala_tata
  ├─ canonical_nume_normalized  (fără diacritice, lowercase, pentru match)
  ├─ data_decesului             (NULL dacă în viață)
  ├─ telefon, email, naționalitate, citizenship_country
  ├─ tip_act_ident, serie_act_ident, nr_act_ident
  └─ ...

deed_owner  (= proprietar, păstrat aproape identic)
  ├─ act_id NOT NULL                      (TP-ul)
  ├─ person_id NULLABLE                   (FK către person, NULL = anonim)
  ├─ ordine, cota
  ├─ initial (TRUE/FALSE)                 (originar vs moștenitor propagat)
  ├─ anexa_act_id NULLABLE                (anexa generatoare, dacă initial=FALSE)
  ├─ snapshot_nume, snapshot_initiala_tata, snapshot_prenume  (de pe TP)
  └─ adresa_id (FK către adresa)

immovable_owner  (proprietar pe imobil)
  ├─ f_cg_land_id NOT NULL
  ├─ person_id NULLABLE
  ├─ source_deed_id NULLABLE              (TP-ul de proveniență, pentru audit)
  ├─ ordine, cota
  └─ snapshot_nume etc.
```

### Reguli de business preservate

- **Atașare la act/imobil** — `deed_owner.act_id` și `immovable_owner.f_cg_land_id` rămân NOT NULL
- **Persoana standalone** — `person` poate exista fără nicio atașare (pentru pre-completare, mandatari, contestatari)
- **CNP unifică automat** — la introducerea CNP-ului pe ocurență, se găsește/creează `person` și se atașează
- **Fără CNP rămâne separat** — ocurențe cu `person_id = NULL` rămân izolate (NU se unifică pe nume)
- **Snapshot imutabil** — `snapshot_nume` etc. rămân fixe pe ocurență (fidelitate juridică)

### Mecanica unificării — explicit

```
deed_owner.cnp introdus  →  trigger:
  ├─ caută person WHERE id_code = NEW.cnp
  ├─ dacă există: NEW.person_id = found.id
  └─ dacă nu: INSERT INTO person + NEW.person_id = new.id

deed_owner.cnp = NULL  →  person_id rămâne NULL

același CNP pe multe ocurențe (TP-uri sau imobile)  →  toate au același person_id
                                                       (automat aceeași persoană)
```

### Relația cu rapoartele de calitate

Adăugat: **tabelă persistentă pentru probleme detectate**

```
tp_quality_issue
  ├─ id
  ├─ act_id (sau parcela_id)
  ├─ tip_problema  (OUT_OF_TARLA_RANGE | DUPLICATE_PARCEL | ...)
  ├─ severitate    (warning | error)
  ├─ detalii       (JSON)
  ├─ rezolvat_la, rezolvat_de
  └─ created_at
```

În locul recalculării on-the-fly, raportul devine filtrare pe această tabelă.

### Asistent de unificare (post-refactor)

UI pentru proprietari fără CNP, după unificarea automată prin CNP:

1. Grupează `deed_owner WHERE person_id IS NULL` după `(LOWER(unaccent(nume)), initiala_tata, LOWER(unaccent(prenume)))`
2. Afișează grupurile candidate utilizatorului
3. Permite aprobarea/respingerea fiecărui grup
4. La aprobare: creează `person` (fără CNP) + atașează toate ocurențele

> Niciodată unificare automată pe nume. Decizie umană înregistrată mereu.

---

## 6. Strategia de refactor recomandată

### Recomandarea: Refactor incremental (NU rescriere de la zero)

**Motivare:**

1. Aplicația **NU are probleme arhitecturale fundamentale**. Modelul TP-centric, anexele cu lanț succesoral, separarea „starea curentă"/„istoric documentar", `f_cg_person` ca entitate de identitate — toate sunt corecte conceptual.

2. **Datele au valoare istorică ireversibilă** — mii de TP-uri, anexe operate, geometrie cadastrală. Migrare-singulară-la-final = risc disproporționat.

3. **Aplicația e infrastructură publică** — single-instance în producție, multi-tenant cu zeci/sute de primării. Downtime extins = imposibil de coordonat.

4. **Compatibilitate cgxml e non-negociabilă** — schema impusă de ANCPI prin lege. Refactor-ul trebuie să păstreze fidelitatea exportului 100%.

5. **Cunoașterea încorporată în 14 ani** depășește valoarea unei scheme „curate". Rescrierea ar pierde rapoartele de calitate, validările topologice, fluxurile interinstituționale.

6. **Toate problemele identificate se rezolvă prin adăugări incrementale**, nu prin restructurare.

### Pattern: Strangler Fig

Construire progresivă a noii structuri în jurul celei vechi, până când vechea devine inutilă și se poate îndepărta. Fără moment de discontinuitate.

### Faze propuse

#### Faza 0 — Documentare (acum, fără cod)

Document de design cu modelul țintă în detaliu, ca reper pentru toate deciziile incrementale.

#### Faza 1 — Identitate decuplată (1-2 luni)

- ADD UNIQUE pe `f_cg_person.id_code` (cu permisiunea NULL)
- ADD `proprietar.f_cg_person_id` ca FK opțional
- Migrare datelor: pentru fiecare CNP din `proprietar`, găsește/creează `f_cg_person`
- Modificarea aplicației să folosească legătura

#### Faza 1.5 — Validări topologice persistente (paralel)

- Creare `tp_quality_issue` ca tabelă persistentă
- Migrare logica raportului „Erori T.P." din runtime în background job
- UI pentru filtrare/rezolvare/audit

#### Faza 2 — Persoană standalone (1-2 luni)

- UI pentru gestionarea persoanelor independente
- Căutare globală după CNP/nume direct pe `f_cg_person`
- La introducerea CNP pe ocurență, sistem găsește/atașează automat

#### Faza 2.5 — Asistent de unificare proprietari fără CNP

- Algoritmul de propunere (grupare după nume normalizat)
- UI de revizie umană
- Audit log al unificărilor

#### Faza 3 — Curățare nomenclatură (2-3 luni)

- Redenumire treptată: `f_cg_person` → `person` (alias prin view, apoi rename)
- Restul tabelelor `f_cg_*` la fel
- Decide unificarea `proprietar` cu o tabelă `act_owner` curată

#### Faza 4 — Funcționalități noi (continuu)

- Toate dezvoltările noi pe schema curată
- Bug-urile vechi se rezolvă în direcția corectă
- Datoria tehnică reziduală scade în timp

### Constrângeri operaționale (specifice multi-tenant single-instance)

1. **Migrări reversibile sau zero-risk**
   - Pattern: ADD COLUMN nullable → populare în background → ADD constraint → enforcement
   - Niciodată DROP COLUMN sau ALTER fără reversibilitate
   - `gem strong_migrations` recomandat

2. **Migrări de date batched**
   - Background jobs (Sidekiq), batch 1000-10000 rânduri
   - Niciodată `UPDATE` întreaga tabelă într-o singură tranzacție

3. **Aplicația trebuie să accepte stări intermediare**
   - În tranziție: unele rânduri au `person_id`, altele nu
   - Toate query-urile, view-urile, rapoartele tolerează ambele cazuri

4. **Permisiuni integrate în fiecare migrație**
   - Tabele/coloane noi → reguli de acces clarificate cu utilizatorii reali
   - Operațiuni sensibile (unificare proprietari) → roluri stricte

### Proceduri operaționale necesare

**Pre-refactor:**
- Mediu de staging cu copie producție realistă
- Backup automat pre-migrate
- Monitoring de performanță (locks, deadlock-uri, query-uri lente)
- Procedură de rollback documentată per migrație

**Pentru fiecare migrație:**
- Test pe staging cu volum producție
- Aplicare în window de mentenanță (weekend / noapte)
- Monitorizare 24-48h post-deploy
- Documentarea oricăror incidente

**Comunicare cu utilizatorii:**
- Notificare prealabilă pentru migrațiile vizibile
- Documentație actualizată (manuale, training)
- Canal de feedback pentru raportare probleme

---

## 7. Întrebări deschise

### Decizii de business (clarificate parțial)

- ✅ **Cotele pe TP** — clarificat: cotele moștenitorilor sunt relative la decedat, nu la TP
- ⚠ **Cota pe TP vs pe parcelă** — neclarificat dacă există cazuri cu cote diferite per parcelă
- ✅ **Acte succesorale** — clarificat: tabelă `anexa_act` separată cu `parent_anexa_id` self-FK, lanț recursiv
- ⚠ **Tarla ca entitate vs string** — confirmat că trebuie entitate proprie (cu interval numere parcelă), dar starea actuală în baza vie de verificat
- ⚠ **Renunțare la moștenire** — văzută în UI, nu confirmat dacă e implementată
- ⚠ **Ștergere proprietar decedat după CM operat** — neclarificat (probabil rămâne cu flag, nu se șterge)

### Decizii de implementare

- ⚠ **Opțiunea A/B/C pentru `person`** — recomandat hibrid (tabel + populare automată prin trigger sau aplicație), dar de discutat cu partenerul în funcție de capacitate Rails
- ⚠ **Validare CNP/CUI** — la nivel DB (CHECK function) sau Rails sau ambele
- ⚠ **CUI și CNP în aceeași coloană `id_code`** — recomandare: da, cu CHECK adaptat în funcție de `tip` (PF/PJ/SR/UAT)
- ⚠ **SR și UAT ca person globale sau ocurențe per TP** — recomandare: globale (1 rând per UAT)

### De aflat din schema reală

- Format exact al `imp_nr_cad`, `imp_nr_cf`, `imp_nr_topo`
- Format al cotelor (string `"1/2"` vs două coloane numerator/numitor)
- Sistemul de coordonate GIS (presupus EPSG:3844 — Stereo70)
- Bibliotecile de import DXF
- Stocarea fișierelor (disk, S3, BLOB)
- Volumetria reală (rânduri în tabele principale, procent CNP completat)

---

## 8. Materiale de cerut partenerului de dezvoltare

### A. Critice (fără ele migrarea nu poate începe)

1. **Schema bazei de date** — `pg_dump --schema-only` (sau echivalent), inclusiv FK-uri, indecși, constraints, secvențe
2. **Codul Rails** — `app/models/*.rb` și `db/migrate/*` (pentru regulile de business + istoricul evoluției schemei)
3. **DBMS** — confirmare versiune + extensii (PostGIS?)

### B. Importante (semantică)

4. **Convenții de date**
   - Format `imp_nr_cad`, `imp_nr_cf`, `imp_nr_topo`
   - Format cote
   - Semnificația flag-urilor `cm_neoperat`, `partaj_neoperat`, `cm_incomplete`, `partaj_incomplete`
   - Convenții NULL vs '' vs 0

5. **Reguli de business** pentru operațiuni complexe
   - „Creare imobil din TP" — ce duplichează exact, ce conexiuni păstrează
   - „Audit juridic" — ce verifică, unde stochează rezultatul
   - „Distribuire automată acte scanate" — pe ce criterii face matching
   - „Import OCPI (T.P.)" — formatul de input, maparea câmpurilor

6. **Volumetria**
   - Rânduri în tabelele principale
   - Procent TP-uri cu CNP completat
   - Număr de UAT-uri active
   - Distribuție etapa 1 vs etapa 2

### C. Infrastructură

7. **Stocare fișiere** — PDF scanate, DXF, cgxml (disk, S3, BLOB?), structura de directoare, integrare Google Drive
8. **GIS** — tipul coloanei de geometrie pe `f_cg_land`, sistem coordonate, biblioteci import DXF
9. **Job-uri background** — Sidekiq/DelayedJob, ce job-uri există

### D. Probleme cunoscute și acces

10. **Probleme cunoscute** — cazuri unificare greșită identificate, TP-uri orfane, sume necorecte, datorii tehnice tolerate
11. **Documentație** — manuale, diagrame ER, specificații cgxml folosite
12. **Acces** — read-only la producție pentru spot-checks, dump anonimizat pentru testarea migrării



---

## Notă finală

Aplicația e-CAD e exemplul rar al unui sistem **bine gândit conceptual** care a evoluat în pas cu legislația și cu nevoia operațională, având nevoie nu de rescriere ci de **îngrijire**. Lecțiile învățate pe parcurs (problema unificării proprietarilor, separarea TP/imobil, decuplarea persoanei) sunt **dovezi de maturitate**, nu de eșec.

Cunoașterea încorporată în 14 ani de operare — în rapoartele de calitate, validările topologice, fluxurile interinstituționale între primării și specialiști — e mai valoroasă decât claritatea unei scheme noi. Refactor-ul incremental respectă această valoare, curățând datoria tehnică acumulată fără să pună în pericol ce funcționează.

```markdown
## Context specific pentru acest repo

Acest repo este **mediul de dezvoltare independent** pentru modulul GIS al aplicației e-CAD.
Scopul: dezvolt modulul GIS izolat, pe o copie locală a schemei e-CAD, fără a atinge producția.
La final, livrez partenerului DOAR codul nou (modulul GIS), nu și schema reprodusă.

Reguli de lucru:
- NU modific schema e-CAD existentă (tabelele act, parcela, proprietar, f_cg_*, etc.)
- TOATE tabelele noi au prefix `gis_` ca să fie ușor de identificat la livrare
- TOATE migrările noi sunt într-un folder separat sau au timestamp clar mai mare
  decât ultima migrare e-CAD, ca partenerul să le aplice în ordine corectă
- Convenția de cod: respectăm stilul Rails al aplicației existente
  (snake_case, RESTful controllers, ActiveRecord standard)
- Limba: comentarii în română (consistent cu aplicația existentă),
  nume de cod în engleză (gis_layer, geo_feature, etc.)
```
