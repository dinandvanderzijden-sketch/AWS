resource "aws_db_subnet_group" "db_subnets" {
  name       = "db-subnet-group"
  subnet_ids = [aws_subnet.data_private_a.id, aws_subnet.data_private_b.id]
}

resource "aws_db_instance" "mariadb" {
  allocated_storage      = 20
  engine                 = "mariadb"
  engine_version         = "10.11"
  instance_class         = "db.t4g.micro"
  db_name                = "appdb"
  username               = "dbadmin"
  password               = "Welkom321"
  db_subnet_group_name   = aws_db_subnet_group.db_subnets.name
  vpc_security_group_ids = [aws_security_group.db_sg.id]
  publicly_accessible    = false
  skip_final_snapshot    = true
}