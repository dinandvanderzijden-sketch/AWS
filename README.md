# AWS Infrastructuur & Applicatie — Brabantse Delta / NCA

Terraform voor een containerized NGINX-applicatie op AWS ECS Fargate, met een
MariaDB-database, een Prometheus/Grafana-observabilitystack en een
GitHub Actions-pipeline die infra én applicatie uitrollet.

Region: `eu-west-1` · Account: `491799435972` · Terraform: `>= 1.10` (CI pint 1.16.2)

---

## Snel starten

```bash
# Eenmalig per machine, ná de wijziging van de backend-configuratie
terraform init -reconfigure

# Lokaal controleren zonder iets in AWS te doen
terraform fmt -check -recursive
terraform validate
terraform test

# Uitrollen
terraform plan
terraform apply
```

> **Let op — `init -reconfigure`**: de backend heeft `use_lockfile = true`
> gekregen (REQ-NCA-P1-06). Een bestaande lokale `.terraform`-map kent die
> instelling nog niet en `terraform init` weigert dan met
> *"Backend configuration block has changed"*. Eén keer `-reconfigure` lost het
> op. Op CI is elke runner schoon, dus daar is een gewone `terraform init`
> voldoende.

Volledige uitleg, bewijsvoering en de lijst met openstaande punten staan in
**[TESTPLAN.md](TESTPLAN.md)**.

---

## Overzicht van de bestanden

| Bestand | Wat het doet |
|---|---|
| `main.tf` | Provider, S3-backend met locking, alle `output`s voor de pipeline |
| `variables.tf` | Alle invoer, fail-closed qua beveiliging |
| `oidc.tf` | OIDC-provider en de rol `github-actions-deploy` waarmee de pipeline inlogt |
| `network.tf` | Hub-and-spoke VPC's, Transit Gateway, subnetten, route tables |
| `security.tf` | Security-group-matrix (deny-all, per poort expliciet toegestaan) |
| `compute.tf` | ECR, ALB, blue/green target groups, ECS-cluster/-service/-taakdefinitie, autoscaling |
| `database.tf` | RDS MariaDB, Secrets Manager, KMS |
| `endpoints.tf` | Interface endpoints (S3, ECR, Secrets Manager, …) |
| `monitoring.tf` | Prometheus + Grafana op EC2, dashboard, SSM-beheerrol |
| `alarms.tf` | SNS-topic en de vijf CloudWatch-alarms |
| `runner.tf` | Optionele self-hosted GitHub Actions-runner (standaard uit) |
| `appspec.yaml` | CodeDeploy blue/green-script |
| `task-definition.json` | Taakdefinitie-template; `DB_HOST` wordt door de pipeline gezet |
| `dockerfile` | NGINX-image |
| `default.conf` | NGINX-serverblok, inclusief `/healthz` |
| `tests/*.tftest.hcl` | 25 plan-based assertions (`terraform test`) |
| `.github/workflows/deploy.yml` | De pipeline: lint → plan → deploy |

---

## Eisen uit het analyse-document en waar ze staan

| REQ | Korte omschrijving | Waar het in de code staat | Bewijs |
|---|---|---|---|
| **REQ-NCA-P1-01** | Deny-all; per poort/protocol expliciet toegestaan | `security.tf` | `tests/security.tftest.hcl` |
| **REQ-NCA-P1-02** | Geen publieke toegang tot data- en beheerlaag | `security.tf`, `database.tf`, `monitoring.tf` | `tests/security.tftest.hcl`, TESTPLAN T3 |
| **REQ-NCA-P1-03** | Containerized & configureerbare deployment | `dockerfile`, `compute.tf`, `task-definition.json` | `tests/application.tftest.hcl` |
| **REQ-NCA-P1-04** | Horizontale schaalbaarheid en hoge beschikbaarheid | `compute.tf`, `alarms.tf` | `tests/application.tftest.hcl` |
| **REQ-NCA-P1-05** | Observability: dashboard + notificatie bij overschrijding | `monitoring.tf`, `alarms.tf` | `tests/observability.tftest.hcl`, TESTPLAN T6 |
| **REQ-NCA-P1-06** | Veilig gehoste, vergrendelde remote state | `main.tf` (backend `s3` + `use_lockfile`) | `tests/observability.tftest.hcl` |
| **REQ-NCA-P1-07** | Pipeline: preview vóór uitrol, automatische tests | `.github/workflows/deploy.yml`, `runner.tf` | `tests/observability.tftest.hcl`, TESTPLAN T7, T11 |
| **REQ-NCA-P1-08** | Git-repo is de enige bron van waarheid | `main.tf` (outputs), `.github/workflows/deploy.yml` | `tests/observability.tftest.hcl` |

De `lint`-job in de pipeline faalt zodra een van deze ID's uit deze tabel
verdwijnt, zodat de koppeling tussen onderzoeksdocument en code niet stilletjes
vervalt.

---

## De pipeline

```
push naar main  --->  lint --->  plan (preview) --->  deploy
                      |            |                     |
               fmt + validate  terraform test      terraform apply
               REQ-ID-controle  + plan/preview      + ECR push
                                                       + CodeDeploy blue/green
```

- **lint** draait zonder AWS-credentials en zonder `terraform init`. Draait
  voor elke push en elke pull request, ook uit forks.
- **plan** voert `terraform test` uit en zet het volledige plan in de step
  summary. Vereist de OIDC-rol, dus draait alleen bij een push naar `main`.
- **deploy** doet `terraform apply`, haalt alle resourcenamen uit
  `terraform output` in plaats van uit hardcoded strings, en draait alleen bij
  een push naar `main`.

### Hoe de pipeline inlogt bij AWS

Via **OIDC**. Er is geen access key, geen secret en niets om in te vullen.

Zo werkt het: als een job start, vraagt GitHub een kort token op (een JWT). De
action `aws-actions/configure-aws-credentials` stuurt dat naar AWS, en AWS
ruilt het in voor tijdelijke credentials van de rol `github-actions-deploy`.
Het token leeft een paar minuten en is één keer bruikbaar.

Wat je daarvoor in GitHub doet: **niets**. Geen secret aanmaken, geen sleutel
plakken, niets roteren. Er staat dan ook geen `secrets.AWS_*` meer in de
workflow, en dat houdt de tests ook in de gaten.

De rol en de trust policy staan in [`oidc.tf`](oidc.tf).

**Wat je één keer moet doen** is de rol aanmaken, lokaal of met je eigen
credentials:

```bash
terraform apply
```

Dat maakt de OIDC-provider en de rol aan. Daarna werkt de pipeline. Let op:
de eerste keer moet dat nog met jouw eigen credentials, want de rol bestaat
dan nog niet.

#### Wat de trust policy toestaat

Precies één ding: een push naar `main` in deze repo. Een pull request — uit
deze repo of uit een fork — krijgt een andere `sub` en komt er dus niet in.
Daarom draait de `plan`-job alleen op een push naar `main`, en doen PR's
alleen de `lint`-job, zonder AWS-toegang.

Wil je tóch een plan zien bij een pull request, dan moet er een tweede,
read-only rol bij. Dat is bewust niet gedaan: één rol is simpeler, en de
veiligheidswinst van de huidige opzet is groter dan het gemak.

#### Als de inlog toch misgaat

Foutmelding `Not authorized to perform sts:AssumeRoleWithWebIdentity` betekent
dat de `sub` van het token niet in de trust policy staat. De foutmelding toont
de volledige `sub`; zet die letterlijk in `subs_main` in `oidc.tf`.
## Variabelen die je waarschijnlijk wilt zetten

| Variabele | Default | Waarom |
|---|---|---|
| `admin_cidr` | `""` | Jouw eigen `/32` zodat Grafana en Prometheus bereikbaar worden. Leeg laten = fail-closed, niets publiek. `0.0.0.0/0` wordt geweigerd. |
| `alert_email` | `""` | Ontvangt de alarmmeldingen na bevestiging van de SNS-mail. |
| `max_task_count` | `4` | Bovengrens voor autoscaling. De TCO-analyse gaat uit van een piek van 10. |
| `key_pair_name` | `""` | Alleen nodig als je echt SSH wilt; anders beheer je via SSM Session Manager. |
| `enable_spoke_endpoints` | `true` | Noodzakelijk, geen optimalisatie: zonder deze endpoints blijven de taken op PENDING staan. Zie TESTPLAN T13.3. |
| `enable_self_hosted_runner` | `false` | Zet pas aan als je de workflow ook omzet naar `runs-on: [self-hosted, linux]`. Zie TESTPLAN T7. |
| `github_repo` | `dinandvanderzijden-sketch/AWS` | Bepaalt wie de rol uit `oidc.tf` mag overnemen: alleen een push naar `main` in deze repo. Ook gebruikt om de self-hosted runner te registreren. |
| `github_owner_id` | `229950911` | Numerieke eigenaar-ID voor de `sub`-claim in het OIDC-token. |
| `github_repo_id` | `1372748269` | Numerieke repo-ID voor de `sub`-claim in het OIDC-token. |

Volledige beschrijvingen staan in `variables.tf`.

---

## Bewust niet aangepast

Een aantal zaken is bewust *niet* veranderd omdat het de bestaande
uitrolketen zou breken. Ze staan in TESTPLAN.md onder "Bewuste afwijkingen" met
de reden:

- ECR is op `MUTABLE` blijven staan, omdat de pipeline ook `:latest` pusht.
- Er is geen HTTPS/ACM/WAF toegevoegd; de ALB luistert op HTTP.
- Het Prometheus-paneel in het dashboard blijft optioneel: cross-VPC DNS werkt
  niet zonder Route 53 Resolver Inbound Endpoint (TESTPLAN T4).
- `max_task_count` staat op 4 terwijl de TCO-analyse van 10 taken uitgaat, en de
  database is `db.t3.micro` in plaats van `db.t4g.micro`.
- OIDC is verwijderd uit de pipeline; die draait nu met AWS-sleutels uit
  GitHub Secrets. Zie "De AWS-credentials voor CI" hierboven voor de afweging
  en de aanbevolen extra horde (GitHub Environment).
