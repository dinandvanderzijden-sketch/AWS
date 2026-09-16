# Infrastructure as Code — Innovatech Webplatform (AWS)

Terraform-implementatie van het Analysedocument en Ontwerpdocument:
Hub-and-Spoke netwerk, NGINX op ECS Fargate met Blue-Green deployment,
Amazon RDS MariaDB, Prometheus/Grafana en een self-hosted GitHub Actions
runner — allemaal declaratief, met remote state en CI/CD (REQ-NCA-P1-06
t/m P1-08).

## Structuur

```
aws-iac/
├── backend.tf                      # documentatie remote state (S3 + DynamoDB)
├── providers.tf                    # AWS provider + versies
├── variables.tf / outputs.tf       # root laag
├── main.tf                         # koppelt alle modules
├── terraform.tfvars.example        # kopieer naar terraform.tfvars
├── modules/
│   ├── network/                    # Hub VPC + 2 Spoke VPC's + Transit Gateway
│   ├── security/                   # Security Groups (firewall-matrix)
│   ├── database/                   # RDS MariaDB, KMS, Secrets Manager
│   ├── compute/                    # ALB, ECS Fargate, CodeDeploy Blue-Green, autoscaling
│   ├── cicd/                       # Self-hosted GitHub Actions runner (EC2 + IAM)
│   └── observability/              # Prometheus + Grafana (EC2, docker-compose)
├── environments/
│   └── bootstrap/                  # eenmalig: maakt de S3/DynamoDB backend zelf aan
└── .github/workflows/terraform.yml # de CI/CD-pipeline
```

## Requirement-traceability

| Requirement | Waar geïmplementeerd |
|---|---|
| REQ-NCA-P1-01 Netwerksegmentatie | `modules/network` (Hub + 2 Spokes via Transit Gateway, Deny-All + expliciete routes) |
| REQ-NCA-P1-02 Secure Resource Access | `modules/security` (DB-SG alleen vanaf web-CIDR), `modules/database` (`publicly_accessible = false`) |
| REQ-NCA-P1-03 Webservice Deployment | `modules/compute` (ECS Fargate taakdefinitie, omgevingsvariabelen via Secrets Manager) |
| REQ-NCA-P1-04 Scalability | `modules/compute` (`ecs_min_tasks`, step-scaling alarms op 70%/20% CPU) |
| REQ-NCA-P1-05 Observability | `modules/observability` (Prometheus/Grafana) + CloudWatch alarms in `modules/compute` |
| REQ-NCA-P1-06 IaC | dit hele project + `backend.tf` (S3 + DynamoDB locking) |
| REQ-NCA-P1-07 CI/CD | `.github/workflows/terraform.yml` (plan op PR, apply na merge + approval) |
| REQ-NCA-P1-08 DevOps Platform | GitHub repo = single source of truth; elke apply is gekoppeld aan een commit/PR |

## 1. Eenmalige bootstrap (lokaal, met jouw eigen AWS-credentials)

Terraform kan zijn eigen backend niet aanmaken, dus dit stapje gebeurt
buiten de pipeline om, en de zelfgehoste runner bestaat op dit moment nog
niet — dit draai je dus lokaal.

```bash
cd environments/bootstrap
terraform init
terraform apply       # maakt de S3-bucket + DynamoDB-tabel voor de state
```

## 2. Eerste infrastructuur-uitrol (lokaal)

De self-hosted runner moet zelf ook door Terraform worden aangemaakt —
de allereerste `apply` draai je dus ook lokaal, met je eigen (tijdelijke,
liefst SSO/AssumeRole-) AWS-credentials:

```bash
cd ../..   # terug naar de root van dit project
cp terraform.tfvars.example terraform.tfvars   # en vul 'm aan

terraform init \
  -backend-config="bucket=<naam-uit-stap-1>" \
  -backend-config="key=production/terraform.tfstate" \
  -backend-config="region=eu-west-1" \
  -backend-config="dynamodb_table=<naam-uit-stap-1>"

terraform plan   -var="github_runner_token=<kortlevend-token>"
terraform apply  -var="github_runner_token=<kortlevend-token>"
```

Het `github_runner_token` haal je op via:
`gh api -X POST repos/<org>/<repo>/actions/runners/registration-token`
(of via de GitHub UI: Settings → Actions → Runners → New self-hosted
runner). Dit token is kortlevend en hoeft dus nooit in git te staan.

Na deze apply staat de self-hosted runner in het Hub management subnet
en meldt hij zich bij GitHub Actions. Vanaf nu lopen alle volgende
wijzigingen via de pipeline.

## 3. Doorlopend gebruik: via GitHub Actions

In je repository-instellingen zet je:

- **Repository variables**: `TF_STATE_BUCKET`, `TF_STATE_KEY`, `TF_LOCK_TABLE`
- **Repository secret**: `GH_RUNNER_REG_TOKEN` (voor het geval de pipeline
  de runner ooit opnieuw moet registreren)
- **Environment `production`** met minimaal 1 verplichte reviewer — dít is
  het "plan/preview vóór apply"-moment uit REQ-NCA-P1-07.

Workflow:

1. Je opent een PR met infrastructuurwijzigingen → de pipeline draait
   `terraform plan` op de self-hosted runner en plaatst de output als
   PR-comment.
2. Na merge naar `main` draait `terraform apply` — maar pas na
   goedkeuring van de reviewer op de `production` environment.

## Belangrijke kanttekeningen / bewuste vereenvoudigingen

- **Cross-VPC ALB-targets**: de ALB staat in de Hub, de ECS-taken in de
  Spoke-Web VPC. Dit werkt via ALB's ondersteuning voor IP-targets in een
  andere VPC (bereikbaar via de Transit Gateway). Controleer of dit in
  jouw regio/account beschikbaar is; als alternatief kun je de ALB in de
  Spoke-Web VPC plaatsen met een aparte publieke subnet daar.
- **Eén NAT Gateway**: voor deze opdracht bewust op 1 AZ gehouden i.v.m.
  kosten. Voor echte productie: één NAT Gateway per AZ.
- **CI/CD-runner rechten**: de runner-IAM-rol heeft nu `AdministratorAccess`
  omdat de pipeline zelf de volledige infrastructuur beheert. Bouw dit in
  een vervolgstap af naar een strak afgebakende policy.
- **TLS/HTTPS**: de ALB-listener luistert nu op poort 80. Voeg een
  ACM-certificaat + HTTPS-listener toe zodra er een domeinnaam is.
- Draai na het schrijven van `.tf`-bestanden altijd `terraform fmt -recursive`
  en `terraform validate` voordat je een PR opent.

## Op- en afbreken

```bash
terraform destroy -var="github_runner_token=<token>"
```

`deletion_protection = true` staat aan voor de RDS-instance — zet dit
bewust uit voordat je destroy draait, anders faalt die stap.
