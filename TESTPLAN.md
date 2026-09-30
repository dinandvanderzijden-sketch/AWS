# Test- en Validatieplan

Bijbehorend aan het onderzoeksdocument *Analyse Document* en het
*Ontwerpdocument*. Dit plan laat zien dat de gerealiseerde infrastructuur aan de
acht eisen voldoet — en, waar dat niet zo is, waarom.

Er zijn twee soorten tests:

- **Geautomatiseerd** — draaien zonder AWS-credentials, zonder kosten en in
  seconden. Deze horen in het bewijsstuk van de klant: de output van
  `terraform test` en een geslaagde pipeline-run.
- **Handmatig** — vragen een echte omgeving. Deze doe je één keer na
  `terraform apply` en lever je aan als screenshot of logregel.

---

## Overzicht

| # | Test | REQ | Type | Status |
|---|---|---|---|---|
| T0 | Eenmalige lokale setup (`init -reconfigure`) | P1-06 | handmatig | verplicht vóór T1 |
| T1 | Statische controles: fmt, validate, 25 assertions | P1-01 t/m P1-08 | geautomatiseerd | ✅ 25/25 |
| T2 | Netwerkisolatie: database niet publiek bereikbaar | P1-01, P1-02 | handmatig | open |
| T3 | Fail-closed beheerlaag (`admin_cidr`) | P1-02 | geautomatiseerd + handmatig | ✅ geautomatiseerd |
| T4 | Cross-VPC DNS: NGINX-paneel blijft leeg | P1-05 | handmatig | ⚠️ bekende beperking |
| T5 | `mysqld_exporter` als alternatief voor CloudWatch RDS | P1-05 | handmatig | optioneel |
| T6 | Notificatiepad: alarm → SNS → mailbox (incl. blue/green) | P1-05, P1-04 | handmatig | open |
| T7 | Self-hosted runner inschakelen | P1-07 | handmatig | optioneel |
| T8 | Autoscaling onder belasting | P1-04, P1-05 | handmatig | open |
| T9 | Blue/green-deployment en rollback | P1-04 | handmatig | open |
| T10 | State-locking werkt | P1-06 | handmatig | open |
| T11 | CI-credentials: juiste IAM-user, geen OIDC-restanten | P1-07 | geautomatiseerd | ✅ |
| T12 | Git-repo als enige bron van waarheid | P1-08 | geautomatiseerd | ✅ |
| T13 | Eerste `terraform apply` in echt AWS | P1-01 t/m P1-08 | handmatig | ⚠️ gedeeltelijk |

---

## T0 — Eenmalige lokale setup

De backend in `main.tf` heeft `use_lockfile = true` gekregen om aan
REQ-NCA-P1-06 te voldoen. Een bestaande lokale `.terraform/`-map kent die
instelling nog niet, waardoor élk terraform-commando lokaal faalt met:

```
Error: Backend initialization required
Reason: Backend configuration block has changed
```

**Actie:**

```bash
terraform init -reconfigure
```

**Verwacht:** `Terraform has been successfully initialized!`

Dit is eenmalig. Op CI is elke runner schoon, dus daar is een gewone
`terraform init` voldoende en daarom is de workflow hier niet op aangepast.

**Bewijs:** de output van dit commando.

---

## T1 — Statische controles (geautomatiseerd)

Dit is de test die de meeste waarde heeft voor het bewijs: hij controleert 25
concrete uitspraken over de configuratie, zonder iets in AWS te doen.

**Actie:**

```bash
terraform fmt -check -recursive
terraform validate
terraform test -no-color
```

**Verwacht:**

```
Success! The configuration is valid.
...
Success! 25 passed, 0 failed.
```

**Wat wordt er precies gecontroleerd** (bestand per bestand):

`tests/security.tftest.hcl`
- geen enkele security group staat open op `0.0.0.0/0` of `::/0`, behalve de ALB
- de ALB opent uitsluitend 80 en 443
- `web_sg` verwijst naar de security group van de ALB (conforme ontwerpdocument)
- `web_sg` opent alleen 80 en 9113 — geen databasepoort
- `db_sg` opent alleen 3306 (de dode 9104-regel is weg)
- RDS draait op `publicly_accessible = false`
- met de standaard (lege) `admin_cidr` zijn er **nul** ingress-regels op de
  monitoring-instance
- met een gezette `admin_cidr` zijn het er precies drie, allemaal voor dat ene
  CIDR
- `admin_cidr = "0.0.0.0/0"` wordt **geweigerd** door de variabele-validatie

`tests/application.tftest.hcl`
- wachtwoorden lopen via Secrets Manager (`secrets`), niet als environment-
  variabele met "password" in de naam
- `DB_HOST` staat in de taakdefinitie en komt uit de RDS-resource
- `network_mode = "awsvpc"`, `deployment_controller = CODE_DEPLOY`,
  geen publiek IP op de taken
- Container Insights staat aan (anders werkt de geheugenmetriek niet)
- minimaal 2 taken, in 2 verschillende subnetten (2 AZ's)
- autoscaling: min 2, max gelijk aan `var.max_task_count`, +2 bij opschalen
  en −2 bij afschalen
- listener en service geven `default_action`, `task_definition` en
  `load_balancer` vrij aan CodeDeploy
- blue en green zijn verschillende target groups, beide met `/healthz`
- `task-definition.json` bevat geen hardcoded database-adres meer

`tests/observability.tftest.hcl`
- het dashboard heeft 7 panelen: 6 op CloudWatch met precies de vier drempels
  uit het ontwerpdocument (70% CPU, 80% geheugen, 500ms, 85% DB-CPU) en 1 op
  Prometheus
- alle alarms hangen aan dezelfde SNS-topic
- de vier kritieke alarms hebben `evaluation_periods = 1` (notificatie binnen
  1 minuut, zoals het acceptatiecriterium vraagt)
- de 5xx-alarm rekent een **percentage** uit, geen absoluut aantal
- de drempels in de alarms zijn gelijk aan die in het dashboard
- het HA-alarm heeft geen `TargetGroup`-dimension, zodat het een blue/green-
  switch overleeft
- de backend gebruikt `use_lockfile = true` en de bucket komt overeen met die
  in de documentatie
- de workflow leest de AWS-sleutels uit de GitHub-secrets, bevat geen
  `role-to-assume` en geen token-permissie meer, controleert dat hij als IAM-user
  `github-actions-deploy` inlogt, en slaat PR's uit een fork over
- de runner draait zonder publiek IP in het management-subnet
- de workflow haalt zijn namen uit `terraform output` en bevat geen
  hardcoded clusternaam of servicenaam
- de workflow draait `terraform test` en `terraform fmt -check` voor de deploy

**Bewijs:** de volledige `terraform test`-output, of de groene pipeline-run.

---

## T2 — Netwerkisolatie (uit het ontwerpdocument)

**Doel:** bewijzen dat de database vanaf het internet niet bereikbaar is.

**Actie**, vanaf een machine buiten de VPC:

```bash
mysql -h "$(terraform output -raw database_endpoint)" -u dbadmin -p
```

of, nog overtuigender, rechtstreeks op IP-niveau:

```bash
nc -vz <endpoint> 3306
```

**Verwacht:** timeout, connection refused, of de hostname lost niet op buiten
de VPC. Nadrukkelijk **geen** login-prompt.

**Waarom het werkt:**
- `aws_db_instance.mariadb` staat op `publicly_accessible = false` (getest in T1)
- de instance zit in de private data-subnetten, met een route table zonder
  internetroute
- `db_sg` accepteert alleen 3306 en alleen vanaf de `web_sg` of het CIDR
  `10.1.0.0/16`

**Bewijs:** terminal-output met de timeout. Doe dit vanaf een netwerk dat
echt niet in je VPC zit (thuisverbinding, niet de TU/eigen bastion).

---

## T3 — Fail-closed beheerlaag

**Doel:** bewijzen dat de Prometheus/Grafana-instance met een publiek IP
standaard *niet* vanaf het internet bereikbaar is.

Deel A — geautomatiseerd (T1): de test
`zonder_admin_cidr_is_er_geen_enkele_ingress_op_de_monitoring_instance`
doet precies dit en slaagt.

Deel B — handmatig, in de echte omgeving:

```bash
# 1. Staat er een publiek IP op de instance?
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=monitoring-prometheus-grafana" \
  --query 'Reservations[].Instances[].PublicIpAddress' --output text

# 2. Kun je van buiten verbinden? Dit moet time-outen.
nc -vz <publiek-ip> 3000
nc -vz <publiek-ip> 9090
```

**Verwacht:** stap 1 geeft een IP, stap 2 geeft een timeout. Toch bereikbaar?
Dan is er ergens een regel toegevoegd die hier niet hoort.

Deel C — de regel wordt pas toegevoegd als je er bewust om vraagt:

```bash
terraform apply -var 'admin_cidr=x.x.x.x/32'
```

Vul hier je **eigen** IP in (zie <https://whatismyip.com>). Daarna werken
poort 3000 (Grafana) en 9090 (Prometheus) wél, en alleen vanaf dat ene adres.

**Waarom `0.0.0.0/0` geweigerd wordt:** Prometheus heeft geen
authenticatie. Iemand die het publieke IP van de instance gokt zou anders de
volledige metrieken van het platform zien. Een variabele-validatie weigert die
waarde met een expliciete foutmelding; dat is beter dan een configuratie die
publiek is zonder dat iemand het ziet.

**Bewijs:** de timeout-output, en de output van
`terraform apply -var 'admin_cidr=...'`.

---

## T4 — Cross-VPC DNS: het NGINX-paneel blijft leeg (bekende beperking)

**Doel:** uitleggen waarom paneel 7 van het dashboard ("NGINX requests") leeg
blijft, en aangeven wat er nodig is om het te vullen.

**Diagnose**, via SSM Session Manager op de monitoring-instance:

```bash
aws ssm start-session --target-id <instance-id>

# Op de instance:
docker exec -it <prometheus-container> \
  promtool check config /etc/prometheus/prometheus.yml

curl -s 'http://localhost:9090/api/v1/targets?state=active' | jq '.data.activeTargets[] | {job: .labels.job, health, error}'
```

**Verwacht:** job `nginx-web` staat op `health: "unknown"` met een fout als
`no such host`.

**Oorzaak:** de ECS-taken registreren zich bij Cloud Map in de private zone
`web.internal.local`, en die zone is gekoppeld aan de Spoke-Web VPC. Prometheus
draait in de Hub-VPC. Private DNS tussen twee VPC's werkt via een Transit
Gateway **alleen** als er een Route 53 Resolver Inbound Endpoint in de
resolving-VPC staat; anders ziet de Hub-VPC-resolver die zone niet.

**Waarom het hier zo is gelaten:** de zes verplichte panelen draaien op
CloudWatch en werken wél. Ze zouden afhankelijk zijn van een DNS-feature die
extra resources kost en een subnet-gateway in een andere VPC vereist. Het
dashboard zou anders bij het grootste deel leeg zijn.

**Oplossing als je het paneel echt wilt:**

1. Maak een Route 53 Resolver Inbound Endpoint in de Hub-VPC op poort 53.
2. Koppel die aan de Inbound Resolver van de Spoke-Web-VPC.
3. Voeg aan het subnet van de Hub-VPC een subnet route table toe die het
   endpoint bereikbaar maakt.

Het paneel in het dashboard hoeft niet te veranderen: de job
`nginx-web` staat er al.

**Bewijs:** de `api/v1/targets`-output. Dit is een gedocumenteerde
afwijking, geen defect — maar het hoort wel in het verslag.

---

## T5 — `mysqld_exporter` (optioneel)

Het ontwerpdocument noemde poort 9104 "voor mysqld_exporter". Die exporter
werd nergens gerenderd en Prometheus scant de database niet, dus de regel deed
niets. Ze is uit `db_sg` verwijderd: een security group hoort geen dode poorten
te openen. DB-metrieken komen nu uit CloudWatch RDS (CPU) en het dashboard.

Wil je toch een echte exporter, dan:

1. Voeg een sidecar-container toe aan de taakdefinitie in `compute.tf`
   (`percona/mysqld_exporter`, met de DB-credentials uit Secrets Manager).
2. Zet een scrape-job in `prometheus.yml` in `monitoring.tf` op poort 9104.
3. Heropen poort 9104 in `db_sg` — vanaf het CIDR van het management-subnet,
   niet vanaf `0.0.0.0/0`.
4. Voeg een dashboard-paneel toe met de metrics die je wilt volgen.

Let op: de Prometheus-container zit in een andere VPC dan de database, dus
dezelfde DNS-beperking als bij T4 geldt. De CloudWatch-RDS-metrieken zijn daarom
de simpelere route.

---

## T6 — Notificatiepad end-to-end

**Doel:** bewijzen dat een overschrijding van een kritieke drempel binnen
één minuut een notificatie oplevert (het acceptatiecriterium van REQ-NCA-P1-05).

**Aanmelden** (eenmalig, anders blijven de alarms staan op INSUFFICIENT_DATA):

```bash
terraform apply -var 'alert_email=jij@voorbeeld.nl'
```

Je krijgt een bevestigingsmail van AWS SNS. Klik de link; daarna volgen de
alarmmeldingen.

**Alarm handmatig afgaan** — bijvoorbeeld de 5xx-alarm, door de
`default.conf` tijdelijk te saboteren:

```bash
# Vanaf de laptop, ter illustratie van wat de ALB ziet:
for i in $(seq 1 20); do
  curl -s -o /dev/null -w "%{http_code}\n" http://$(terraform output -raw alb_dns_name)/kapot
done
```

Of, betrouwbaarder, stel het alarm handmatig op ALARM:

```bash
aws cloudwatch set-alarm-state \
  --alarm-name alb-target-response-time-high \
  --state-value ALARM \
  --state-reason "Test T6"
```

**Verwacht binnen 60 seconden:**
- de alarm gaat van `OK` naar `INSUFFICIENT_DATA`/`ALARM`
- je ontvangt een mail via `nca-infra-alerts`
- zet je hem terug op `OK`, dan volgt een tweede mail (`ok_actions`)

**Waarom CloudWatch-alarms en niet Grafana Alerting:** ze hebben geen SMTP of
relay nodig, ze overleven een reboot van de monitoring-instance, en ze sluiten
aan op precies dezelfde metrieken als het dashboard. `tests/observability.tftest.hcl`
controleert dat die drempels gelijk zijn, zodat ze niet uit elkaar kunnen lopen.

**Let op — de latency- en DB-CPU-drempel:** het ontwerpdocument noemt daar
"gemiddeld over 3 minuten" en "gedurende 5 minuten". Het acceptatiecriterium
eist echter een notificatie binnen 1 minuut. Ik heb de strengere eis aangehouden
(`evaluation_periods = 1`) en de reden in `alarms.tf` genoteerd. Het gevolg is
dat een korte uitschieter eerder een melding geeft.

**Blue/green-controle:** draai eerst T9. Het HA-alarm
(`alb-healthy-hosts-below-minimum`) telt met `stat = "Minimum"` over *alle*
target groups van de ALB. Na een verkeersshift meet het dus niet de group die
net toevallig leeg staat, maar het zwakste van alle — wat blijft kloppen met de
HA-eis.

**Bewijs:** de alarmstatus in CloudWatch, plus de ontvangen mail.

---

## T7 — Self-hosted runner inschakelen (optioneel)

REQ-NCA-P1-07 noemt een self-hosted runner binnen de eigen netwerkgrenzen.
`runner.tf` bouwt die volledig op — EC2 in het management-subnet, zonder
publiek IP, met een IAM-rol en CloudWatch Logs — maar `var.enable_self_hosted_runner`
staat standaard op `false`.

**Waarom uit:** een workflow met `runs-on: [self-hosted, linux]` blijft hangen
op *"Waiting for a runner"* zolang die runner niet geregistreerd is, en dan
valt ook de `terraform apply` stil die de runner zou aanmaken. Vastlopen is
lastiger dan een keer handmatig inschakelen.

**Actie:**

```bash
# 1. Registratietoken ophalen (1 uur geldig)
TOKEN=$(gh api -X POST repos/:OWNER/:REPO/actions/runners/registration-token \
  --jq .token)

# 2. Aan Terraform geven
aws ssm put-parameter \
  --name /github-actions/runner/registration-token \
  --value "$TOKEN" --type SecureString --overwrite

# 3. Runner aanmaken
terraform apply -var 'enable_self_hosted_runner=true'

# 4. Controleer of hij online is
gh api repos/:OWNER/:REPO/actions/runners
```

**Verwacht:** één runner met status `online`, met de labels `nca` en `runner`.
Zet daarna in `.github/workflows/deploy.yml` `runs-on: [self-hosted, linux]`
voor de `deploy`-job.

**Let op bij het omzeten van `runs-on`:** de pipeline logt nu in met
AWS-sleutels uit GitHub Secrets (zie T11). Die blijven werken op de
self-hosted runner, dus het omzetten van `runs-on` op zichzelf is genoeg. Wil
je in plaats daarvan de instance-profielrol gebruiken, dan moet de
IAM-user `github-actions-deploy` `iam:PassRole` op
`nca-github-runner-role` krijgen — anders heeft de taak geen AWS-credentials.

**Terugdraaien:**

```bash
terraform apply -var 'enable_self_hosted_runner=false'
```

**Bewijs:** de `gh api`-output met `status: "online"`, plus een geslaagde run
waarin je in de GitHub-UI ziet dat de taak op de eigen runner draaide.

---

## T8 — Autoscaling onder belasting (uit het ontwerpdocument)

**Doel:** bewijzen dat het systeem opschaalt bij >70% CPU en afschaalt onder 20%.

**Actie:**

```bash
# Vanaf je laptop, gericht op de ALB
vegeta attack -c 200 -d 10m http://$(terraform output -raw alb_dns_name)/ | \
  tee vegeta-report.txt
```

Of met `ab`:

```bash
ab -n 1000000 -c 200 http://$(terraform output -raw alb_dns_name)/
```

**Verwacht, in deze volgorde:**

1. ECS CPU (paneel 1 in het dashboard) gaat boven 70%.
2. Het alarm `ecs-cpu-high` gaat af (5 evaluatieperiodes van 60 s = 5 minuten).
3. Het aantal taken loopt op met +2 per stap, tot `max_task_count` (standaard 4).
4. Er blijven geen 5xx-fouten boven 1% (paneel 6).
5. Je ontvangt een mail via de SNS-topic.
6. Onder 20% gedurende 10 minuten schaalt het systeem terug naar 2 taken.

**Twee dingen om vooraf te weten:**

- De TCO-analyse gaat uit van een **piek van 10 taken**, terwijl
  `max_task_count` op **4** staat. Bij een echte piek van 10 taken is 4 dus
  te laag. Zet `-var 'max_task_count=10'` als je dat wilt testen, en werk het
  ontwerpdocument bij.
- De sandbox-SCP (AWS Free Tier) kan niet schalen naar 10 Fargate-taken zonder
  een quota-aanvraag. Vraag die aan voordat je deze test herhaalt.

**Bewijs:** een screenshot van het dashboard met de CPU-grafiek en het
aantal taken, plus de vegeta-output zonder 5xx-fouten.

---

## T9 — Blue/green-deployment en rollback

**Actie:** push een commit naar `main` en kijk naar de pipeline. Of lokaal:

```bash
echo "<!-- $(date) -->" >> default.conf
git add default.conf && git commit -m "test T9"
git push
```

**Verwacht:**
1. Docker build + push naar ECR (tag op commit-SHA én `latest`).
2. De taakdefinitie krijgt een nieuwe revisie met de nieuwe image, en met
   `DB_HOST` uit de Terraform-output.
3. CodeDeploy zet **green** op naast **blue** en wacht op de health check
   (`/healthz`, twee successen à 5 s).
4. De ALB schakelt het verkeer om: je ziet dat paneel 5 van het dashboard
   (Healthy hosts) stabiel blijft.
5. De pipeline eindigt met de bevestiging dat de site HTTP 200 teruggeeft.

**Rollback testen** — de belangrijkste belofte van blue/green:

Pauzeer de deployment in de AWS-console (of: zet in `appspec.yaml` bewust een
foute opdracht neer), zodat de verkeersshift uitblijft. Het verkeer blijft dan
op de oude, werkende versie: nul downtime, geen gebruikersimpact. Zet daarna de
deployment af — binnen vijf seconden is de verkeersstroom terug op blue.

**Waarom de listener niet terugveert:** de listener en de ECS-service hebben
`ignore_changes` op respectievelijk `default_action` en
`task_definition`/`load_balancer`. Zonder die zou elke `terraform apply` de
verkeersshift ongedaan maken. `tests/application.tftest.hcl` controleert dat
deze regels aanwezig zijn.

**Bewijs:** de pipeline-run met groene vinkjes, plus een screenshot van de
CodeDeploy-deployment met de verkeersshift.

---

## T10 — State-locking

**Doel:** bewijzen dat twee gelijktijdige runs elkaar niet in de weg zitten.

**Actie 1 — de lockfile bestaat tijdens een run.** Start lokaal een
`terraform plan -lock-timeout=0` en onderbreek hem halverwege
(`Ctrl+C`). Kijk dan vanuit een tweede terminal:

```bash
aws s3 ls s3://tfstate-eu-west-1-491799435972/terraform/
```

**Verwacht:** er staat een `.tflock`-bestand. Na het afbreken verdwijnt het
weer; een verouderd lock-bestand ruim je op met
`terraform force-unlock <LOCK_ID>`.

**Actie 2 — een tweede run wacht.** Start in twee terminals tegelijk
`terraform plan -lock-timeout=60`.

**Verwacht:** de tweede wacht met
`Error acquiring the state lock` en geeft na 60 seconden op. De eerste gaat
gewoon door.

**Waarom `use_lockfile` en geen DynamoDB-tabel:** het S3-native mechanisme
(Terraform ≥ 1.10) doet hetzelfde zonder extra tabel, zonder extra kosten en
zonder het kip-een-probleem waarbij de tabel nog aangemaakt moet zijn vóór de
eerste `terraform init`. Wil je toch DynamoDB, zet `use_lockfile = false` en
vul `dynamodb_table` in — en maak die tabel dan vóór de eerste init aan.

**Bewijs:** de twee terminal-sessies naast elkaar.

---

## T11 — CI-credentials: juiste IAM-user, geen OIDC-restanten

**Geautomatiseerd.** `tests/observability.tftest.hcl` bevat de run
`de_pipeline_logt_in_met_aws_sleutels_uit_github_secrets`. Die controleert dat
de workflow:

- `AWS_ACCESS_KEY_ID` en `AWS_SECRET_ACCESS_KEY` uit de GitHub-secrets leest
- nergens meer `role-to-assume` gebruikt (de OIDC-rol bestaat niet meer, dus
  dat zou een job met `AccessDenied` opleveren)
- nergens meer een token-permissie aanvraagt
- met `aws sts get-caller-identity` controleert dat hij als IAM-user
  `github-actions-deploy` inlogt, en hard faalt bij een andere identiteit
- PR's uit een fork over slaat, want daar deelt GitHub geen secrets

**Verwacht:** in GitHub staan precies twee secrets, `AWS_ACCESS_KEY_ID` en
`AWS_SECRET_ACCESS_KEY`, van de IAM-user `github-actions-deploy`; en de
pipeline-run is groen.

**Bewijs:** de groene testregel, plus de stap "Controleer dat we als de
CI-gebruiker binnenkomen" met de regel `OK: de CI-gebruiker`.

### Wat hier bewust minder sterk is dan met OIDC

Met OIDC zat de scheiding tussen plan en deploy in de trust policy: de
plan-job nam een read-only rol over, de deploy-job een rol met
schrijfrechten, en beide alleen vanaf een push naar `main`. Een pull request
kon daardoor nooit deployen.

Met statische sleutels is die laag weg. De plan-job draait met dezelfde sleutel
als de deploy-job, dus een pull request binnen deze repo draait met
schrijfrechten. Twee dingen beperken de schade:

1. GitHub deelt geen secrets met een pull request uit een **fork**. Daarom
   overslaat de plan-job die expliciet, in plaats van te breken.
2. Zet de secrets op een **GitHub Environment** met een verplichte
   goedkeurder. Dan is een release een beslissing van een mens en niet van
   een push. Zie README.md, "De AWS-credentials voor CI".

Wil je de oude grens terug, dan is OIDC de weg - de policies hiervoor staan in
de git-historie (`git show 93a1ae3:oidc.tf`).

## T12 — Git-repo als enige bron van waarheid

**Geautomatiseerd.** `tests/observability.tftest.hcl` controleert dat de
workflow alle namen haalt met `terraform output -raw <naam>`:

```
ecs_cluster_name, ecs_service_name, codedeploy_app_name,
codedeploy_deployment_group_name, ecr_repository_url, database_endpoint
```

en dat er geen `production-ecs-cluster` of `nginx-service` als hardcoded
string in de workflow staat. Hetzelfde geldt voor `task-definition.json`, dat
nu `SET_BY_PIPELINE_FROM_TERRAFORM_OUTPUT` bevat in plaats van een echt
database-adres.

**Waarom dit een echte bug was:** eerder stonden deze namen op twee plekken.
Wie een service hernoemde, kreeg een pipeline die stil naar de oude naam
deployde — zonder foutmelding, en dus zonder dat je het merkte.

**Bewijs:** de groene testregels, of de stap
"Haal de resourcenamen uit de Terraform-output" in de pipeline-run.

---

## T13 — De eerste `terraform apply` in echt AWS

Deze test is toegevoegd nadat de eerste echte apply op 2026-09-29 liep. `terraform
validate` en `terraform test` bewijzen dat de *code* klopt, maar ze raken AWS
niet aan. Juist een apply is een andere tak van de boom, en die vond drie dingen
die geen enkele statische controle had kunnen vinden.

### Wat er is gebeurd

De eerste apply is tweemaal gestart. De eerste ronde faalde op `web_sg`, de
tweede op de vier interface-VPC-endpoints.

| Resource | Uitkomst |
|---|---|
| 5 CloudWatch-alarms | ✅ aangemaakt |
| SNS-topic + e-mailabonnement | ✅ aangemaakt |
| `iam_role_policy.monitoring_ssm` | ✅ aangemaakt |
| `aws_instance.monitoring` | ✅ opnieuw gebouwd (`i-01be6b6180398f295`) — enige reden: nieuwere AL2023-AMI |
| `web_sg`, `db_sg` | ✅ in-place bijgewerkt |
| `spoke_endpoints_sg` + S3-gateway-endpoint | ✅ aangemaakt |
| 4 interface-endpoints (ECR, Logs, Secrets Manager) | ⚠️ blijven 10+ minuten in `pending`; apply faalt op de provider-timeout |
| `aws_db_instance.mariadb` | ✅ **niet aangeraakt** — zie T13.2 |

### T13.1 — Een security-group-referentie over een VPC-grens

Foutmelding:

```
Error: updating Security Group (sg-07d05992fd1641166) ingress rules:
  api error InvalidGroup.NotFound: You have specified two resources
  that belong to different networks.
```

**Oorzaak.** `web_sg` (in `spoke_web`) had een ingress-regel met
`security_groups = [aws_security_group.alb_sg.id]` — en `alb_sg` zit in de
Hub-VPC. AWS accepteert een security-group-referentie uitsluitend binnen dezelfde
VPC; peering geeft losse routes en géén gedeelde security groups.

Het ontwerpdocument schrijft die referentie voor. Dat is niet uitvoerbaar in deze
topologie, en het is dus een afwijking van het ontwerpdocument en geen bug in de
implementatie.

**Opgelost** door de CIDR's van de Hub-publieke subnets te gebruiken, wat
functioneel gelijkwaardig is: een ALB met `target_type = ip` bewaart het
client-IP, dus de pakketten arriveren met het IP van de eindgebruiker als bron.
`db_sg` had dezelfde fout met `web_sg` en is op dezelfde manier rechtgezet.

**Belangrijk voor de toetsing:** dit was een fout die ik zelf had
geintroduceerd, en die `terraform test` wél had kunnen vinden als er een test was
geweest die de VPC-echtheid controleerde. Er staat nu een assertion in
`tests/security.tftest.hcl` die elke `security_groups`-verwijzing als fout aanmerkt
— bewust conservatief, want elke cross-VPC-verwijzing is onmogelijk in deze
topologie.

### T13.2 — Een `description` die de database bijna raakte

Het plan bevatte `aws_security_group.db_sg: must be replaced`, veroorzaakt door
een door mij herschreven `description`. Dat is `ForceNew` in de AWS-provider. De
ketenreactie was:

1. `db_sg` wordt vervangen;
2. daardoor wordt `db_sg.id` `unknown` tijdens het plannen;
3. daardoor wordt `vpc_security_group_ids` van de **draaiende RDS-instance**
   `unknown`;
4. de database zou dus een onbedoelde in-place wijziging krijgen.

Stap 1 zou bovendien zelf zijn mislukt: AWS weigert een security group te
verwijderen die aan een ENI hangt (`InvalidGroup.InUse`), dus de apply zou
halverwege klappen — precies bij de database.

**Opgelost** door de originele `description`-teksten terug te zetten en in
`security.tf` uit te leggen waarom ze daar bewust achterhaald blijven staan. De
dode poort 9104 verdwijnt daarmee wél gewoon, in-place; dat is in het plan
bevestigd. De RDS-instance staat in het eindplan helemaal niet meer.

### T13.3 — De vier interface-VPC-endpoints blijven pending

```
Error: waiting for EC2 VPC Endpoint (com.amazonaws.eu-west-1.logs) create:
  timeout while waiting for state to become 'available, pendingacceptance'
  (last state: 'pending', timeout: 10m0s)
```

Alle vier tegelijk, en de S3-gateway-endpoint in hetzelfde plan werd wél meteen
beschikbaar. Dat wijst op de aanlegstap van interface-endpoints, niet op een fout
in de configuratie.

Dit is **niet** een kwestie van "weglaten": volgens de toelichting bovenin
`endpoints.tf` blijven de ECS-taken zonder deze endpoints 4+ minuten op `PENDING`
staan en sterven ze met *"connection issue between the task and Amazon
CloudWatch"*. Ze zijn dus noodzakelijk, niet overbodig.

Als tussenstap is de timeout verhoogd van de provider-default van 10 minuten naar
30 (`timeouts { create = "30m" }`). Dat is een ruimer venster, geen bewezen
oplossing — als ze na 30 minuten nog pending staan is de oorzaak anders.

**Diagnose-stappen zodra er weer credentials zijn:**

```bash
# 1. Wat zegt AWS nu? Zijn ze inmiddels beschikbaar geworden?
aws ec2 describe-vpc-endpoints \
  --filters Name=vpc-id,Values=vpc-0f1364066e56edd87 \
  --query 'VpcEndpoints[].{Svc:ServiceName,State:State,Subnets:SubnetIds}'

# 2. Klopt de time? Let op: --start-time is lokale tijd.
aws ec2 describe-vpc-endpoints \
  --filters Name=vpc-id,Values=vpc-0f1364066e56edd87 \
  --query 'VpcEndpoints[].{Created:CreationTimestamp}' \
  --output text

# 3. Zijn de subnetten vol? Vier endpoints over twee subnetten is acht ENI's.
aws ec2 describe-subnets \
  --subnet-ids subnet-03de7890b5c1237cc subnet-05996ea254f8058bb \
  --query 'Subnets[].{Id:SubnetId,Free:AvailableIpAddressCount}'

# 4. Zit er een quota in de weg?
aws service-quotas get-service-quota --service-code vpc --quota-code L-13B15B8B
```

Waarschijnlijkste verklaringen, in volgorde: Transit Gateway in de VPC (bekend
lang aanlegtraject), subnet zonder vrije IP-adressen, of een quota.

**Tijdelijke terugvaloptie** als ze echt niet beschikbaar worden: zet
`enable_spoke_endpoints = false`. Dat is echter geen fix — dan staan de taken weer
op het pad dat hierboven is beschreven als kapot. Liever niet, en dan zeker pas
nadat T8 (autoscaling onder belasting) aantoont dat taken daadwerkelijk opkomen.

### T13.4 — Een state-lock die vast bleef zitten

Tijdens het debuggen werd een `terraform plan` door een PowerShell-pipeline
voortijdig afgebroken. Daardoor bleef de lockfile in S3 achter en weigerde de
volgende run:

```
Error: Error acquiring the state lock
  api error PreconditionFailed: At least one of the pre-conditions you specified did not hold
```

Opgeruimd met `terraform force-unlock <id>` nadat was gecontroleerd dat er geen
`terraform`-proces meer draaide. Er was geen schade: de lock deed precies wat hij
moest doen.

Dit is ook het praktische bewijs voor REQ-NCA-P1-06 — zie T10. De les voor het
verslag: een pipeline die een terraform-proces voortijdig afbreekt laat een
state-lock achter; controleer altijd of er nog een proces loopt vóór je force-unlock
gebruikt.

---

## Wat bewust níet is aangepast

| Onderwerp | Afwijking | Waarom |
|---|---|---|
| ECR `image_tag_mutability` | blijft `MUTABLE` | De pipeline pusht ook `:latest`. `IMMUTABLE` zou die push breken. Een sha-tag erbij zetten werkt wel. |
| HTTPS / ACM / WAF | niet toegevoegd | De ALB luistert op HTTP. Een certificaat vraagt een domeinnaam en DNS; dat valt buiten de scope. De ALB-SG houdt 443 wel vrij, zodat het later kan. |
| Cross-VPC DNS (T4) | niet opgezet | Vereist een Route 53 Resolver Inbound Endpoint in een andere VPC. Zie T4. |
| `max_task_count` | 4, terwijl de TCO-analyse 10 noemt | Zie T8. Zet de variabele omhoog als de loadtest dat vraagt. |
| Database-instance | `db.t3.micro`, TCO noemt `db.t4g.micro` | Werk de TCO-analyse bij, of verhoog de instance. Beide veranderen de kostenberekening. |
| Self-hosted runner | staat uit | Zie T7. |
| OIDC in de pipeline | verwijderd | De pipeline logt nu in met AWS-sleutels uit GitHub Secrets. Gevolg: de plan-job is niet meer read-only. Fork-PR's worden overgeslagen, en een GitHub Environment met verplichte goedkeurder sluit de kwalijk aan. Zie T11. |
| Verwijzingen tussen security groups | overal CIDR, geen SG-referentie | Het ontwerpdocument schrijft een SG-referentie voor, maar de ALB en de database zitten in een andere VPC dan de ECS-taken. AWSweigert dat met `InvalidGroup.NotFound`. Zie T13.1. |
| `description` van `db_sg` en `mgmt_sg` | bewust achterhaald | `description` is `ForceNew`; wijzigen zou een groep vervangen die aan een draaiende RDS/EC2-resource hangt. Zie T13.2. |

---

## Bewijsmateriaal verzamelen

Voor het verslag zijn deze zeven dingen genoeg:

1. `terraform fmt -check -recursive` → geen output
2. `terraform validate` → `Success! The configuration is valid.`
3. `terraform test` → `Success! 25 passed, 0 failed.`
4. Een geslaagde pipeline-run (GitHub → Actions → de groene run)
5. T2: de timeout vanaf een extern netwerk
6. T6: de ontvangen alarmmail
7. Een dashboard-screenshot met de vier drempelgrafieken
