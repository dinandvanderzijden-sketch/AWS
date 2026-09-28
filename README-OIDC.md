# AWS-toegang voor GitHub Actions via OIDC (geen access keys)

## Wat verandert er

Voorheen stonden er drie secrets in GitHub die je telkens moest invullen/rotaten:

```
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
AWS_SESSION_TOKEN
```

Die zijn lang geldig. Wie ze eenmaal had, had daarmee blijvend toegang tot je
account, ook als de repo later per ongeluk openbaar werd.

Nu levert **GitHub Actions** zelf een **kortlopend OIDC-token** af, en
`aws-actions/configure-aws-credentials` ruilt dat in voor tijdelijke
credentials via `sts:AssumeRoleWithWebIdentity`. Er is geen key meer die je
hoeft op te slaan, in te vullen of te roleren. Elk token is ~5 minuten geldig.

## Volgorde: dit MOET in deze volgorde

Er zit een kip-een-probleem in. De OIDC-provider en de rollen moeten in AWS
bestaan *voordat* de workflow ze kan gebruiken. Je kunt de eerste keer dus nog
niet via OIDC deployen.

### Stap 1 — eenmalig lokaal apply'en

Met je lokale AWS-credentials (of nog met je oude keys):

```powershell
terraform init
terraform plan -out=oidc.tfplan
terraform apply oidc.tfplan
```

Haal daarna de role-ARN's op:

```powershell
terraform output github_actions_plan_role_arn
terraform output github_actions_deploy_role_arn
```

### Stap 2 — ARN's in de workflow zetten

In `.github/workflows/deploy.yml` staan nu hardcoded:

```yaml
role-to-assume: arn:aws:iam::491799435972:role/github-actions-plan
role-to-assume: arn:aws:iam::491799435972:role/github-actions-deploy
```

Vervang het account-ID als dat niet `491799435972` is. Dit kan handiger met een
repository-variable (`vars.AWS_ACCOUNT_ID`), maar dan moet die vóór stap 1
al bestaan.

### Stap 3 — de secrets verwijderen

In GitHub: **Settings → Secrets and variables → Actions** → verwijder
`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` en `AWS_SESSION_TOKEN`.

De workflow verwijst er niet meer naar, dus ze worden genegeerd. Verwijderen is
puur voor de veiligheid: als er ooit per ongeluk een key terugkomt, is de rol
alsnog de enige deur.

### Stap 4 — testen

Push iets naar `main`. De job "Validate & Plan (read-only)" moet groen worden,
gevolgd door "Deploy Infrastructure & Application".

## Twee rollen, twee deuren

| Rol | Wie 'm mag overnemen | Wat 'm mag |
|---|---|---|
| `github-actions-plan` | push naar `main`, **en** elk pull request | alleen lezen |
| `github-actions-deploy` | **alleen** push naar `main` | aanmaken, wijzigen, verwijderen |

De beveiliging zit volledig in de *trust policy* van de rollen. GitHub stuurt
een `sub`-claim mee, en die wordt exact vergeleken. Let op de **numerieke
IDs**: GitHub gebruikt niet `repo:owner/repo`, maar
`repo:<owner>@<owner_id>/<repo>@<repo_id>`. Vergelijken op IDs is veiliger dan
op namen, want een repo kan hernoemd worden en een ID niet.

```
repo:dinandvanderzijden-sketch@229950911/AWS@1372748269:ref:refs/heads/main
  -> mag deployen
repo:dinandvanderzijden-sketch@229950911/AWS@1372748269:pull_request
  -> mag alleen lezen
```

De IDs staan in `variables.tf` (`github_owner_id`, `github_repo_id`); de
samengestelde strings in `locals.github_sub_branch` en `locals.github_sub_pr`
in `oidc.tf`. Ze staan op `https://api.github.com/users/<owner>` en
`https://api.github.com/repos/<owner>/<repo>`.

Verandert GitHub dit formaat ooit, dan faalt de inlog met
`Not authorized to perform sts:AssumeRoleWithWebIdentity`. De stap
"Toon de OIDC-claims" in de workflow print de werkelijke claims, dus dan
zie je meteen wat er moet worden aangepast.

Iemand die alleen pull-rechten heeft op de repo kan dus `main` **niet**
misbruiken. En een pull request uit een fork krijgt de read-only rol, waar
geen enkele schrijfactie in zit.

Wil je de pull-request-route helemaal dicht, zet dan in `variables.tf`:

```hcl
variable "enable_pr_plan_role" {
  default = false
}
```

## Wat de deploy-role precies mag

Gewoon `PowerUserAccess` (alles behalve IAM en account-administratie) plus een
klein eigen policy-bestand voor de twee dingen die PowerUserAccess niet doet:

- **IAM-beheer** — deze stack maakt zelf rollen aan
  (`ecs_execution_role`, `ecs_task_role`, `monitoring`, `codedeploy_role`).
- **S3 op de state-bucket** — zonder dit kan `terraform init` de backend niet
  eens openen.

`iam:PassRole` is bewust beperkt tot de vier rollen in deze stack, dus de rol kan
zichzelf niet promotie geven.

**Bekende beperking:** `iam:CreateRole` is niet op resource-niveau te scopen
(die actie kent nog geen resource-ARN). Die staat daarom op `*`. Dat is een
limiet van IAM zelf, geen shortcut. Wie de deploy-role kan nemen, kan in
principe een extra rol aanmaken. De trust policy houdt de deur dicht; de
permissies erachter zijn dat niet.

## Aandachtspunten die ik heb gezien maar niet heb aangeraakt

1. **`.github/deploy.yml` is een dubbele, dode workflow.** Hij staat buiten
   `.github/workflows/`, dus GitHub voert hem nooit uit, maar hij bevat nog de
   oude key-referenties. Aanbeveling: verwijder het bestand.

2. **Geen state-locking.** De S3-backend in `main.tf` heeft geen
   `use_lockfile` of DynamoDB-tabel. Twee gelijktijdig lopende applies kunnen
   de state laten corrumperen. OIDC maakt dit risico niet groter, maar nu je
   geen mens meer handmatig hoeft te coördineren valt het sneller op.
   Oplossing vereist Terraform >= 1.10 (`use_lockfile = true`).

3. **`admin_cidr` staat op `0.0.0.0/0`.** Daarmee staan SSH (22), Grafana
   (3000) en Prometheus (9090) op de monitoring-instance voor de hele wereld
   open. Zet dit naar je eigen IP/32 (`https://checkip.amazonaws.com`).

4. **`task-definition.json` bevat een vastgezet DB-host**
   (`terraform-2026092507...rds.amazonaws.com`) en hardcoded role-ARN's op
   account `491799435972`. Dat is een duplicaat van wat al in
   `aws_ecs_task_definition.nginx` (compute.tf) staat. Zodra Terraform die DB
   opnieuw aanmaakt, wijst dit bestand naar een dode instance. Bewust niet
   aangeraakt omdat het een ontwerpkeuze is, geen access-key-probleem.

5. **De website is nog een placeholder.** `dockerfile` zet alleen
   `<h1>Infrastructuur Succesvol Uitgerold via GitHub Actions!</h1>` op de
   pagina. Wil je daar een echt dashboard met live AWS-status, dan is dat een
   aparte ronde.
