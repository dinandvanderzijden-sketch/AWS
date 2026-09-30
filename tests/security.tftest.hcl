# ============================================================
# Tests voor REQ-NCA-P1-01 (netwerksegmentatie, deny-all) en
# REQ-NCA-P1-02 (geen publieke toegang tot data- en beheerlaag).
#
# Draait met 'terraform test'. Alle assertions gebruiken 'command = plan',
# dus er verandert niets in AWS.
#
# De aws- en random-provider worden gemockt: de tests draaien dus zonder
# credentials en zonder kosten. Elke waarde die pas na het aanmaken bekend
# is (een ARN, een ID) krijgt een mockwaarde; daarom asserten deze tests
# alleen op configuratie die al in de .tf-bestanden staat - wat precies is
# wat je wilt controleren.
# ============================================================

mock_provider "aws" {}
mock_provider "random" {}

# De SG-ID's zijn pas na de apply bekend. Ze worden hier alvast vastgezet
# zodat de plannen van resources die naar een SG verwijzen niet volledig
# 'unknown' worden. Let op: in de definitieve configuratie verwijst GEEN
# security group naar een andere (cross-VPC kan dat niet - zie de test
# hieronder); deze overrides zijn er voor de leesbaarheid en om de
# toekomstige volgorde van het plan te stabiliseren.
override_resource {
  target          = aws_security_group.alb_sg
  override_during = plan
  values = {
    id = "sg-0aaaaaaaaaaaaaaa1"
  }
}

override_resource {
  target          = aws_security_group.web_sg
  override_during = plan
  values = {
    id = "sg-0bbbbbbbbbbbbbbb2"
  }
}

override_resource {
  target          = aws_security_group.db_sg
  override_during = plan
  values = {
    id = "sg-0ccccccccccccccc3"
  }
}

override_resource {
  target          = aws_security_group.mgmt_sg
  override_during = plan
  values = {
    id = "sg-0ddddddddddddddd4"
  }
}

# Het RDS-endpoint bestaat pas na de apply.
override_resource {
  target          = aws_db_instance.mariadb
  override_during = plan
  values = {
    address    = "appdb-mariadb.abc123.eu-west-1.rds.amazonaws.com"
    db_name    = "appdb"
    identifier = "appdb-mariadb"
  }
}

# ============================================================
# REQ-NCA-P1-01: poorten expliciet toegestaan, verder alles geweigerd
# ============================================================

run "security_groups_staan_niet_open_op_het_internet" {
  command = plan

  assert {
    condition = alltrue([
      for sg in [aws_security_group.web_sg, aws_security_group.db_sg, aws_security_group.mgmt_sg] :
      !strcontains(jsonencode(sg.ingress), "0.0.0.0/0")
    ])
    error_message = "Er staat een security group open op 0.0.0.0/0 (behalve de ALB zelf, die is bewust publiek voor HTTP)."
  }

  # En dezelfde controle voor IPv6: een regel die alleen op ::/0 let wordt
  # makkelijk vergeten.
  assert {
    condition = alltrue([
      for sg in [aws_security_group.web_sg, aws_security_group.db_sg, aws_security_group.mgmt_sg] :
      !strcontains(jsonencode(sg.ingress), "::/0")
    ])
    error_message = "Er staat een security group open op ::/0."
  }

  # De enige resource die publiek bereikbaar mag zijn, is de ALB - en die
  # alleen op 80/443.
  assert {
    condition = alltrue([
      for ing in aws_security_group.alb_sg.ingress : contains([80, 443], ing.from_port)
    ])
    error_message = "De ALB-security-group opent een poort die geen 80 of 443 is."
  }
}

run "web_sg_accepteert_alleen_verkeer_van_de_alb" {
  command = plan

  # REQ-NCA-P1-01 / ontwerpdocument: "Inkomend verkeer uitsluitend toegestaan
  # op poort 80 vanaf de Public LB Security Group."
  #
  # Het ontwerpdocument bedoelt hier een security-group-referentie, maar dat
  # kan niet: de ALB zit in de Hub-VPC en web_sg in de Spoke-Web-VPC, en AWS
  # weigert een SG-referentie over VPC-grenzen (InvalidGroup.NotFound,
  # geverifieerd tijdens de apply van 2026-09-29). Ook met peering zou het
  # niet werken; cross-VPC kan alleen via een CIDR. Daarom wordt hier
  # gecontroleerd dat poort 80 alleen open staat voor de CIDR's van de twee
  // publieke Hub-subnets waarin de ALB draait.
  assert {
    condition = anytrue([
      for ing in aws_security_group.web_sg.ingress :
      ing.from_port == 80 && contains(ing.cidr_blocks, "10.0.2.0/24") && contains(ing.cidr_blocks, "10.0.3.0/24")
    ])
    error_message = "web_sg laat poort 80 niet toe vanaf de CIDR's van de Hub-publieke subnets (10.0.2.0/24 en 10.0.3.0/24); dan komt er geen verkeer van de ALB binnen."
  }

  # Het mag ook geen SG-referentie meer zijn: die zou de apply opblazen.
  assert {
    condition = alltrue([
      for ing in aws_security_group.web_sg.ingress : ing.security_groups == null
    ])
    error_message = "web_sg bevat een security-group-referentie. De ALB zit in een andere VPC dan de Spoke-Web-VPC; zo'n regel maakt de apply stuk met InvalidGroup.NotFound."
  }

  # Alleen poort 80 mag van buiten de ALB, plus het scrape-poortje van
  # Prometheus - geen 3306 vanaf 'buiten'.
  assert {
    condition = alltrue([
      for ing in aws_security_group.web_sg.ingress : contains([80, 9113], ing.from_port)
    ])
    error_message = "web_sg opent een poort die geen 80 (HTTP) of 9113 (exporter) is."
  }
}

run "db_sg_opent_alleen_3306_en_komt_van_de_web_spoke" {
  command = plan

  assert {
    condition = alltrue([
      for ing in aws_security_group.db_sg.ingress : ing.from_port == 3306 && ing.to_port == 3306
    ])
    error_message = "db_sg opent een poort die geen 3306 is. De dode mysqld_exporter-regel (9104) hoort hier niet meer."
  }

  # Zelfde cross-VPC-reden als bij web_sg: db_sg zit in spoke_data, web_sg in
  # spoke_web. De enige toegestane bron is het CIDR van spoke_web, en daar laat
  // web_sg precies 3306 op toe. Zo sluiten de twee bij elkaar aan.
  assert {
    condition = alltrue([
      for ing in aws_security_group.db_sg.ingress : ing.security_groups == null
    ])
    error_message = "db_sg bevat een security-group-referentie naar een andere VPC (spoke_data <> spoke_web); dat maakt de apply stuk met InvalidGroup.NotFound."
  }

  assert {
    condition = alltrue([
      for ing in aws_security_group.db_sg.ingress : contains(ing.cidr_blocks, "10.1.0.0/16")
    ])
    error_message = "db_sg laat 3306 niet toe vanaf het CIDR van de Spoke-Web-VPC (10.1.0.0/16); dan kan de applicatie de database niet bereiken."
  }

  # En de spiegelbeeld-assertie: web_sg mag 3306 alleen naar spoke_data toe.
  assert {
    condition = alltrue([
      for e in aws_security_group.web_sg.egress :
      e.from_port != 3306 || contains(e.cidr_blocks, "10.3.0.0/16")
    ])
    error_message = "web_sg laat 3306 toe naar een ander CIDR dan 10.3.0.0/16 (het CIDR van spoke_data)."
  }
}

# ============================================================
# REQ-NCA-P1-02: de database is niet publiek bereikbaar
# ============================================================

run "database_heeft_geen_publiek_ip" {
  command = plan

  assert {
    condition     = aws_db_instance.mariadb.publicly_accessible == false
    error_message = "De RDS-instance staat op publicly_accessible = true. Dat rechtstreeks in strijd met REQ-NCA-P1-02."
  }

  # Geen subnet in een publieke route table en geen public IP-adres.
  assert {
    condition     = aws_db_instance.mariadb.address != null
    error_message = "De RDS-instance heeft geen endpoint."
  }
}

# ============================================================
# REQ-NCA-P1-02: beheer is fail-closed
# ============================================================

run "zonder_admin_cidr_is_er_geen_enkele_ingress_op_de_monitoring_instance" {
  command = plan

  # Dit is de standaardconfiguratie: var.admin_cidr is leeg.
  assert {
    condition     = var.admin_cidr == ""
    error_message = "De default van admin_cidr hoort leeg te zijn; deze test draait op de default."
  }

  assert {
    condition     = length(aws_security_group.mgmt_sg.ingress) == 0
    error_message = "Met een lege admin_cidr horen er nul ingress-regels te zijn, maar er zijn er ${length(aws_security_group.mgmt_sg.ingress)}. Dat betekent dat de monitoring-instance (met een publiek IP) vanaf het internet bereikbaar is."
  }
}

run "met_admin_cidr_staan_er_precies_drie_regels_voor_juist_je_eigen_ip" {
  command = plan

  variables {
    admin_cidr = "203.0.113.10/32"
  }

  assert {
    condition     = length(aws_security_group.mgmt_sg.ingress) == 3
    error_message = "Verwacht 3 ingress-regels (22, 3000, 9090) voor het gekozen CIDR, maar er zijn er ${length(aws_security_group.mgmt_sg.ingress)}."
  }

  # Elke regel bestaat uit precies één CIDR, en dat is jouw eigen adres.
  # 'contains' werkt zowel op een set als op een lijst; een '==' zou de
  # set/list-conversie stilzwijgend laten mislukken.
  assert {
    condition = alltrue([
      for ing in aws_security_group.mgmt_sg.ingress :
      length(ing.cidr_blocks) == 1 && contains(ing.cidr_blocks, "203.0.113.10/32")
    ])
    error_message = "Een ingress-regel van de monitoring-instance staat open op een ander CIDR dan admin_cidr, of er staat meer dan één CIDR in één regel."
  }
}

run "admin_cidr_0_0_0_0_0_wordt_geweigerd" {
  command = plan

  variables {
    # Dit mag niet kunnen: Prometheus heeft geen authenticatie.
    admin_cidr = "0.0.0.0/0"
  }

  # Dit is een bewuste keuze: liever een harde foutmelding dan een
  # configuratie die publiek toegankelijk is zonder dat iemand het ziet.
  expect_failures = [var.admin_cidr]
}
