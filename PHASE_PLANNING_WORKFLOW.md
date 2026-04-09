# Phase Planning Workflow

Gebruik dit document als vaste werkwijze voor het ontwerpen van een nieuwe projectfase, het vertalen naar de runner-control-plane, en het voorbereiden van een lange autonome run.

Dit document is bedoeld om direct aan een planner, operator of Codex-sessie te geven.

## Doel

Lever een nieuwe fase op die:
- inhoudelijk scherp genoeg is om zonder freestylen gebouwd te worden
- direct traceerbaar is naar de canonieke `SPEC.md`
- is vertaald naar een runner-veilige `ROADMAP.md` en `units/`
- prep-groen is vóórdat de runner start

## Verwachte output

Aan het einde van deze workflow moeten deze bestanden kloppen:
- optioneel `docs/PROJECT_SPEC.md` of `PROJECT_PLAN.md` als rijke ontwerpbron
- root `SPEC.md` als canonieke runner-spec
- `VISION.md`
- `DECISIONS.md`
- `ROADMAP.md`
- `units/*.md`

De runner mag pas starten nadat de fase prep-groen is.

## Kernregels

- `SPEC.md` is normatief. Niet `docs/PROJECT_SPEC.md`, niet chatgeschiedenis.
- De roadmap is een afgeleide van de spec, geen parallel plan.
- Open keuzes horen in `DECISIONS.md`, niet verstopt in units.
- Units moeten uitvoerbaar zijn voor een verse agent zonder verborgen context.
- `prep-summarize` en `ready-check` zijn verplichte gates, geen optionele sanity checks.
- `VISION.md` en `DECISIONS.md` zijn niet alleen prose; de runner leest verplichte YAML prep-secties direct van disk.
- Een unit is pas runner-safe als hij niet alleen inhoudelijk goed voelt, maar ook door de huidige complexity- en dependency-gates heen komt.

## Stap 1: Schrijf eerst de rijke ontwerpbron

Als er al een rijke ontwerpbron bestaat, werk dan eerst daarin. Als die nog niet bestaat en de fase klein en helder is, mag je direct in root `SPEC.md` werken.

Gebruik zo nodig `docs/PROJECT_SPEC.md`, `PROJECT_PLAN.md`, of een vergelijkbaar rijk brondocument als bronmateriaal.

Dat ontwerpdocument moet minimaal expliciet maken:
- einddoel van de fase
- scope en non-goals
- belangrijkste gebruikersflows of systeemflows
- dataflow, integraties en systeemgrenzen
- directories, componenten en verwachte bestandslocaties
- install-, run-, build- en testcommando's
- externe dependencies, secrets en live-ops
- open product- of technische keuzes

Gebruik deze fase nog niet om units te schrijven.

## Stap 2: Normaliseer naar root SPEC.md

Zet daarna pas de ontwerpbron om naar root `SPEC.md`.

`SPEC.md` moet een machine-checkbare `## Runner Spec` YAML block bevatten met:
- `requirements`
- `environment`

Per requirement minimaal:
- `id`
- `title`
- `summary`
- `paths`
- `acceptance`
- `mode`

`mode` is:
- `local`
- `live_ops`

In `environment` minimaal:
- `required_tools`
- `required_paths`
- `install_commands`
- `run_commands`
- `test_commands`
- `external_dependencies`

Optioneel:
- `required_env_vars`

## Stap 3: Pas de SPEC-first gate toe

Voordat je een roadmap schrijft, controleer je of de spec scherp genoeg is.

Beantwoord minimaal deze vragen:
- is het eindresultaat concreet genoeg beschreven
- zijn scope en non-goals expliciet
- zijn de belangrijkste flows en schermen helder
- zijn architectuur en dataflow concreet genoeg
- zijn directories en bestandslocaties benoemd
- zijn build-, test- en run-commando's bekend
- zijn externe dependencies en live-ops expliciet gemaakt
- zijn open keuzes echt besloten of bewust open gelogd

Als het antwoord op een of meer vragen nee is:
- verbeter eerst `SPEC.md`
- schrijf nog geen `ROADMAP.md`
- maak nog geen `units/`

## Stap 4: Leg fase-intentie en open keuzes vast als prep-inputs

Werk daarna:
- `VISION.md`
- `DECISIONS.md`

Belangrijk: deze bestanden moeten niet alleen inhoudelijk kloppen, maar ook de machine-leesbare prep-secties bevatten die de runtime direct inleest.

`VISION.md` moet een `## Runner Prep` YAML block bevatten met minimaal:
- doel
- doelgroep
- succescriteria
- constraints
- non-goals

Gebruik prose in `VISION.md` gerust aanvullend, maar zorg dat de prep-sectie canoniek genoeg is voor unattended readiness.

`DECISIONS.md` moet een `## Decision Log` YAML block bevatten met `decisions`.

Per decision minimaal:
- `id`
- `title`
- `scope`
- `status`
- `blocking`
- `summary`

`status` is:
- `open`
- `decided`

Gebruik `DECISIONS.md` inhoudelijk voor:
- open keuzes
- besliste keuzes
- blocking decisions
- scope van de keuze

Belangrijke regel:
- als een worker straks een wezenlijke keuze zou moeten maken, dan is die keuze nog niet goed genoeg geland in `SPEC.md` of `DECISIONS.md`

## Stap 5: Vertaal de SPEC naar ROADMAP.md

Maak de roadmap direct uit de spec.

Voor elke milestone geldt:
- hij moet terug te voeren zijn op expliciete `spec_refs`
- de bouwvolgorde moet logisch zijn
- blockers moeten vroeg worden opgelost
- prep-, enablement- of structuurwerk mag een eigen milestone of vroege unit zijn

Niet doen:
- losse brainstormmijlpalen toevoegen buiten de spec
- UX of architectuur verzinnen die niet in de spec staat
- integratie- of toolingschulden stil doorschuiven naar latere units

## Stap 6: Schrijf runner-veilige units

Schrijf daarna pas `units/*.md`.

Elke nieuwe unit moet in de praktijk deze frontmatter hebben:
- `id`
- `milestone`
- `title`
- `depends_on`
- `spec_refs`
- `owned_files`
- `required_paths`
- `required_tools`
- `creates_paths`
- `installs_tools`
- optioneel `required_env_vars`
- `smoke_validation_commands`
- `full_validation_commands`
- `requires_live_ops`
- `reviewer_focus`
- optioneel `execution_lane_hint`

Legacy-opmerking:
- `validation_commands` wordt nog als compatibiliteitsveld ondersteund, maar nieuwe units moeten staged validation gebruiken met `smoke_validation_commands` en `full_validation_commands`

En daarna exact deze secties:
- `# Objective`
- `## In scope`
- `## Non-goals`
- `## Completion contract`

## Unit-authoring regels

Een goede unit is:
- smal
- toetsbaar
- expliciet
- uitvoerbaar zonder verborgen kennis

Elke unit moet:
- duidelijke `owned_files` hebben
- concrete paden en componenten noemen
- snelle semantische smoke-validatie hebben
- zwaardere full-validatie apart hebben
- exact aangeven wat buiten scope valt
- expliciet maken welke repo-paden al moeten bestaan via `required_paths`
- expliciet maken welke repo-paden deze unit oplevert via `creates_paths`
- dependencies zo modelleren dat een vereiste producer-unit daadwerkelijk vóór de consumer schedulable is

Vermijd:
- `TBD`
- `todo`
- `decide`
- `confirm with user`
- `if needed`
- `where appropriate`
- units die eerst repo-structuur of toolkeuze moeten uitvinden
- units die ontwerpbeslissingen aan de worker overlaten
- units die artefacten nodig hebben die pas in een latere unit of latere milestone worden geproduceerd
- units waarbij meerdere producers hetzelfde `creates_paths` claimen

## Huidige preflight-regels voor unitgrootte

De huidige runtime behandelt unit-shaping strenger dan alleen een zachte "hou het klein"-vuistregel.

Preflight kijkt nu onder meer naar:
- aantal `owned_files` plus `creates_paths`
- aantal concerns of lagen, zoals `ui`, `viewmodel`, `service`, `model`, `tests`, `docs`, `project_wiring`
- compile-relevante paden
- aantal validation commands
- zware validation blast-radius
- aantal upstream `depends_on`
- aantal downstream dependents
- deliverable count in de unit-body
- risky concern-mixes

Gevolg:
- middelhoge complexity geeft warning
- hoge complexity geeft blocker
- brede app/product-code units met zware validation kunnen direct blokkeren
- docs-only units zijn soepeler, maar niet vrijgesteld van alle prep-signalen

Praktische authoring-regel:
- als een unit meerdere concerns mixt, veel paden heeft, veel deliverables opsomt, of zware validation nodig heeft, split hem vóór je preflight draait

## Dependency- en producer-regels

`required_paths`, `creates_paths`, en `depends_on` zijn samen een contract, niet losse hints.

Gebruik deze regels:
- als een unit een pad nodig heeft dat door een andere unit wordt gemaakt, zet dat pad in `required_paths`
- laat precies één unit eigenaar zijn van een gegeven `creates_paths` output
- zorg dat de producer-unit vóór de consumer schedulable is; "staat eerder in het bestand" is niet genoeg als dependencies anders lopen
- vertrouw niet op het feit dat een pad toevallig al lokaal in de repo bestaat als de control-plane zegt dat een andere unit het pas hoort te produceren
- gebruik `depends_on` om echte producer-consumerrelaties expliciet te maken

Preflight blokkeert nu onder meer op:
- `required_paths` die alleen door latere units of later bereikbare units worden geproduceerd
- ambigue producer-paden met meerdere claimende units
- contracten die buiten `owned_files` of zonder expliciete dependency naar producer-owned paden verwijzen

## Lane-keuze

Gebruik `execution_lane_hint` alleen bewust:
- `auto` voor normale units
- `worker_first` voor pure gedrag- of logica-units
- `operator_first` voor structurele units zoals project wiring, target setup, build graph, of andere repo-structuurgevoelige slices

De hint helpt token-efficiëntie, maar vervangt geen goede unit-shaping.

Belangrijk:
- gebruik `operator_first` niet om een te brede unit te "redden"
- complexity-blockers moeten gesplitst worden; lane-keuze is geen escape hatch voor een unit die prep-rood is
- complexity-warnings kunnen wel leiden tot advisory operator-first triage

## Validatie-ontwerp

Schrijf validatie alsof je review-problemen zo vroeg mogelijk wilt afvangen.

`smoke_validation_commands` moeten:
- snel zijn
- semantisch genoeg zijn om de kernclaim van de unit vroeg te testen
- vanuit repo-root draaien

`full_validation_commands` moeten:
- zwaarder mogen zijn
- pas na review/gate relevant zijn
- nog steeds concreet en herhaalbaar zijn

Gebruik geen build-only smoke voor een unit die gedragsclaims maakt, tenzij dat gedrag elders heel gericht en expliciet bewezen wordt.

Houd ook rekening met blast-radius:
- zware validation zoals `xcodebuild test`, `xcodebuild build`, brede `pytest`, `swift test`, of andere full-suite checks tellen mee in complexity
- zware validation is prima voor smalle units, maar wordt een preflight-risico als de unit tegelijk breed is in paden, lagen of deliverables
- voor nieuwe units: gebruik geen legacy `validation_commands` tenzij je bewust een oude unit migreert of compatibiliteit nodig hebt

## Live-ops

Als een unit echte live systemen, secrets, devices of externe activering nodig heeft:
- zet `requires_live_ops: true`
- benoem `required_env_vars`
- beschrijf het expliciet in `SPEC.md`

Als het slechts gaat om repo-side voorbereiding voor latere live enablement:
- houd de unit lokaal uitvoerbaar
- documenteer live activering als checklist of runbook
- maak niet onnodig een live-ops unit van een lokale featurebasis

## Prep vóór start

Voer vanuit repo-root minimaal uit:

```bash
python3 bin/runtime prep-summarize --root . --milestone P5-M1
python3 bin/runtime ready-check --root . --milestone P5-M1
python3 bin/runtime prep-summarize --root . --program
python3 bin/runtime ready-check --root . --program
```

Gebruik alleen `--allow-live-ops` als de fase echt live-ops mag doen en alle vereiste env vars aanwezig zijn.

Als live-ops bewust onderdeel van de fase is, draai aanvullend ook:

```bash
python3 bin/runtime ready-check --root . --program --allow-live-ops
```

## Hoe je prep leest

- `Autonomy blockers` moeten naar nul voor een unattended fresh start
- `Autonomy warnings` hoeven niet per se naar nul, maar moeten bewust acceptabel zijn
- `Autonomy advice` markeert likely babysit points en triage-risico

Huidige blockers kunnen nu ook komen uit:
- te brede of te complexe units
- future-dependency fouten tussen `required_paths` en `creates_paths`
- ambigue producer-paden
- ontbrekende machine-readable prep-secties in `VISION.md` of `DECISIONS.md`

Als `ready-check` niet groen is:
- fix eerst de control-plane
- start de runner nog niet
- herhaal prep tot zowel milestone- als program-brede `ready-check` groen zijn

## Definition of Done voor de ontwerpfase

De fase is pas klaar voor uitvoering als:
- `SPEC.md` concreet en canoniek is
- `VISION.md` en `DECISIONS.md` bijgewerkt zijn
- de verplichte `## Runner Prep` en `## Decision Log` YAML blocks kloppen
- `ROADMAP.md` traceerbaar uit de spec is opgebouwd
- alle nieuwe units runner-safe zijn
- milestone- en program-brede prep groen zijn
- eventuele live-ops expliciet en bewust zijn gemodelleerd

## Compacte checklist

Gebruik deze checklist vlak voor start:

- rijke ontwerpbron geschreven
- root `SPEC.md` genormaliseerd
- SPEC-first gate gehaald
- `VISION.md` bijgewerkt inclusief `## Runner Prep`
- `DECISIONS.md` bijgewerkt inclusief `## Decision Log`
- `ROADMAP.md` vertaald uit de spec
- units geschreven met staged validation
- `required_paths`, `creates_paths`, en `depends_on` kloppen semantisch
- geen unit triggert voorspelbaar een complexity-blocker
- `execution_lane_hint` bewust gezet waar nodig
- `prep-summarize --milestone` groen of acceptabel
- `ready-check --milestone` groen
- `prep-summarize --program` groen of acceptabel
- `ready-check --program` groen

## Aanbevolen praktische flow voor Homebase P5

Voor een nieuwe `homebase`-fase:
1. schrijf of laat schrijven: rijke ontwerpbron als dat helpt, anders werk direct in `SPEC.md`
2. normaliseer naar root `SPEC.md`
3. werk `VISION.md` en `DECISIONS.md` bij inclusief hun YAML prep-secties
4. voeg `P5` toe aan `ROADMAP.md`
5. schrijf de `P5` units met kleine scope, staged validation, en correcte producer-consumer dependencies
6. draai prep-checks
7. split of herschrijf units die op complexity of future dependencies stuklopen
8. itereren tot milestone- en program-brede `ready-check` groen zijn
9. commit de control-plane
10. start pas daarna de runner
