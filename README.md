# Infrastructure as Code — Innovatech Webplatform (vereenvoudigde versie)

Dit is een herschreven, platte versie van het Terraform-project: geen
modules, geen hub-and-spoke met Transit Gateway, geen Blue-Green CodeDeploy
— maar wél alle kernvereisten uit het analyse-/ontwerpdocument. Bedoeld om
makkelijk zelf bij te kunnen houden en uit te breiden.

## Bestanden

Terraform leest gewoon élk `.tf`-bestand in deze map als één geheel samen —
de opsplitsing hieronder is puur voor de leesbaarheid, er zit geen
technische scheiding (zoals bij modules) tussen.

| Bestand | Inhoud |
|---|---|
| `main.tf` | provider, terraform-blok, gedeelde data sources (AZ's, AMI) |
| `variables.tf` | alle instelbare waarden, op één plek |
| `network.tf` | 1 VPC, 3 lagen subnets (publiek / privé-web / privé-data) |
| `security.tf` | security groups (ALB → web → database, management apart) |
| `database.tf` | RDS MariaDB + Secrets Manager |
| `compute.tf` | ALB + ECS Fargate (NGINX) + autoscaling |
| `cicd.tf` | self-hosted GitHub Actions runner (EC2) |
| `observability.tf` | Prometheus + Grafana (EC2, docker-compose) |
| `outputs.tf` | wat je na een apply terugkrijgt (ALB-adres, etc.) |
| `environments/bootstrap/` | eenmalig: maakt de S3/DynamoDB remote-state backend aan |
| `.github/workflows/terraform.yml` | de CI/CD-pipeline |

## Wat is er simpeler gemaakt t.o.v. de vorige versie?

| Was | Is nu | Waarom |
|---|---|---|
| Hub-VPC + 2 Spoke-VPC's + Transit Gateway | 1 VPC met 3 subnet-lagen | Evenveel segmentatie voor dit doel, geen TGW-routing om over na te denken |
| Modules (`modules/network`, `modules/compute`, ...) | Platte `.tf`-bestanden in de root | Geen variabelen die je 3x moet doorgeven voor je bij de daadwerkelijke resource bent |
| Network Load Balancer (voor cross-VPC targets) | Gewone Application Load Balancer | ALB en ECS-taken zitten nu toch al in dezelfde VPC |
| CodeDeploy Blue/Green deployment | Standaard ECS rolling-update | Nog steeds zero-downtime, maar zonder CodeDeploy-app, deployment group en aparte IAM-rol erbij |
| Step-scaling + 2 losse CloudWatch-alarms | 1 target-tracking autoscaling-policy (CPU 70%) | Functioneel gelijk, 1 resource in plaats van 4 |
| Custom KMS-key + custom DB parameter group | Standaard AWS-beheerde encryptie | Nog steeds versleuteld, gewoon minder resources om te begrijpen |

## Requirement-traceability

| Requirement | Waar |
|---|---|
| REQ-NCA-P1-01 Netwerksegmentatie | `network.tf` (publiek / privé-web / privé-data, elk hun eigen route table) |
| REQ-NCA-P1-02 Secure Resource Access | `security.tf` (DB-SG alleen vanaf web-SG) + `database.tf` (`publicly_accessible = false`) |
| REQ-NCA-P1-03 Webservice Deployment | `compute.tf` (ECS Fargate taakdefinitie) |
| REQ-NCA-P1-04 Scalability | `compute.tf` (`ecs_min_tasks`, target-tracking autoscaling) |
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

- **Eén NAT Gateway, single-AZ**: bewust, i.v.m. kosten. Voor echte
  productie: één per AZ.
- **RDS-instance klein gehouden** (`db.t3.micro`, `multi_az = false`) omdat
  Fontys-sandbox SCP's grotere/Multi-AZ instances vaak blokkeren. Zet dit
  gerust groter als je eigen account dat toelaat.
- **Runner-IAM-rol heeft `AdministratorAccess`** omdat de pipeline de hele
  infra beheert — bouw dit af als dit richting een echte productieomgeving
  gaat.
- **Geen TLS/HTTPS** op de ALB-listener — voeg een ACM-certificaat toe
  zodra er een domeinnaam is.
- Draai na wijzigingen altijd `terraform fmt` en `terraform validate`
  voordat je een PR opent.

## Opruimen

```bash
terraform destroy -var="github_runner_token=<token>"
```
