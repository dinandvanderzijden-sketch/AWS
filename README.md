# Infrastructure as Code — Innovatech Webplatform

Dit Terraform-project maakt een hub-and-spoke-netwerk met één hub en drie
spokes. De hub bevat de publieke Application Load Balancer. Twee spokes
bevatten elk een private NGINX-EC2-instance; de derde spoke bevat de private
RDS MariaDB-database. Een Transit Gateway verzorgt de routing tussen de
VPC's.

## Bestanden

Terraform leest gewoon élk `.tf`-bestand in deze map als één geheel samen —
de opsplitsing hieronder is puur voor de leesbaarheid, er zit geen
technische scheiding (zoals bij modules) tussen.

| Bestand | Inhoud |
|---|---|
| `main.tf` | provider, terraform-blok, gedeelde data sources (AZ's, AMI) |
| `variables.tf` | alle instelbare waarden, op één plek |
| `network.tf` | hub, 2 web-spoke-VPC's, database-spoke-VPC en Transit Gateway |
| `security.tf` | security groups met routed CIDR-regels tussen de VPC's |
| `database.tf` | RDS MariaDB + Secrets Manager |
| `compute.tf` | publieke ALB + 2 private NGINX-EC2-instances |
| `cicd.tf` | self-hosted GitHub Actions runner (EC2) |
| `observability.tf` | Prometheus + Grafana (EC2, docker-compose) |
| `outputs.tf` | wat je na een apply terugkrijgt (ALB-adres, etc.) |
| `environments/bootstrap/` | eenmalig: maakt de S3/DynamoDB remote-state backend aan |
| `.github/workflows/terraform.yml` | de CI/CD-pipeline |

## Wat is er simpeler gemaakt t.o.v. de vorige versie?

| Was | Is nu | Waarom |
|---|---|---|
| Hub-VPC + 2 web-spokes + 1 database-spoke | Hub + 3 spokes + Transit Gateway | VPC-segmentatie en centrale routing |
| Modules (`modules/network`, `modules/compute`, ...) | Platte `.tf`-bestanden in de root | Geen variabelen die je 3x moet doorgeven voor je bij de daadwerkelijke resource bent |
| Cross-VPC ECS-targets | EC2 NGINX-targets in de web-spokes | Rechtstreeks als IP-targets aan de hub-ALB te koppelen |
| Eén NAT Gateway voor alles | Eén NAT Gateway per web-spoke | Private NGINX-hosts kunnen updates ophalen zonder publiek IP |
| Custom KMS-key + custom DB parameter group | Standaard AWS-beheerde encryptie | Nog steeds versleuteld, gewoon minder resources om te begrijpen |

## Requirement-traceability

| Requirement | Waar |
|---|---|
| REQ-NCA-P1-01 Netwerksegmentatie | `network.tf` (hub + 3 spokes, TGW en route tables) |
| REQ-NCA-P1-02 Secure Resource Access | `security.tf` (DB-SG alleen vanaf web-SG) + `database.tf` (`publicly_accessible = false`) |
| REQ-NCA-P1-03 Webservice Deployment | `compute.tf` (2 NGINX-EC2-instances achter de ALB) |
| REQ-NCA-P1-04 Availability | 2 web-spokes, elk met een NGINX-instance en ALB-health checks |
| REQ-NCA-P1-05 Observability | `observability.tf` (Prometheus/Grafana) |
| REQ-NCA-P1-06 IaC | dit hele project + `main.tf` (S3-backend) |
| REQ-NCA-P1-07 CI/CD | `.github/workflows/terraform.yml` |
| REQ-NCA-P1-08 DevOps Platform | GitHub repo = single source of truth |

## Hoe te draaien

Zelfde volgorde als eerder:

```bash
# 1. Eenmalig: de remote-state backend aanmaken
cd environments/bootstrap
terraform init
terraform apply

# 2. Eerste, lokale apply (bouwt o.a. de GitHub-runner)
cd ../..
cp terraform.tfvars.example terraform.tfvars   # en vul 'm aan

terraform init \
  -backend-config="bucket=<state_bucket uit stap 1>" \
  -backend-config="key=production/terraform.tfstate" \
  -backend-config="region=eu-west-1" \
  -backend-config="dynamodb_table=<lock_table uit stap 1>"

terraform apply -var="github_runner_token=<token via GitHub Settings → Actions → Runners → New self-hosted runner>"
```

Daarna in GitHub: repository variables `TF_STATE_BUCKET`, `TF_STATE_KEY`,
`TF_LOCK_TABLE`, secret `GH_RUNNER_REG_TOKEN`, en een `production`
environment met een verplichte reviewer. Vanaf dan loopt alles via een
PR → plan → merge → approve → apply.

## Kanttekeningen

- **NAT Gateway-kosten**: er draait één NAT Gateway per web-spoke, zodat
  private NGINX-hosts software kunnen installeren zonder publieke IP's.
- **RDS-instance klein gehouden** (`db.t3.micro`, `multi_az = false`) omdat
  Fontys-sandbox SCP's grotere/Multi-AZ instances vaak blokkeren. Zet dit
  gerust groter als je eigen account dat toelaat.
- **Runner-IAM-rol heeft `AdministratorAccess`** omdat de pipeline de hele
  infra beheert — bouw dit af als dit richting een echte productieomgeving
  gaat.
- **Geen TLS/HTTPS** op de ALB-listener — voeg een ACM-certificaat toe
  zodra er een domeinnaam is.
- De ALB gebruikt IP-targets over de Transit Gateway. Controleer in de eigen
  AWS-regio/provider-versie dat cross-VPC IP-targets via TGW voor het gekozen
  load-balancer-type zijn toegestaan; anders is een interne NLB in de hub de
  passende variant.
- Draai na wijzigingen altijd `terraform fmt` en `terraform validate`
  voordat je een PR opent.

## Opruimen

```bash
terraform destroy -var="github_runner_token=<token>"
```
