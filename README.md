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
  ook voor pull requests uit forks.
- **plan** voert `terraform test` uit en zet het volledige plan in de step
  summary. Vereist AWS-credentials, dus hij wordt overgeslagen voor PR's uit
  forks.
- **deploy** draait alleen bij een push naar `main` en haalt alle
  resourcenamen uit `terraform output` in plaats van uit hardcoded strings.

### De AWS-credentials voor CI

De pipeline logt in met een access key van een eigen IAM-user
`github-actions-deploy`, die in GitHub Secrets staat. Die user staat bewust
**buiten** Terraform: zo blijft de git-repo de enige bron van waarheid voor de
infrastructuur, en de credentials kunnen niet per ongeluk meegecommit worden.

Aanmaken, eenmalig, met je eigen account:

```bash
aws iam create-user --user-name github-actions-deploy
aws iam create-access-key --user-name github-actions-deploy
```

Daarnaast heeft de user nodig: `PowerUserAccess` (alles behalve IAM), een
eigen policy voor het IAM-beheer van de vier rollen in deze stack
(`ecs_execution_role`, `ecs_task_role`, `monitoring`, `codedeploy_role`) met
`iam:PassRole` op precies die vier rollen, en lees/schrijfrechten op de
state-bucket `tfstate-eu-west-1-491799435972`. De exacte policies stonden
eerder in `oidc.tf` en zijn terug te vinden in de git-historie.

Staat er in je account nog een OIDC-provider uit de vorige opzet, dan moet je
die eerst vrijgeven voordat Terraform hem mag verwijderen. AWS weigert een
provider te verwijderen zolang er nog een client op `sts` `actions-to-access`
toestaat:

```bash
aws iam update-open-id-connect-provider-client \
  --open-id-connect-provider-arn <arn> --client-id sts \
  --no-enable-actions-to-access-oidc
```

Het verwijderen van de provider is een `terraform apply` en dus niet meer
terug te draaien. Wil je hem eerst laten staan, zet `oidc.tf` dan terug uit
`git show 93a1ae3:oidc.tf`.

Vervolgens in GitHub: **Settings -> Secrets and variables -> Actions**:

| Secret | Waarde |
|---|---|
| `AWS_ACCESS_KEY_ID` | uit `create-access-key` |
| `AWS_SECRET_ACCESS_KEY` | uit `create-access-key` |

Elke job controleert met `aws sts get-caller-identity` of hij werkelijk als
deze user binnenkomt, en faalt hard als dat niet zo is.

**Twee dingen om te weten over deze opzet:**

1. **De plan-job is niet meer read-only.** Toen de pipeline via OIDC liep zat
   de scheiding tussen plan en deploy in de trust policy van twee rollen. Die
   laag is er nu niet meer: de plan-job draait met dezelfde sleutel als de
   deploy-job. Een pull request binnen deze repo draait dus met
   schrijfrechten. Een PR uit een *fork* krijgt daarentegen geen secrets van
   GitHub en wordt netjes overgeslagen.
2. **Statische keys blijven geldig als de repo verdwijnt.** Behandel ze als een
   wachtwoord: roteer ze, en overweeg de twee maatregelen hieronder.

Aanbevolen als je punt 1 wilt afdekken:

- Zet de secrets op een **GitHub Environment** met een verplichte
  goedkeurder. De deploy-job krijgt dan `environment: <naam>` en een mens
  moet de release akkoord geven voordat er iets naar AWS gaat.
- Roteer de key zodra iemand met repo-toegang de repo verlaat.

## Variabelen die je waarschijnlijk wilt zetten

| Variabele | Default | Waarom |
|---|---|---|
| `admin_cidr` | `""` | Jouw eigen `/32` zodat Grafana en Prometheus bereikbaar worden. Leeg laten = fail-closed, niets publiek. `0.0.0.0/0` wordt geweigerd. |
| `alert_email` | `""` | Ontvangt de alarmmeldingen na bevestiging van de SNS-mail. |
| `max_task_count` | `4` | Bovengrens voor autoscaling. De TCO-analyse gaat uit van een piek van 10. |
| `key_pair_name` | `""` | Alleen nodig als je echt SSH wilt; anders beheer je via SSM Session Manager. |
| `enable_spoke_endpoints` | `true` | Noodzakelijk, geen optimalisatie: zonder deze endpoints blijven de taken op PENDING staan. Zie TESTPLAN T13.3. |
| `enable_self_hosted_runner` | `false` | Zet pas aan als je de workflow ook omzet naar `runs-on: [self-hosted, linux]`. Zie TESTPLAN T7. |
| `github_repo` | `dinandvanderzijden-sketch/AWS` | Alleen voor het registreren van de self-hosted runner; de actieve pipeline gebruikt GitHub-gehoste runners. |

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
